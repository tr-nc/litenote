import Foundation
import ImageIO
import UniformTypeIdentifiers

struct DataLocation {
    let root: URL
    static var application: Self {
        Self(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papertray", isDirectory: true))
    }
}

/// The only owner of image files. No deletion API: exported paths survive removal and undo.
actor AttachmentStore {
    nonisolated let directory: URL

    init(root: URL) throws {
        directory = root.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated func verifiedURL(for id: UUID) throws -> URL {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else {
            throw PapertrayError.message("附件丢失或无效；没有复制不可靠的路径。")
        }
        return url
    }

    func importImage(_ data: Data) throws -> UUID {
        guard data.count <= 50 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 40_000_000 else {
            throw PapertrayError.message("仅支持 50 MB、4000 万像素以内的单帧图片；多页或动画图片请先导出静态图。")
        }
        // Thumbnail transform applies EXIF orientation; the maximum retains original pixel dimensions.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PapertrayError.message("无法解码图片。")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw PapertrayError.message("无法创建 PNG。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PapertrayError.message("PNG 编码失败。") }
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
        try (encoded as Data).write(to: url, options: .atomic)
        guard let saved = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceCreateImageAtIndex(saved, 0, nil) != nil else {
            throw PapertrayError.message("附件写入验证失败。")
        }
        _ = try verifiedURL(for: id)
        return id
    }
}

/// Serial document owner. Phase A uses small synchronous atomic writes after a debounce.
/// Revisions are checked here, not by UI callers.
@MainActor
final class NoteStore {
    let root: URL
    private let attachments: AttachmentStore
    private var revisions: [UUID: UInt64] = [:]
    private var blocked: Set<UUID> = []
    private var deleted: Set<UUID> = []

    init(root: URL, attachments: AttachmentStore) throws {
        self.root = root
        self.attachments = attachments
        for name in ["notes", "backups", "trash"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    func loadAll() -> (notes: [NoteDocument], errors: [String]) {
        var notes: [NoteDocument] = []
        var errors: [String] = []
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("notes"),
                                                                  includingPropertiesForKeys: nil)
            for url in urls where url.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    // Newer schemas are never silently recovered from an older backup.
                    let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard header?["schemaVersion"] as? Int == 1 else {
                        throw PapertrayError.message("文档版本不受支持。")
                    }
                    let note = try JSONDecoder().decode(NoteDocument.self, from: data)
                    try note.validate()
                    guard url.deletingPathExtension().lastPathComponent == note.id.uuidString else {
                        throw PapertrayError.message("文档身份与文件名不匹配。")
                    }
                    revisions[note.id] = note.revision
                    notes.append(note)
                } catch {
                    if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { blocked.insert(id) }
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)（原文件和备份已保留）")
                }
            }
        } catch { errors.append(error.localizedDescription) }
        return (notes.sorted { $0.createdAt < $1.createdAt }, errors)
    }

    func save(_ note: NoteDocument) throws {
        try note.validate()
        guard !deleted.contains(note.id) else { throw PapertrayError.message("这张纸已永久删除，不能再次保存。") }
        guard !blocked.contains(note.id) else { throw PapertrayError.message("损坏文档已锁定，不能覆盖。") }
        if let revision = revisions[note.id], note.revision < revision { return }
        for id in note.attachmentIDs { _ = try attachments.verifiedURL(for: id) }
        let url = root.appendingPathComponent("notes/\(note.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(note)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            let valid = try JSONDecoder().decode(NoteDocument.self, from: previous)
            try valid.validate()
            try previous.write(to: root.appendingPathComponent("backups/\(note.id.uuidString).json"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        revisions[note.id] = note.revision
    }

    /// Remove recovery copies first: if removing the authoritative note fails, keep
    /// its editor usable and report failure. Never touch separately owned attachments.
    func permanentlyDelete(_ id: UUID) throws {
        for directory in ["backups", "notes"] {
            let url = root.appendingPathComponent("\(directory)/\(id.uuidString).json")
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
        deleted.insert(id)
        revisions.removeValue(forKey: id)
        blocked.remove(id)
    }
}
