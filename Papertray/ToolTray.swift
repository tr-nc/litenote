import AppKit

@MainActor
final class ToolTrayController: NSWindowController {
    var onCreate: ((PaperKind, NSPoint, NSPoint) -> Bool)?
    var onInk: ((Ink) -> Void)?
    var onDismiss: (() -> Void)?
    private var papers: [PaperChoice] = []
    private var colors: [NSButton] = []
    private var preview: NSPanel?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var gesture = PlacementGesture()
    private var draggedKind: PaperKind = .ruled
    private var anchor = NSPoint.zero

    init(ink: Ink) {
        let panel = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 182),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Papertray"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        guard let content = panel.contentView else { return }
        for (index, kind) in PaperKind.allCases.enumerated() {
            let paper = PaperChoice(frame: NSRect(x: 20 + index * 116, y: 65, width: 94, height: 100))
            paper.kind = kind
            paper.tray = self
            paper.selected = index == 0
            papers.append(paper)
            content.addSubview(paper)
        }
        for (index, color) in Ink.allCases.enumerated() {
            let button = NSButton(title: "●", target: self, action: #selector(selectInk(_:)))
            button.tag = index
            button.frame = NSRect(x: 19 + index * 44, y: 14, width: 36, height: 32)
            button.bezelStyle = .regularSquare
            button.contentTintColor = color.color
            button.font = .systemFont(ofSize: 22)
            button.setAccessibilityLabel("\(color.title)色笔")
            colors.append(button)
            content.addSubview(button)
        }
        updateInk(ink)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelDrag()
                if self.window?.isVisible == true { self.positionOnCurrentScreen() }
            }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelDrag() }
        }
    }
    required init?(coder: NSCoder) { return nil }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func positionOnCurrentScreen() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.first,
              let window else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width - 16,
                                      y: visible.maxY - window.frame.height - 16))
    }

    func show(activate: Bool = true) {
        positionOnCurrentScreen()
        if activate { window?.makeKeyAndOrderFront(nil) }
        else { window?.orderFront(nil) }
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            let handled = MainActor.assumeIsolated {
                if self.gesture.state == .pressed || self.gesture.state == .dragging {
                    self.cancelDrag()
                    return true
                }
                // Notes/IME/sheets own their Escape handling; do not steal their event.
                guard event.window === self.window else { return false }
                self.onDismiss?()
                return true
            }
            return handled ? nil : event
        }
    }

    func hide() {
        cancelDrag()
        window?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    private func cancelDrag() {
        gesture.cancel()
        preview?.orderOut(nil)
        preview = nil
    }

    func press(kind: PaperKind, point: NSPoint, anchor: NSPoint) {
        cancelDrag()
        draggedKind = kind
        self.anchor = anchor
        gesture.press(at: point)
        for paper in papers { paper.selected = paper.kind == kind }
        window?.makeKey()
    }

    func move(to point: NSPoint) {
        gesture.move(to: point)
        guard gesture.state == .dragging else { return }
        if preview == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.alphaValue = 0.55
            panel.backgroundColor = NSColor(srgbRed: 0.99, green: 0.97, blue: 0.90, alpha: 1)
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            preview = panel
        }
        preview?.setFrameOrigin(NSPoint(x: point.x - anchor.x, y: point.y + anchor.y - 440))
        preview?.orderFrontRegardless()
    }

    func release(at point: NSPoint) {
        preview?.orderOut(nil)
        preview = nil
        guard let window, gesture.release(at: point, screens: NSScreen.screens.map(\.frame), tray: window.frame) else { return }
        _ = onCreate?(draggedKind, point, anchor)
    }

    @objc private func selectInk(_ sender: NSButton) {
        let ink = Ink.allCases[sender.tag]
        updateInk(ink)
        onInk?(ink)
    }

    private func updateInk(_ ink: Ink) {
        for (index, button) in colors.enumerated() {
            let selected = Ink.allCases[index] == ink
            button.title = selected ? "◉" : "●"
            button.setAccessibilityValue(selected ? "已选择" : "未选择")
        }
    }
}

final class PaperChoice: NSView {
    var kind: PaperKind = .ruled
    var selected = false { didSet { needsDisplay = true } }
    weak var tray: ToolTrayController?
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let paper = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        NSColor(srgbRed: 0.99, green: 0.97, blue: 0.90, alpha: 1).setFill()
        paper.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        paper.lineWidth = selected ? 2 : 1
        paper.stroke()
        for index in 0..<3 {
            let y = CGFloat(42 + index * 17)
            if kind == .checklist {
                NSColor.gray.setStroke()
                NSBezierPath(rect: NSRect(x: 13, y: y, width: 8, height: 8)).stroke()
            }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: kind == .checklist ? 28 : 13, y: y + 3))
            line.line(to: NSPoint(x: 80, y: y + 3))
            NSColor.gray.withAlphaComponent(0.4).setStroke()
            line.stroke()
        }
        (kind.title as NSString).draw(at: NSPoint(x: 24, y: 14),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray])
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        tray?.press(kind: kind, point: NSEvent.mouseLocation, anchor: NSPoint(x: local.x, y: bounds.height - local.y))
    }
    override func mouseDragged(with event: NSEvent) { tray?.move(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { tray?.release(at: NSEvent.mouseLocation) }
}
