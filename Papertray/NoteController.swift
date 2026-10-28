import AppKit

final class NotePanel: NSPanel {
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
    var onFocus: ((NoteController) -> Void)?
    var onVisibility: ((NoteController, Bool) -> Void)?
    var onFrame: ((NoteController) -> Void)?

    init(document: NoteDocument, store: NoteStore, attachments: AttachmentStore, frame: NSRect, ink: Ink) throws {
        self.noteDocument = document
        self.store = store
        let panel = NotePanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        // Placement and workspace persistence use outer window frames, not content rects.
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

        let surface = PaperSurface(kind: document.content.kind)
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
            scroll.topAnchor.constraint(equalTo: surface.topAnchor),
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
        scroll.documentView = editor
        let text = try EditorProjection.render(document.content, store: attachments) { [weak editor] in editor?.toggleTask($0) }
        editor.textStorage?.setAttributedString(text)
        editor.ink = ink
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
            guard let self else { return }
            self.onFocus?(self)
        }
        editor.beforeCopy = { [weak self] in try self?.flush() }
        editor.setSelectedRange(NSRange(location: text.length, length: 0))
        assert(editor.textLayoutManager != nil, "TextKit 2 must remain active")
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func open() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(editor)
        onVisibility?(self, true)
    }

    func saveInitial() throws {
        dirty = true
        try flush()
    }

    func textDidChange(_ notification: Notification) { commitEditor() }

    private func commitEditor() {
        guard !editor.hasMarkedText() else { return }
        let firstID: UUID
        if case .checklist(let items) = noteDocument.content { firstID = items.first?.id ?? UUID() }
        else { firstID = UUID() }
        let content = EditorProjection.parse(editor.attributedString(), kind: editor.kind, firstTaskID: firstID)
        guard content != noteDocument.content else { return }
        noteDocument.content = content
        noteDocument.revision += 1
        // Native undo can bypass didChangeText; invalidate decorative layout as well.
        editor.needsDisplay = true
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !editor.importing else {
            NSApp.presentError(PapertrayError.message("图片正在导入，请完成后再关闭便笺。"))
            return false
        }
        guard !editor.hasMarkedText() else {
            editor.unmarkText()
            textDidChange(Notification(name: NSText.didChangeNotification))
            return windowShouldClose(sender)
        }
        do { try flush(); return true }
        catch { NSApp.presentError(error); return false }
    }

    func windowWillClose(_ notification: Notification) { onVisibility?(self, false) }
    func windowDidMove(_ notification: Notification) { onFrame?(self) }
    func windowDidResize(_ notification: Notification) { onFrame?(self) }
}
