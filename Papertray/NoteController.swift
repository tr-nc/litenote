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
    private(set) var isDeleted = false
    private var undoObservers: [NSObjectProtocol] = []
    var onFocus: ((NoteController) -> Void)?
    var onHideRequested: (() -> Void)?
    var onFrame: ((NoteController) -> Void)?
    var onDelete: ((NoteController) -> Void)?

    init(document: NoteDocument, store: NoteStore, attachments: AttachmentStore, frame: NSRect, glass: GlassPreferences? = nil) throws {
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
        panel.isMovableByWindowBackground = false
        super.init(window: panel)
        panel.delegate = self
        installDeleteButton(on: panel)

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
        editor.kind = document.content.kind
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
        scroll.documentView = editor.kind == .checklist ? ChecklistDocumentView(editor: editor) : editor
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
        editor.onFocus = { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.onFocus?(self)
        }
        editor.onHideRequested = { [weak self] in self?.requestHide() }
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
        guard !isDeleted else { return }
        window?.orderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        if focus {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(editor)
        }
    }

    func prepareToHide() throws {
        if editor.hasMarkedText() {
            editor.unmarkText()
            commitEditor()
        }
        try flush()
    }

    func saveInitial() throws {
        dirty = true
        try flush()
    }

    func textDidChange(_ notification: Notification) { commitEditor() }

    private func commitEditor() {
        guard !isDeleted, !editor.hasMarkedText() else { return }
        let firstID: UUID
        if case .checklist(let items) = noteDocument.content { firstID = items.first?.id ?? UUID() }
        else { firstID = UUID() }
        let content = EditorProjection.parse(editor.attributedString(), kind: editor.kind, firstTaskID: firstID)
        guard content != noteDocument.content else { return }
        noteDocument.content = content
        noteDocument.revision += 1
        // Native undo can bypass didChangeText; update regions and decoration as well.
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
        guard !isDeleted else { return }
        commitEditor()
        saveWork?.cancel()
        guard dirty else { return }
        try store.save(noteDocument)
        dirty = false
        window?.isDocumentEdited = false
        window?.title = noteDocument.content.kind.title
    }

    private func installDeleteButton(on panel: NSWindow) {
        for type: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
        // Keep AppKit's native placement, appearance and close action.
        // The window delegate deletes the note immediately.
        guard let button = panel.standardWindowButton(.closeButton) else { return }
        button.isHidden = false
        button.toolTip = "永久删除这张纸"
        button.setAccessibilityLabel("永久删除这张纸")
    }

    /// A failed deletion leaves memory, pending autosave and the window intact;
    /// a successful one cannot be undone.
    func permanentlyDelete() throws {
        guard !isDeleted else { return }
        guard !editor.importing else { throw PapertrayError.message("图片正在导入，请完成后再删除。") }
        try store.permanentlyDelete(noteDocument.id)
        isDeleted = true
        saveWork?.cancel()
        dirty = false
        editor.isEditable = false
        editor.undoManager?.removeAllActions()
        window?.isDocumentEdited = false
        onDelete?(self)
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try permanentlyDelete() }
        catch { editor.reportError(error) }
        // Deletion owns closing the window; failures must leave it open.
        return false
    }

    private func requestHide() {
        if let onHideRequested { onHideRequested(); return }
        guard !editor.importing else {
            NSApp.presentError(PapertrayError.message("图片正在导入，请完成后再关闭便笺。"))
            return
        }
        do {
            try prepareToHide()
            window?.orderOut(nil)
        } catch { NSApp.presentError(error) }
    }

    // Returning to a paper can leave the same text view as first responder,
    // so editor.becomeFirstResponder alone does not observe every focus change.
    func windowDidBecomeKey(_ notification: Notification) { onFocus?(self) }

    func windowDidMove(_ notification: Notification) { onFrame?(self) }
    func windowDidResize(_ notification: Notification) { onFrame?(self) }
}
