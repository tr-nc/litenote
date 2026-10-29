import AppKit

final class NoteTextView: NSTextView {
    var kind: PaperKind = .ruled
    var attachments: AttachmentStore!
    var clipboard: NSPasteboard = .general
    var reportError: (Error) -> Void = { NSApp.presentError($0) }
    var beforeCopy: () throws -> Void = {}
    var onFocus: () -> Void = {}
    var onHideRequested: () -> Void = {}
    var onPresentationChange: () -> Void = {}
    private(set) var importing = false

    override func draw(_ dirtyRect: NSRect) {
        if kind == .ruled { RuledPaper.draw(in: dirtyRect, editor: self) }
        super.draw(dirtyRect)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidatePaper()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { invalidatePaper() }
    }

    func invalidatePaper() {
        // Reflow and undo can move decoration outside the edited glyphs' rectangle.
        needsDisplay = true
        onPresentationChange()
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
            insertText(NSAttributedString(string: string, attributes: EditorProjection.attributes()),
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
        let value = NSMutableAttributedString(string: "\n", attributes: EditorProjection.attributes())
        value.append(EditorProjection.task(TaskItem()))
        insertText(value, replacementRange: selectedRange())
        typingAttributes = EditorProjection.attributes()
    }

    override func insertLineBreak(_ sender: Any?) {
        insertText(NSAttributedString(string: "\n", attributes: EditorProjection.attributes()),
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
        if kind == .checklist {
            if affectedCharRange.location == 0, affectedCharRange.length > 0 { return false }
            // Native word/line deletion must not strand a task marker inside a paragraph.
            // The ordinary insert/delete paths below merge the boundary as one edit.
            if isTaskMarker(at: NSMaxRange(affectedCharRange)),
               replacementString?.hasSuffix("\n") != true,
               !hasNewline(before: affectedCharRange.location) { return false }
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // NSTextInputClient uses NSNotFound to replace the active composition,
        // not just its caret/selection. Resolve it before checklist normalization.
        var range = replacementRange
        if range.location == NSNotFound {
            range = hasMarkedText() ? markedRange() : selectedRange()
        }
        if kind == .checklist, range.location == 0, let storage = textStorage, storage.length > 0,
           let marker = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? PaperAttachment,
           case .task = marker.value {
            range = NSRange(location: 1, length: max(0, range.length - 1))
        }
        if kind == .checklist {
            if range.length == 0, isTaskMarker(at: range.location) { range.location += 1 }
            let replacement = (insertString as? NSAttributedString)?.string ?? (insertString as? String ?? "")
            if range.length > 0, isTaskMarker(at: NSMaxRange(range)),
               !replacement.hasSuffix("\n"), !hasNewline(before: range.location) {
                range.length += 1
            }
        }
        let value: Any
        if let string = insertString as? String {
            value = NSAttributedString(string: string, attributes: EditorProjection.attributes())
        } else if let attributed = insertString as? NSAttributedString {
            let normalized = NSMutableAttributedString(attributedString: attributed)
            normalized.addAttributes([.foregroundColor: PaperPalette.ink, .papertrayInk: Ink.graphite.rawValue],
                                     range: NSRange(location: 0, length: normalized.length))
            value = normalized
        } else { value = insertString }
        super.insertText(value, replacementRange: range)
        typingAttributes = EditorProjection.attributes()
    }

    private func isTaskMarker(at offset: Int) -> Bool {
        guard let storage = textStorage, offset >= 0, offset < storage.length,
              let attachment = storage.attribute(.attachment, at: offset, effectiveRange: nil) as? PaperAttachment,
              case .task = attachment.value else { return false }
        return true
    }

    private func hasNewline(before offset: Int) -> Bool {
        guard offset > 0, offset <= (string as NSString).length else { return false }
        return (string as NSString).substring(with: NSRange(location: offset - 1, length: 1)) == "\n"
    }

    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if kind == .checklist, range.length > 0 {
            insertText("", replacementRange: range)
        } else if kind == .checklist, isTaskMarker(at: range.location - 1), hasNewline(before: range.location - 1) {
            insertText("", replacementRange: NSRange(location: range.location - 2, length: 2))
        } else if kind == .checklist, isTaskMarker(at: range.location), hasNewline(before: range.location) {
            insertText("", replacementRange: NSRange(location: range.location - 1, length: 2))
        } else { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        let range = selectedRange()
        if kind == .checklist, range.length > 0 {
            insertText("", replacementRange: range)
        } else if kind == .checklist, isTaskMarker(at: range.location + 1), hasNewline(before: range.location + 1) {
            insertText("", replacementRange: NSRange(location: range.location, length: 2))
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
        let value = EditorProjection.task(TaskItem(id: id, isChecked: !checked))
        // Checking is a semantic transaction, not typing an attachment. Native typing
        // coalescing can swallow an attachment replacement after rich/paragraph edits.
        breakUndoCoalescing()
        undoManager?.registerUndo(withTarget: self) { editor in editor.toggleTask(id) }
        undoManager?.setActionName("勾选待办")
        storage.replaceCharacters(in: range, with: value)
        didChangeText()
        setSelectedRange(selection)
        typingAttributes = EditorProjection.attributes()
        window?.makeFirstResponder(self)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else { onHideRequested() }
    }
}
