import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    // Keep the persisted shortcut name so existing user bindings survive.
    static let togglePaper = Self("toggleTray", initial: .init(.period, modifiers: [.option]))
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
    private var workspace: PaperWorkspace!
    private var settings: NSWindowController?
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
            let document = try store.loadPaper()
            let controller = try NoteController(document: document, store: store, attachments: attachments,
                                                frame: savedFrame(for: document.id))
            controller.onFrame = { controller in
                if let frame = controller.window?.frame {
                    UserDefaults.standard.set(NSStringFromRect(frame), forKey: "frame.\(controller.noteDocument.id)")
                }
            }
            workspace = PaperWorkspace(note: controller, preferences: .standard)
            KeyboardShortcuts.onKeyUp(for: .togglePaper) { [weak self] in self?.toggleWorkspace() }
            if KeyboardShortcuts.getShortcut(for: .togglePaper)?.isTakenBySystem == true {
                KeyboardShortcuts.disable(.togglePaper)
                NSApp.presentError(PapertrayError.message("横线纸快捷键与系统快捷键冲突，请在 Papertray 设置中重新录制。没有修改系统快捷键。"))
            }
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.constrainWindows() }
            }
            workspace.restoreVisibility()
        } catch {
            NSApp.presentError(error)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspace?.show()
        return false
    }

    private func savedFrame(for id: UUID) -> NSRect {
        let saved = UserDefaults.standard.string(forKey: "frame.\(id)").map(NSRectFromString)
        let fallback = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = saved ?? NSRect(x: fallback.midX - 180, y: fallback.midY - 220, width: 360, height: 440)
        let visible = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) })?.visibleFrame ?? fallback
        return Placement.constrain(frame, to: visible)
    }

    private func constrainWindows() {
        guard let controller = workspace?.note else { return }
        controller.window?.setFrame(savedFrame(for: controller.noteDocument.id), display: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("显示 / 收起横线纸", action: #selector(toggleWorkspace), to: menu)
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
    @objc private func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.title = "Papertray 设置"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
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
            try workspace.note.prepareToHide()
            return .terminateNow
        } catch { NSApp.presentError(error); return .terminateCancel }
    }
}

private struct SettingsView: View {
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("显示 / 收起横线纸", name: .togglePaper) { _ in
                KeyboardShortcuts.enable(.togglePaper)
            }
            Toggle("登录时启动", isOn: Binding(get: { login }, set: { value in
                do {
                    if value { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    login = SMAppService.mainApp.status == .enabled
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                } catch { NSApp.presentError(error) }
            }))
            Divider().padding(.vertical, 8)
            GlassSettingsView(preferences: .shared)
        }
        .padding(24)
        .frame(width: 420, height: 430)
    }
}
