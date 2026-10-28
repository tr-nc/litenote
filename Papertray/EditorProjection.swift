import AppKit
import ImageIO

extension Ink {
    var color: NSColor {
        switch self {
        case .graphite: return NSColor(srgbRed: 0.17, green: 0.16, blue: 0.14, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.15, green: 0.34, blue: 0.65, alpha: 1)
        case .red: return NSColor(srgbRed: 0.72, green: 0.23, blue: 0.22, alpha: 1)
        case .green: return NSColor(srgbRed: 0.19, green: 0.43, blue: 0.30, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.48, green: 0.27, blue: 0.60, alpha: 1)
        }
    }
}

extension NSAttributedString.Key {
    static let papertrayInk = Self("local.papertray.ink")
}

/// Immutable editor projection; authoritative checked state lives in NoteDocument.
final class PaperAttachment: NSTextAttachment {
    enum Value {
        case image(UUID)
        case task(UUID, Bool)
    }
    let value: Value
    var toggle: ((UUID) -> Void)?

    init(value: Value) {
        self.value = value
        switch value {
        case .task(_, let checked):
            super.init(data: nil, ofType: nil)
            // AppKit also uses the image projection for printing/cached drawing, where
            // layer-backed attachment views are not necessarily composited.
            image = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square",
                            accessibilityDescription: checked ? "已完成" : "未完成")
            image?.size = NSSize(width: 22, height: 22)
            bounds = NSRect(x: 0, y: -3, width: 22, height: 22)
        case .image:
            super.init(data: nil, ofType: nil)
        }
    }

    required init?(coder: NSCoder) { return nil }

    override var usesTextAttachmentView: Bool {
        if case .task = value { return allowsTextAttachmentView }
        return false
    }

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        if case .task = value {
            return CheckboxProvider(textAttachment: self, parentView: parentView,
                                    textLayoutManager: textContainer?.textLayoutManager, location: location)
        }
        return super.viewProvider(for: parentView, location: location, textContainer: textContainer)
    }
}

final class CheckboxProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? PaperAttachment,
              case .task(_, let checked) = attachment.value else { return }
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle))
        button.state = checked ? .on : .off
        button.setAccessibilityLabel("完成待办")
        button.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        view = button
    }

    @objc private func toggle() {
        guard let attachment = textAttachment as? PaperAttachment,
              case .task(let id, _) = attachment.value else { return }
        attachment.toggle?(id)
    }
}

enum EditorProjection {
    static func attributes(ink: Ink) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: ink.color,
                .papertrayInk: ink.rawValue, .paragraphStyle: paragraph]
    }

    static func task(_ item: TaskItem, toggle: @escaping (UUID) -> Void) -> NSAttributedString {
        let attachment = PaperAttachment(value: .task(item.id, item.isChecked))
        attachment.toggle = toggle
        return NSAttributedString(attachment: attachment)
    }

    static func image(_ id: UUID, store: AttachmentStore) throws -> NSAttributedString {
        let url = try store.verifiedURL(for: id)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
              ] as CFDictionary) else { throw PapertrayError.message("无法读取附件图片。") }
        let attachment = PaperAttachment(value: .image(id))
        let size = NSSize(width: thumbnail.width, height: thumbnail.height)
        attachment.image = NSImage(cgImage: thumbnail, size: size)
        let scale = min(1, 260 / size.width)
        attachment.bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        return NSAttributedString(attachment: attachment)
    }

    static func render(_ content: NoteContent, store: AttachmentStore,
                       toggle: @escaping (UUID) -> Void) throws -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func append(_ runs: [Run]) throws {
            for run in runs {
                switch run {
                case .text(let text, let ink):
                    result.append(NSAttributedString(string: text, attributes: attributes(ink: ink)))
                case .image(let id): result.append(try image(id, store: store))
                }
            }
        }
        switch content {
        case .ruled(let body): try append(body)
        case .checklist(let tasks):
            for (index, item) in tasks.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes(ink: .graphite))) }
                result.append(task(item, toggle: toggle))
                try append(item.body)
            }
        }
        return result
    }

    /// One editor, arbitrary paragraphs per task. Only explicit task attachments split tasks.
    static func parse(_ text: NSAttributedString, kind: PaperKind, firstTaskID: UUID) -> NoteContent {
        var body: [Run] = []
        var tasks: [TaskItem] = []
        var current = TaskItem(id: firstTaskID)
        var sawTask = false

        func appendText(_ value: String, ink: Ink) {
            guard !value.isEmpty else { return }
            if let last = body.last, case .text(let previous, let previousInk) = last, previousInk == ink {
                body[body.count - 1] = .text(previous + value, ink)
            } else { body.append(.text(value, ink)) }
        }
        func finishTask(stripSeparator: Bool) {
            if stripSeparator, let last = body.last, case .text(var value, let ink) = last, value.hasSuffix("\n") {
                value.removeLast()
                body.removeLast()
                if !value.isEmpty { body.append(.text(value, ink)) }
            }
            current.body = body
            tasks.append(current)
            body = []
        }

        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? PaperAttachment {
                switch attachment.value {
                case .image(let id): body.append(.image(id))
                case .task(let id, let checked):
                    guard kind == .checklist else { return }
                    if sawTask || !body.isEmpty { finishTask(stripSeparator: true) }
                    current = TaskItem(id: id, isChecked: checked)
                    sawTask = true
                }
            } else {
                let ink = (attributes[.papertrayInk] as? String).flatMap(Ink.init(rawValue:)) ?? .graphite
                appendText((text.string as NSString).substring(with: range), ink: ink)
            }
        }
        if kind == .ruled { return .ruled(body) }
        finishTask(stripSeparator: false)
        return .checklist(tasks)
    }
}

enum ClipboardExporter {
    /// Uses actual UTF-16 selection ranges supplied by NSTextView, never the whole model by default.
    static func text(from source: NSAttributedString, range: NSRange,
                     store: AttachmentStore) throws -> String {
        guard range.location >= 0, range.length >= 0,
              range.location <= source.length, range.length <= source.length - range.location else {
            throw PapertrayError.message("选区无效。")
        }
        let selected = source.attributedSubstring(from: range)
        var output = ""
        var failure: Error?
        selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attributes, subrange, stop in
            do {
                if let attachment = attributes[.attachment] as? PaperAttachment {
                    switch attachment.value {
                    case .task(_, let checked): output += checked ? "☑ " : "☐ "
                    case .image(let id):
                        let path = try store.verifiedURL(for: id).path
                        if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
                        output += path + "\n"
                    }
                } else {
                    output += (selected.string as NSString).substring(with: subrange)
                }
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        return output
    }
}
