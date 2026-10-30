import Foundation

// Checklist cases remain decodable only to preserve legacy files during adoption.
// The application opens and edits a single ruled document.
enum PaperKind: String, Codable {
    case ruled, checklist
    var title: String { self == .ruled ? "横线纸" : "待办纸" }
}

/// Legacy document metadata retained for lossless loading/saving. All ink renders white;
/// new input uses graphite as the schema-v1 default, not as a display color.
enum Ink: String, Codable, CaseIterable {
    case graphite, blue, red, green, purple
}

enum Run: Codable, Equatable {
    case text(String, Ink)
    case image(UUID)
}

struct TaskItem: Codable, Equatable {
    var id = UUID()
    var isChecked = false
    var body: [Run] = []
}

enum NoteContent: Codable, Equatable {
    case ruled([Run])
    case checklist([TaskItem])

    var kind: PaperKind {
        switch self {
        case .ruled: return .ruled
        case .checklist: return .checklist
        }
    }
}

struct NoteDocument: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var revision: UInt64 = 0
    var createdAt = Date()
    var content: NoteContent

    init(kind: PaperKind) {
        content = kind == .ruled ? .ruled([]) : .checklist([TaskItem()])
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw LitenoteError.message("不支持的文档版本，原文件未被修改。") }
        if case .checklist(let tasks) = content {
            guard !tasks.isEmpty, Set(tasks.map(\.id)).count == tasks.count else {
                throw LitenoteError.message("待办数据无效，原文件未被修改。")
            }
        }
    }

    var attachmentIDs: [UUID] {
        let runs: [Run]
        switch content {
        case .ruled(let body): runs = body
        case .checklist(let tasks): runs = tasks.flatMap(\.body)
        }
        return runs.compactMap { if case .image(let id) = $0 { return id }; return nil }
    }
}

enum LitenoteError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
