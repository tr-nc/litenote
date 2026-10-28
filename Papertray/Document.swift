import Foundation

enum PaperKind: String, Codable, CaseIterable {
    case ruled, checklist
    var title: String { self == .ruled ? "横线纸" : "待办纸" }
}

enum Ink: String, Codable, CaseIterable {
    case graphite, blue, red, green, purple
    var title: String {
        switch self {
        case .graphite: return "石墨"
        case .blue: return "蓝"
        case .red: return "红"
        case .green: return "绿"
        case .purple: return "紫"
        }
    }
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
        guard schemaVersion == 1 else { throw PapertrayError.message("不支持的文档版本，原文件未被修改。") }
        if case .checklist(let tasks) = content {
            guard !tasks.isEmpty, Set(tasks.map(\.id)).count == tasks.count else {
                throw PapertrayError.message("待办数据无效，原文件未被修改。")
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

enum PapertrayError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
