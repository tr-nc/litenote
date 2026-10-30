import XCTest
@testable import Litenote

extension EditorAndStorageTests {
    func testFirstLaunchCreatesAndPinsExactlyOneRuledDocument() throws {
        let first = try store.loadPaper()
        XCTAssertEqual(first.content, .ruled([]))
        XCTAssertEqual(try store.loadPaper(), first)
        let restarted = try NoteStore(root: root, attachments: attachments)
        XCTAssertEqual(try restarted.loadPaper(), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("notes").path),
                       ["\(first.id.uuidString).json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("paper.json").path))
    }

    func testMigrationAdoptsLastEditedRuledPaperAndLeavesEveryLegacyFileUntouched() throws {
        var recent = NoteDocument(kind: .ruled)
        recent.createdAt = Date(timeIntervalSince1970: 10)
        recent.content = .ruled([.text("最近编辑的旧纸", .red)])
        var newerCreation = NoteDocument(kind: .ruled)
        newerCreation.createdAt = Date(timeIntervalSince1970: 100)
        newerCreation.content = .ruled([.text("较晚创建但较早编辑", .blue)])
        var todo = NoteDocument(kind: .checklist)
        todo.content = .checklist([TaskItem(body: [.text("旧待办仍保留", .graphite)])])
        let documents = [recent, newerCreation, todo]
        var originals: [URL: Data] = [:]
        for (index, note) in documents.enumerated() {
            try store.save(note)
            let url = root.appendingPathComponent("notes/\(note.id).json")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: [200.0, 100.0, 300.0][index])],
                                                  ofItemAtPath: url.path)
            originals[url] = try Data(contentsOf: url)
        }
        XCTAssertEqual(try store.loadPaper(), recent)
        for (url, data) in originals { XCTAssertEqual(try Data(contentsOf: url), data) }
        XCTAssertEqual(store.loadAll().notes.count, 3)
        // A later write to a dormant legacy file must never change the chosen paper.
        newerCreation.revision += 1
        try store.save(newerCreation)
        let restarted = try NoteStore(root: root, attachments: attachments)
        XCTAssertEqual(try restarted.loadPaper(), recent)
    }

    func testAdoptedPaperKeepsItsImagesAndCanBeEditedAndCopied() async throws {
        let imageID = try await attachments.importImage(png())
        var legacy = NoteDocument(kind: .ruled)
        legacy.content = .ruled([.text("已有内容\n", .blue), .image(imageID)])
        try store.save(legacy)
        let adopted = try store.loadPaper()
        let controller = try NoteController(document: adopted, store: store, attachments: attachments,
                                            frame: NSRect(x: 0, y: 0, width: 360, height: 440), glass: glass)
        controllers.append(controller)
        controller.editor.clipboard = clipboard
        controller.editor.selectAll(nil)
        controller.editor.copy(nil)
        XCTAssertEqual(clipboard.string(forType: .string), "已有内容\n" + (try attachments.verifiedURL(for: imageID).path) + "\n")
        controller.editor.setSelectedRange(NSRange(location: controller.editor.string.utf16.count, length: 0))
        controller.editor.insertText("继续写", replacementRange: controller.editor.selectedRange())
        try controller.flush()
        let restarted = try NoteStore(root: root, attachments: attachments)
        XCTAssertEqual(try restarted.loadPaper().id, legacy.id)
        XCTAssertEqual(try restarted.loadPaper().content, controller.noteDocument.content)
        XCTAssertEqual(try restarted.loadPaper().attachmentIDs, [imageID])
    }

    func testOnlyLegacyTodosProduceANewBlankPaperWithoutDeletingOrConvertingThem() throws {
        let todo = NoteDocument(kind: .checklist)
        try store.save(todo)
        let url = root.appendingPathComponent("notes/\(todo.id).json")
        let original = try Data(contentsOf: url)
        let paper = try store.loadPaper()
        XCTAssertNotEqual(paper.id, todo.id)
        XCTAssertEqual(paper.content, .ruled([]))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(store.loadAll().notes.count, 2)
    }

    func testDamagedOrMissingPinnedPaperNeverFallsBackToAnotherDocument() throws {
        let paper = try store.loadPaper()
        var dormant = NoteDocument(kind: .ruled)
        dormant.content = .ruled([.text("不能意外复活", .graphite)])
        try store.save(dormant)
        let url = root.appendingPathComponent("notes/\(paper.id).json")
        let reference = try Data(contentsOf: root.appendingPathComponent("paper.json"))
        for data in [Data("broken".utf8), Data("{\"schemaVersion\":99}".utf8)] {
            try data.write(to: url)
            let restarted = try NoteStore(root: root, attachments: attachments)
            XCTAssertThrowsError(try restarted.loadPaper())
            XCTAssertThrowsError(try restarted.save(paper))
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("paper.json")), reference)
        }
        try FileManager.default.removeItem(at: url)
        let restarted = try NoteStore(root: root, attachments: attachments)
        XCTAssertThrowsError(try restarted.loadPaper())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.loadAll().notes, [dormant])
    }

    func testBadReferenceAndFailedFirstSaveDoNotCreateReplacementDocuments() throws {
        let reference = root.appendingPathComponent("paper.json")
        try Data("broken".utf8).write(to: reference)
        XCTAssertThrowsError(try store.loadPaper())
        XCTAssertTrue(store.loadAll().notes.isEmpty)
        try FileManager.default.removeItem(at: reference)
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.removeItem(at: notes)
        try Data("not a directory".utf8).write(to: notes)
        XCTAssertThrowsError(try store.loadPaper())
        XCTAssertFalse(FileManager.default.fileExists(atPath: reference.path))
    }

    func testInvalidLegacyFileBlocksAdoptionButNotAnAlreadyPinnedPaper() throws {
        let invalid = root.appendingPathComponent("notes/\(UUID()).json")
        try Data("broken".utf8).write(to: invalid)
        XCTAssertThrowsError(try store.loadPaper())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("paper.json").path))
        try FileManager.default.removeItem(at: invalid)
        let paper = try store.loadPaper()
        try Data("broken".utf8).write(to: invalid)
        let restarted = try NoteStore(root: root, attachments: attachments)
        XCTAssertEqual(try restarted.loadPaper(), paper, "Dormant files are not part of ordinary startup")
    }
}
