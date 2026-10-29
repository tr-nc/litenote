import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testInputMethodCommitReplacesPinyinInsteadOfAppendingChinese() throws {
        for kind in PaperKind.allCases {
            let controller = try editor(kind: kind)
            let view = controller.editor
            let prefix = view.string
            let initialContent = controller.noteDocument.content
            // NSTextInputClient sequence: compose pinyin, then commit a candidate.
            view.setMarkedText("ce'shi", selectedRange: NSRange(location: 6, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.string, prefix + "ce'shi")
            XCTAssertEqual(controller.noteDocument.content, initialContent)
            view.insertText("测试", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(view.string, prefix + "测试")
            XCTAssertFalse(view.hasMarkedText())
            try assertCommittedText("测试", in: controller)
        }
    }

    func testInputMethodUpdatesReplaceSelectionAndCommitAtAnInternalCompositionCaret() throws {
        for kind in PaperKind.allCases {
            for attributedCommit in [false, true] {
                let controller = try editor(kind: kind)
                let view = controller.editor
                let prefix = view.string
                view.insertText("前👩🏽‍💻旧后", replacementRange: view.selectedRange())
                try controller.flush()
                let original = controller.noteDocument.content
                view.setSelectedRange((view.string as NSString).range(of: "旧"))
                view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                view.setMarkedText("ni'hao", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(view.hasMarkedText())
                XCTAssertEqual(view.string, prefix + "前👩🏽‍💻ni'hao后")
                // Composition stays transient even if an autosave/flush is requested.
                try controller.flush()
                XCTAssertEqual(controller.noteDocument.content, original)
                XCTAssertEqual(store.loadAll().notes.first { $0.id == controller.noteDocument.id }?.content, original)
                let candidate: Any = attributedCommit
                    ? NSAttributedString(string: "你好", attributes: EditorProjection.attributes(ink: .graphite))
                    : "你好"
                view.insertText(candidate, replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertEqual(view.string, prefix + "前👩🏽‍💻你好后")
                XCTAssertFalse(view.hasMarkedText())
                XCTAssertEqual(view.selectedRange(), NSRange(location: (prefix + "前👩🏽‍💻你好" as NSString).length, length: 0))
                try assertCommittedText("前👩🏽‍💻你好后", in: controller)
            }
        }
    }

    func testInputMethodCommitHonorsAnExplicitReplacementRange() throws {
        for kind in PaperKind.allCases {
            let controller = try editor(kind: kind)
            let view = controller.editor
            let prefix = view.string
            view.insertText("前旧后", replacementRange: view.selectedRange())
            view.setSelectedRange((view.string as NSString).range(of: "旧"))
            view.setMarkedText("ni'hao", selectedRange: NSRange(location: 6, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            let explicitRange = (view.string as NSString).range(of: "前ni'hao")
            view.insertText("你好", replacementRange: explicitRange)
            XCTAssertEqual(view.string, prefix + "你好后")
            XCTAssertFalse(view.hasMarkedText())
            try assertCommittedText("你好后", in: controller)
        }
    }

    func testConsecutiveInputMethodCommitsAndOrdinaryTypingDoNotLeaveCompositionText() throws {
        for kind in PaperKind.allCases {
            let controller = try editor(kind: kind)
            let view = controller.editor
            let prefix = view.string
            for (pinyin, candidate) in [("ce'shi", "测试"), ("zhong'wen", "中文")] {
                view.setMarkedText(pinyin, selectedRange: NSRange(location: pinyin.utf16.count, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                view.insertText(candidate, replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertFalse(view.hasMarkedText())
            }
            view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("ok", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(view.string, prefix + "测试中文 ok")
            view.setSelectedRange((view.string as NSString).range(of: "ok"))
            view.insertText("OK", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(view.string, prefix + "测试中文 OK")
            try assertCommittedText("测试中文 OK", in: controller)
        }
    }

    private func assertCommittedText(_ text: String, in controller: NoteController,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try controller.flush()
        let content = controller.noteDocument.content
        switch content {
        case .ruled(let runs):
            XCTAssertEqual(runs, [.text(text, .graphite)], file: file, line: line)
        case .checklist(let items):
            XCTAssertEqual(items.count, 1, file: file, line: line)
            XCTAssertEqual(items.first?.body, [.text(text, .graphite)], file: file, line: line)
        }
        XCTAssertEqual(store.loadAll().notes.first { $0.id == controller.noteDocument.id }?.content,
                       content, file: file, line: line)
        XCTAssertNotNil(controller.editor.textLayoutManager, file: file, line: line)
    }
}
