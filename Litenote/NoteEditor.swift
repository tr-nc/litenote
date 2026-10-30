import AppKit

final class NoteTextView: NSTextView {
    private static let imagePasteTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
    var attachments: AttachmentStore!
    var clipboard: NSPasteboard = .general
    var reportError: (Error) -> Void = { NSApp.presentError($0) }
    var beforeCopy: () throws -> Void = {}
    var onHideRequested: () -> Void = {}
    private(set) var importing = false

    override func draw(_ dirtyRect: NSRect) {
        RuledPaper.draw(in: dirtyRect, editor: self)
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
    }

    override func copy(_ sender: Any?) {
        do {
            guard selectedRange().length > 0 else { return }
            try beforeCopy()
            let text = try ClipboardExporter.text(from: attributedString(), range: selectedRange(), store: attachments)
            clipboard.clearContents()
            guard clipboard.setString(text, forType: .string) else {
                throw LitenoteError.message("无法写入剪贴板。")
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
                throw LitenoteError.message("无法写入剪贴板，正文未删除。")
            }
            insertText("", replacementRange: selectedRange())
        } catch { reportError(error) }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:))
            || menuItem.action == #selector(pasteAsPlainText(_:))
            || menuItem.action == #selector(pasteAsRichText(_:)) {
            // Native validation follows importsGraphics, but our own importer
            // supports bitmaps without enabling native rich-text/image imports.
            // Inspect formats only: menu updates must not read or decode payloads.
            return isEditable && !importing
                && clipboard.availableType(from: Self.imagePasteTypes + [.string]) != nil
        }
        return super.validateMenuItem(menuItem)
    }

    override func paste(_ sender: Any?) {
        guard isEditable, !importing else { NSSound.beep(); return }
        let pasteboard = clipboard
        // Explicit paste only. File URL payloads are not read as arbitrary local files.
        if let data = Self.imagePasteTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).first {
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
                        throw LitenoteError.message("导入期间正文发生变化，图片未插入；请重新粘贴。已导入的图片仍保留在附件目录。")
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
            reportError(LitenoteError.message("请粘贴文字或静态位图；文件和其他富文本格式暂不支持。"))
        }
    }

    // External/native rich drops bypass the normalized paste and attachment commit boundary.
    // Phase A supports explicit paste only, not editor drag-and-drop.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func insertLineBreak(_ sender: Any?) {
        insertText(NSAttributedString(string: "\n", attributes: EditorProjection.attributes()),
                   replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.shift), !hasMarkedText() {
            insertLineBreak(nil)
        } else { super.keyDown(with: event) }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // NSTextInputClient uses NSNotFound to replace the active composition,
        // not just its caret/selection. Resolve it before inserting the candidate.
        var range = replacementRange
        if range.location == NSNotFound {
            range = hasMarkedText() ? markedRange() : selectedRange()
        }
        let value: Any
        if let string = insertString as? String {
            value = NSAttributedString(string: string, attributes: EditorProjection.attributes())
        } else if let attributed = insertString as? NSAttributedString {
            let normalized = NSMutableAttributedString(attributedString: attributed)
            normalized.addAttributes([.foregroundColor: PaperPalette.ink, .litenoteInk: Ink.graphite.rawValue],
                                     range: NSRange(location: 0, length: normalized.length))
            value = normalized
        } else { value = insertString }
        super.insertText(value, replacementRange: range)
        typingAttributes = EditorProjection.attributes()
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else { onHideRequested() }
    }
}
