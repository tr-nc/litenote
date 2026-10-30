import AppKit

final class NotePanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        // AppKit otherwise infers an automatic orderFront/orderOut animation.
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the document. TextKit is a projection; every committed edit becomes a new revision here.
@MainActor
final class NoteController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    private(set) var noteDocument: NoteDocument
    let editor = NoteTextView(usingTextLayoutManager: true)
    private let store: NoteStore
    private var saveWork: DispatchWorkItem?
    private var dirty = false
    private var undoObservers: [NSObjectProtocol] = []
    var onHideRequested: (() -> Void)?
    var onFrame: ((NoteController) -> Void)?

    init(document: NoteDocument, store: NoteStore, attachments: AttachmentStore, frame: NSRect, glass: GlassPreferences? = nil) throws {
        guard document.content.kind == .ruled else {
            throw LitenoteError.message("旧版待办纸已保留在磁盘上，不再作为编辑窗口打开。")
        }
        self.noteDocument = document
        self.store = store
        let panel = NotePanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        // Placement and workspace persistence use outer window frames, not content rects.
        GlassSurface.configure(panel)
        panel.setFrame(frame, display: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 220)
        panel.title = document.content.kind.title
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        super.init(window: panel)
        panel.delegate = self
        installCloseButton(on: panel)

        let surface = GlassSurface(preferences: glass)
        panel.contentView = surface
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        surface.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: (panel.contentLayoutGuide as! NSLayoutGuide).topAnchor),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        editor.attachments = attachments
        editor.drawsBackground = false
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 18, height: 16)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: frame.width - 36, height: CGFloat.greatestFiniteMagnitude)
        editor.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        scroll.documentView = editor
        let text = try EditorProjection.render(document.content, store: attachments)
        editor.textStorage?.setAttributedString(text)
        editor.typingAttributes = EditorProjection.attributes()
        editor.insertionPointColor = PaperPalette.ink
        editor.delegate = self
        // TextKit restores attributed storage during undo without synchronously notifying
        // NSTextViewDelegate on every path. Commit at the undo transaction boundary too.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: panel.undoManager,
                                                                        queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitEditor() }
            })
        }
        editor.beforeCopy = { [weak self] in try self?.flush() }
        editor.setSelectedRange(NSRange(location: text.length, length: 0))
        editor.invalidatePaper()
        assert(editor.textLayoutManager != nil, "TextKit 2 must remain active")
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func open() { present(focus: true) }

    func present(focus: Bool) {
        window?.orderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        if focus {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(editor)
        }
    }

    func prepareToHide() throws {
        guard !editor.importing else { throw LitenoteError.message("图片正在导入，请完成后再关闭横线纸。") }
        if editor.hasMarkedText() {
            editor.unmarkText()
            commitEditor()
        }
        try flush()
    }

    func textDidChange(_ notification: Notification) { commitEditor() }

    private func commitEditor() {
        guard !editor.hasMarkedText() else { return }
        let content = EditorProjection.parse(editor.attributedString())
        guard content != noteDocument.content else { return }
        noteDocument.content = content
        noteDocument.revision += 1
        // Native undo can bypass didChangeText; update the paper decoration as well.
        editor.invalidatePaper()
        dirty = true
        window?.isDocumentEdited = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { try self.flush() }
            catch { self.window?.title = "\(self.noteDocument.content.kind.title) — 未保存，复制或关窗时可重试" }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        assert(editor.textLayoutManager != nil, "Unexpected TextKit 1 fallback")
    }

    func flush() throws {
        commitEditor()
        saveWork?.cancel()
        guard dirty else { return }
        try store.save(noteDocument)
        dirty = false
        window?.isDocumentEdited = false
        window?.title = noteDocument.content.kind.title
    }

    private func installCloseButton(on panel: NSWindow) {
        for type: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
        // Keep AppKit's native placement, appearance and close action.
        // Closing only hides this fixed paper; clearing is an ordinary text edit.
        guard let button = panel.standardWindowButton(.closeButton) else { return }
        button.isHidden = false
        button.toolTip = "收起横线纸"
        button.setAccessibilityLabel("收起横线纸")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestHide()
        return false
    }

    private func requestHide() {
        if let onHideRequested { onHideRequested(); return }
        do {
            try prepareToHide()
            window?.orderOut(nil)
        } catch { editor.reportError(error) }
    }

    func windowDidMove(_ notification: Notification) { onFrame?(self) }
    func windowDidResize(_ notification: Notification) { onFrame?(self) }
}
