import AppKit
import ImageIO

extension NSAttributedString.Key {
    static let litenoteInk = Self("local.papertray.ink")
}

final class PaperAttachment: NSTextAttachment {
    let id: UUID

    init(id: UUID) {
        self.id = id
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { return nil }
    override var usesTextAttachmentView: Bool { false }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: NSRect,
                                   position: NSPoint) -> NSRect {
        guard bounds.width > 0 else { return bounds }
        let scale = min(1, max(1, proposedLineFragment.width) / bounds.width)
        return NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * scale, height: bounds.height * scale)
    }
}

enum EditorProjection {
    static func attributes(ink: Ink = .graphite) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Unlike additive lineSpacing, this also applies to the trailing empty
        // line after deletion. No maximum: tall attachments still expand the line.
        paragraph.minimumLineHeight = 25
        return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: PaperPalette.ink,
                .litenoteInk: ink.rawValue, .paragraphStyle: paragraph]
    }

    static func image(_ id: UUID, store: AttachmentStore) throws -> NSAttributedString {
        let url = try store.verifiedURL(for: id)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
              ] as CFDictionary) else { throw NoteError.message("无法读取附件图片。") }
        let attachment = PaperAttachment(id: id)
        let size = NSSize(width: thumbnail.width, height: thumbnail.height)
        attachment.image = NSImage(cgImage: thumbnail, size: size)
        let scale = min(1, 260 / size.width)
        attachment.bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        return NSAttributedString(attachment: attachment)
    }

    static func render(_ content: NoteContent, store: AttachmentStore) throws -> NSAttributedString {
        guard case .ruled(let runs) = content else {
            throw NoteError.message("仅支持编辑固定横线纸；旧版待办文件未被修改。")
        }
        let result = NSMutableAttributedString(string: "")
        for run in runs {
            switch run {
            case .text(let text, let ink):
                result.append(NSAttributedString(string: text, attributes: attributes(ink: ink)))
            case .image(let id): result.append(try image(id, store: store))
            }
        }
        return result
    }

    static func parse(_ text: NSAttributedString) -> NoteContent {
        var runs: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? PaperAttachment {
                runs.append(.image(attachment.id))
            } else {
                let value = (text.string as NSString).substring(with: range)
                guard !value.isEmpty else { return }
                let ink = (attributes[.litenoteInk] as? String).flatMap(Ink.init(rawValue:)) ?? .graphite
                if let last = runs.last, case .text(let previous, let previousInk) = last, previousInk == ink {
                    runs[runs.count - 1] = .text(previous + value, ink)
                } else { runs.append(.text(value, ink)) }
            }
        }
        return .ruled(runs)
    }
}

enum ClipboardExporter {
    /// Uses actual UTF-16 selection ranges, never the whole document by default.
    static func text(from source: NSAttributedString, range: NSRange,
                     store: AttachmentStore) throws -> String {
        guard range.location >= 0, range.length >= 0,
              range.location <= source.length, range.length <= source.length - range.location else {
            throw NoteError.message("选区无效。")
        }
        let selected = source.attributedSubstring(from: range)
        var output = ""
        var failure: Error?
        selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attributes, subrange, stop in
            do {
                if let attachment = attributes[.attachment] as? PaperAttachment {
                    let path = try store.verifiedURL(for: attachment.id).path
                    if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
                    output += path + "\n"
                } else {
                    output += (selected.string as NSString).substring(with: subrange)
                }
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        return output
    }
}
