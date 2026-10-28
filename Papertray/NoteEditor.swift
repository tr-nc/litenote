import AppKit

final class NoteTextView: NSTextView {
    var kind: PaperKind = .ruled
    var ink: Ink = .graphite {
        didSet { typingAttributes = EditorProjection.attributes(ink: ink) }
    }
    var attachments: AttachmentStore!
    var clipboard: NSPasteboard = .general
    var reportError: (Error) -> Void = { NSApp.presentError($0) }
    var beforeCopy: () throws -> Void = {}
    var onFocus: () -> Void = {}
    private(set) var importing = false
    private var replacingTaskMarker = false

    override func draw(_ dirtyRect: NSRect) {
        if kind == .ruled { RuledPaper.draw(in: dirtyRect, editor: self) }
        super.draw(dirtyRect)
    }

    override func didChangeText() {
        super.didChangeText()
        // Reflow can move rules outside the edited glyphs' invalidation rectangle.
        if kind == .ruled { needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if kind == .ruled { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        return accepted
    }

    override func copy(_ sender: Any?) {
        do {
            guard selectedRange().length > 0 else { return }
            try beforeCopy()
            let text = try ClipboardExporter.text(from: attributedString(), range: selectedRange(), store: attachments)
            clipboard.clearContents()
            guard clipboard.setString(text, forType: .string) else {
                throw PapertrayError.message("无法写入剪贴板。")
            }
        } catch { reportError(error) }
    }

    override func cut(_ sender: Any?) {
        do {
            guard selectedRange().length > 0 else { return }
            try beforeCopy()
            let text = try ClipboardExporter.text(from: attributedString(), range: selectedRange(), store: attachments)
            clipboard.clearContents()
            guard clipboard.setString(text, forType: .string) else {
                throw PapertrayError.message("无法写入剪贴板，正文未删除。")
            }
            insertText("", replacementRange: selectedRange())
        } catch { reportError(error) }
    }

    override func paste(_ sender: Any?) {
        guard !importing else { NSSound.beep(); return }
        let pasteboard = clipboard
        // Explicit paste only. File URL payloads are not read as arbitrary local files.
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let selection = selectedRange()
            let snapshot = attributedString()
            importing = true
            isEditable = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.importing = false; self.isEditable = true }
                do {
                    let id = try await self.attachments.importImage(data)
                    guard self.attributedString().isEqual(to: snapshot) else {
                        throw PapertrayError.message("导入期间正文发生变化，图片未插入；请重新粘贴。已导入的图片仍保留在附件目录。")
                    }
                    let image = try EditorProjection.image(id, store: self.attachments)
                    self.isEditable = true
                    self.insertText(image, replacementRange: selection)
                } catch { self.reportError(error) }
            }
        } else if let string = pasteboard.string(forType: .string) {
            insertText(NSAttributedString(string: string, attributes: EditorProjection.attributes(ink: ink)),
                       replacementRange: selectedRange())
        } else {
            reportError(PapertrayError.message("请粘贴文字或静态位图；文件和其他富文本格式暂不支持。"))
        }
    }

    // External/native rich drops bypass the normalized paste and attachment commit boundary.
    // Phase A supports explicit paste only, not editor drag-and-drop.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func insertNewline(_ sender: Any?) {
        guard kind == .checklist, !hasMarkedText() else { super.insertNewline(sender); return }
        let value = NSMutableAttributedString(string: "\n", attributes: EditorProjection.attributes(ink: ink))
        value.append(EditorProjection.task(TaskItem()) { [weak self] in self?.toggleTask($0) })
        insertText(value, replacementRange: selectedRange())
        typingAttributes = EditorProjection.attributes(ink: ink)
    }

    override func insertLineBreak(_ sender: Any?) {
        insertText(NSAttributedString(string: "\n", attributes: EditorProjection.attributes(ink: ink)),
                   replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.shift), !hasMarkedText() {
            insertLineBreak(nil)
        } else { super.keyDown(with: event) }
    }

    // The first checkbox is a structural root: deleting all content leaves one empty task.
    // Subsequent markers can be removed; their bodies merge into the preceding item.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if kind == .checklist, !replacingTaskMarker,
           affectedCharRange.location == 0, affectedCharRange.length > 0 {
            return false
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        var range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if kind == .checklist, range.location == 0, let storage = textStorage, storage.length > 0,
           let marker = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? PaperAttachment,
           case .task = marker.value {
            range = NSRange(location: 1, length: max(0, range.length - 1))
        }
        let value: Any
        if let string = insertString as? String {
            value = NSAttributedString(string: string, attributes: EditorProjection.attributes(ink: ink))
        } else { value = insertString }
        super.insertText(value, replacementRange: range)
        typingAttributes = EditorProjection.attributes(ink: ink)
    }

    override func deleteBackward(_ sender: Any?) {
        if kind == .checklist, selectedRange().location == 0, selectedRange().length > 0 {
            insertText("", replacementRange: selectedRange())
        } else { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if kind == .checklist, selectedRange().location == 0, selectedRange().length > 0 {
            insertText("", replacementRange: selectedRange())
        } else { super.deleteForward(sender) }
    }

    func toggleTask(_ id: UUID) {
        guard !importing, !hasMarkedText(), let storage = textStorage else { return }
        var match: (NSRange, Bool)?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let attachment = value as? PaperAttachment, case .task(let taskID, let checked) = attachment.value,
               taskID == id { match = (range, checked); stop.pointee = true }
        }
        guard let (range, checked) = match else { return }
        let selection = selectedRange()
        let value = EditorProjection.task(TaskItem(id: id, isChecked: !checked)) { [weak self] in self?.toggleTask($0) }
        // Bypass root-marker protection; this is a semantic replacement, not deletion.
        breakUndoCoalescing()
        replacingTaskMarker = true
        super.insertText(value, replacementRange: range)
        replacingTaskMarker = false
        breakUndoCoalescing()
        setSelectedRange(selection)
        typingAttributes = EditorProjection.attributes(ink: ink)
        window?.makeFirstResponder(self)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else { window?.performClose(sender) }
    }
}

final class PaperSurface: NSView {
    let kind: PaperKind
    init(kind: PaperKind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.99, green: 0.97, blue: 0.90, alpha: 1).setFill()
        dirtyRect.fill()

    }
}
