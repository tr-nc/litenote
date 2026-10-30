import AppKit
import XCTest
@testable import Litenote

extension EditorAndStorageTests {
    func testInputMethodCommitReplacesPinyinInsteadOfAppendingChinese() throws {
        let controller = try editor()
        let view = controller.editor
        let initialContent = controller.noteDocument.content
        view.setMarkedText("ce'shi", selectedRange: NSRange(location: 6, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.string, "ce'shi")
        XCTAssertEqual(controller.noteDocument.content, initialContent)
        view.insertText("测试", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "测试")
        XCTAssertFalse(view.hasMarkedText())
        try assertCommittedText("测试", in: controller)
    }

    func testInputMethodUpdatesReplaceSelectionAndCommitAtAnInternalCompositionCaret() throws {
        for attributedCommit in [false, true] {
            let controller = try editor()
            let view = controller.editor
            view.insertText("前👩🏽‍💻旧后", replacementRange: view.selectedRange())
            try controller.flush()
            let original = controller.noteDocument.content
            view.setSelectedRange((view.string as NSString).range(of: "旧"))
            view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.setMarkedText("ni'hao", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.string, "前👩🏽‍💻ni'hao后")
            try controller.flush()
            XCTAssertEqual(controller.noteDocument.content, original)
            XCTAssertEqual(store.loadAll().notes.first { $0.id == controller.noteDocument.id }?.content, original)
            let candidate: Any = attributedCommit
                ? NSAttributedString(string: "你好", attributes: EditorProjection.attributes()) : "你好"
            view.insertText(candidate, replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(view.string, "前👩🏽‍💻你好后")
            XCTAssertFalse(view.hasMarkedText())
            XCTAssertEqual(view.selectedRange(), NSRange(location: ("前👩🏽‍💻你好" as NSString).length, length: 0))
            try assertCommittedText("前👩🏽‍💻你好后", in: controller)
        }
    }

    func testInputMethodCommitHonorsAnExplicitReplacementRange() throws {
        let controller = try editor()
        let view = controller.editor
        view.insertText("前旧后", replacementRange: view.selectedRange())
        view.setSelectedRange((view.string as NSString).range(of: "旧"))
        view.setMarkedText("ni'hao", selectedRange: NSRange(location: 6, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let explicitRange = (view.string as NSString).range(of: "前ni'hao")
        view.insertText("你好", replacementRange: explicitRange)
        XCTAssertEqual(view.string, "你好后")
        XCTAssertFalse(view.hasMarkedText())
        try assertCommittedText("你好后", in: controller)
    }

    func testConsecutiveInputMethodCommitsAndOrdinaryTypingDoNotLeaveCompositionText() throws {
        let controller = try editor()
        let view = controller.editor
        for (pinyin, candidate) in [("ce'shi", "测试"), ("zhong'wen", "中文")] {
            view.setMarkedText(pinyin, selectedRange: NSRange(location: pinyin.utf16.count, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText(candidate, replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(view.hasMarkedText())
        }
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("ok", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "测试中文 ok")
        view.setSelectedRange((view.string as NSString).range(of: "ok"))
        view.insertText("OK", replacementRange: NSRange(location: NSNotFound, length: 0))
        try assertCommittedText("测试中文 OK", in: controller)
    }

    private func assertCommittedText(_ text: String, in controller: NoteController,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try controller.flush()
        XCTAssertEqual(controller.noteDocument.content, .ruled([.text(text, .graphite)]), file: file, line: line)
        XCTAssertEqual(store.loadAll().notes.first { $0.id == controller.noteDocument.id }?.content,
                       controller.noteDocument.content, file: file, line: line)
        XCTAssertNotNil(controller.editor.textLayoutManager, file: file, line: line)
    }
}
