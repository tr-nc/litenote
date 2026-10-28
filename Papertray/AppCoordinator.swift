import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleTray = Self("toggleTray", initial: .init(.period, modifiers: [.option]))
}

@main
struct PapertrayMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppCoordinator()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: NoteStore!
    private var attachments: AttachmentStore!
    private var tray: ToolTrayController!
    private var workspace: PaperWorkspace!
    private weak var lastEditor: NoteController?
    private var settings: NSWindowController?
    private var ink: Ink = Ink(rawValue: UserDefaults.standard.string(forKey: "ink") ?? "") ?? .graphite
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted XCTest must never load user notes, register hotkeys or show windows.
        guard ProcessInfo.processInfo.environment["PAPERTRAY_TESTING"] != "1",
              NSClassFromString("XCTestCase") == nil else { return }
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        do {
            let root = DataLocation.application.root
            attachments = try AttachmentStore(root: root)
            store = try NoteStore(root: root, attachments: attachments)
            installMainMenu()
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Papertray")
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
            tray = ToolTrayController(ink: ink)
            workspace = PaperWorkspace(tray: tray, preferences: .standard)
            tray.onCreate = { [weak self] in self?.create(kind: $0, point: $1, anchor: $2) ?? false }
            tray.onInk = { [weak self] ink in
                guard let self else { return }
                self.ink = ink
                UserDefaults.standard.set(ink.rawValue, forKey: "ink")
                guard self.lastEditor?.isDeleted != true else { self.lastEditor = nil; return }
                self.lastEditor?.editor.ink = ink
                self.lastEditor?.window?.makeKeyAndOrderFront(nil)
                self.lastEditor?.window?.makeFirstResponder(self.lastEditor?.editor)
            }
            let loaded = store.loadAll()
            for document in loaded.notes {
                do {
                    _ = try makeController(document, frame: savedFrame(for: document.id))
                } catch { NSApp.presentError(error) }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleTray) { [weak self] in self?.toggleWorkspace() }
            if KeyboardShortcuts.getShortcut(for: .toggleTray)?.isTakenBySystem == true {
                KeyboardShortcuts.disable(.toggleTray)
                NSApp.presentError(PapertrayError.message("工具盘快捷键与系统快捷键冲突，请在 Papertray 设置中重新录制。没有修改系统快捷键。"))
            }
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.constrainWindows() }
            }
            if !loaded.errors.isEmpty {
                NSApp.presentError(PapertrayError.message(loaded.errors.joined(separator: "\n")))
            }
            let firstLaunch = !UserDefaults.standard.bool(forKey: "didLaunch")
            let legacyVisible = loaded.notes.contains { UserDefaults.standard.bool(forKey: "visible.\($0.id)") }
            workspace.restoreVisibility(legacyVisible: firstLaunch || legacyVisible)
            UserDefaults.standard.set(true, forKey: "didLaunch")
        } catch {
            NSApp.presentError(error)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspace?.show()
        return false
    }

    private func makeController(_ document: NoteDocument, frame: NSRect) throws -> NoteController {
        let controller = try NoteController(document: document, store: store, attachments: attachments, frame: frame, ink: ink)
        controller.onFocus = { [weak self] in self?.lastEditor = $0 }
        controller.onFrame = { controller in
            if let frame = controller.window?.frame {
                UserDefaults.standard.set(NSStringFromRect(frame), forKey: "frame.\(controller.noteDocument.id)")
            }
        }
        workspace.add(controller)
        return controller
    }

    private func create(kind: PaperKind, point: NSPoint, anchor: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        do {
            let controller = try makeController(NoteDocument(kind: kind),
                                                frame: Placement.noteFrame(at: point, anchor: anchor, visible: screen.visibleFrame))
            controller.open()
            do { try controller.saveInitial() }
            catch { NSApp.presentError(error); return false } // Keep recoverable in-memory editor.
            return true
        } catch { NSApp.presentError(error); return false }
    }

    private func savedFrame(for id: UUID) -> NSRect {
        let saved = UserDefaults.standard.string(forKey: "frame.\(id)").map(NSRectFromString)
        let fallback = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = saved ?? NSRect(x: fallback.midX - 180, y: fallback.midY - 220, width: 360, height: 440)
        let visible = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) })?.visibleFrame ?? fallback
        return Placement.constrain(frame, to: visible)
    }

    private func constrainWindows() {
        for controller in workspace.notes.values {
            controller.window?.setFrame(savedFrame(for: controller.noteDocument.id), display: true)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("显示 / 收起所有纸张", action: #selector(toggleWorkspace), to: menu)
        menu.addItem(.separator())
        for controller in workspace.notes.values.sorted(by: { $0.noteDocument.createdAt < $1.noteDocument.createdAt }) {
            let text = controller.editor.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = text.isEmpty ? controller.noteDocument.content.kind.title : String(text.prefix(28))
            let item = add(title, action: #selector(reopen(_:)), to: menu)
            item.representedObject = controller.noteDocument.id.uuidString
            item.state = controller.window?.isVisible == true ? .on : .off
        }
        if workspace.notes.isEmpty {
            let empty = NSMenuItem(title: "从工具盘拖出纸张开始", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        add("设置…", action: #selector(showSettings), to: menu)
        add("退出 Papertray", action: #selector(quit), to: menu)
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Papertray")
        appItem.submenu?.addItem(withTitle: "退出 Papertray", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"),
            ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")
        ] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc private func toggleWorkspace() {
        do { try workspace.toggle() }
        catch { NSApp.presentError(error) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func reopen(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String, let id = UUID(uuidString: string) else { return }
        workspace.show(focusing: id)
    }
    @objc private func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.title = "Papertray 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settings = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        do {
            for controller in workspace.notes.values {
                guard !controller.editor.importing else {
                    throw PapertrayError.message("图片正在导入，请完成后再退出。")
                }
                if controller.editor.hasMarkedText() {
                    controller.editor.unmarkText()
                    controller.textDidChange(Notification(name: NSText.didChangeNotification))
                }
                try controller.flush()
            }
            return .terminateNow
        } catch { NSApp.presentError(error); return .terminateCancel }
    }
}

private struct SettingsView: View {
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("显示纸张与工具盘", name: .toggleTray) { _ in
                KeyboardShortcuts.enable(.toggleTray)
            }
            Toggle("登录时启动", isOn: Binding(get: { login }, set: { value in
                do {
                    if value { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    login = SMAppService.mainApp.status == .enabled
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                } catch { NSApp.presentError(error) }
            }))
        }
        .padding(24)
        .frame(width: 380, height: 150)
    }
}
