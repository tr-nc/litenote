import AppKit
import XCTest
@testable import litenote

extension EditorAndStorageTests {
    func testCommandASelectsCurrentBlockThenWholeDocumentAndStaysSelected() throws {
        let controller = try editor()
        let view = controller.editor
        let text = "第一段\n仍是第一段\n\n第二段 👩🏽‍💻\n还有一行\n\n第三段"
        view.insertText(text, replacementRange: view.selectedRange())
        let block = (text as NSString).range(of: "第二段 👩🏽‍💻\n还有一行")
        view.setSelectedRange(NSRange(location: block.location + 2, length: 0))
        let document = controller.noteDocument
        let menu = NSMenu(title: "编辑")
        let item = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.keyEquivalentModifierMask = [.command]
        item.target = view
        menu.addItem(item)
        menu.update()
        XCTAssertTrue(item.isEnabled)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                  timestamp: 0, windowNumber: controller.window!.windowNumber,
                                                  context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                  isARepeat: false, keyCode: 0))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), block)
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        XCTAssertEqual(controller.noteDocument, document, "Selection must not edit or dirty the document")
    }

    func testBlockSelectionIncludesOrdinaryNewlinesWhitespaceAndUnicode() throws {
        let controller = try editor()
        let view = controller.editor
        let blockText = "中文 👩🏽‍💻 e\u{301}\n \t\n继续"
        let text = "前\n\n" + blockText + "\n\n后"
        view.insertText(text, replacementRange: view.selectedRange())
        let block = (text as NSString).range(of: blockText)
        for location in [block.location, block.location + "中文 👩🏽‍💻".utf16.count, NSMaxRange(block)] {
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), block)
        }
        view.setSelectedRange((text as NSString).range(of: "e\u{301}"))
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), block)
    }

    func testVisualWrappingAndWindowResizeDoNotSplitABlock() throws {
        let controller = try editor()
        let view = controller.editor
        let blockText = String(repeating: "较长的一段文字 👩🏽‍💻 ", count: 40)
        let text = "前段\n\n" + blockText + "\n\n后段"
        view.insertText(text, replacementRange: view.selectedRange())
        let block = (text as NSString).range(of: blockText)
        let window = try XCTUnwrap(controller.window)
        for width: CGFloat in [280, 700] {
            window.setContentSize(NSSize(width: width, height: 440))
            window.contentView?.layoutSubtreeIfNeeded()
            view.setSelectedRange(NSRange(location: block.location + 30, length: 0))
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), block)
        }
    }

    func testBlockSelectionRecognizesCRLFAndOtherNativeLineEndings() throws {
        for newline in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"] {
            let controller = try editor()
            let view = controller.editor
            let blockText = "中间" + newline + "续行"
            let text = "前" + newline + newline + blockText + newline + newline + "后"
            view.insertText(text, replacementRange: view.selectedRange())
            let block = (text as NSString).range(of: blockText)
            view.setSelectedRange(NSRange(location: block.location + 1, length: 0))
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), block, "Line ending: \(newline.debugDescription)")
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        }
    }

    func testCaretOnBlankLinesPrefersFollowingBlockThenFallsBackToLastBlock() throws {
        let controller = try editor()
        let view = controller.editor
        let text = "\n\n前\n\n\n后\n\n"
        view.insertText(text, replacementRange: view.selectedRange())
        for (location, expected) in [(0, "前"), (1, "前"), (3, "前"), (4, "后"), (5, "后"), (8, "后"), (9, "后")] {
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), (text as NSString).range(of: expected), "Caret at \(location)")
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        }
    }

    func testExistingBlockOrCrossBlockSelectionExpandsToWholeDocument() throws {
        let controller = try editor()
        let view = controller.editor
        let text = "第一段\n\n第二段\n\n第三段"
        view.insertText(text, replacementRange: view.selectedRange())
        for selection in [(text as NSString).range(of: "第二段"), NSRange(location: 1, length: 6),
                          NSRange(location: 3, length: 3)] {
            view.setSelectedRange(selection)
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        }
    }

    func testMovingCaretOrEditingRestartsBlockSelectionWithoutAKeypressCounter() throws {
        let controller = try editor()
        let view = controller.editor
        let text = "第一段\n\n第二段"
        view.insertText(text, replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), (text as NSString).range(of: "第一段"))
        view.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), (text as NSString).range(of: "第二段"))
        view.insertText("新内容", replacementRange: view.selectedRange())
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), (view.string as NSString).range(of: "新内容"))
        view.selectAll(nil)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), (view.string as NSString).range(of: "第一段"))
    }

    func testEmptyBlankOnlyAndSingleBlockDocumentsSelectSafely() throws {
        for text in ["", "\n\n", "\r\n\r\n", "只有一段\n续行", " \t"] {
            let controller = try editor()
            let view = controller.editor
            view.insertText(text, replacementRange: view.selectedRange())
            view.setSelectedRange(NSRange(location: 0, length: 0))
            for _ in 0..<3 {
                view.selectAll(nil)
                XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: text.utf16.count))
            }
        }
    }

    func testBlockCopyAndDeleteLeaveSeparatorsAndOtherBlocksUntouchedAndCanUndo() throws {
        let controller = try editor()
        let view = controller.editor
        let text = "前段\n\n当前\n续行\n\n后段"
        view.insertText(text, replacementRange: view.selectedRange())
        view.breakUndoCoalescing()
        view.undoManager?.removeAllActions()
        view.setSelectedRange((text as NSString).range(of: "当前"))
        view.selectAll(nil)
        view.copy(nil)
        XCTAssertEqual(clipboard.string(forType: .string), "当前\n续行")
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "前段\n\n\n\n后段")
        try controller.flush()
        XCTAssertEqual(store.loadAll().notes.first?.content, controller.noteDocument.content)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, text)
        view.selectAll(nil)
        view.selectAll(nil)
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "")
    }

    func testImageLineBelongsToBlockAndCopiesAsAnExistingAttachmentPath() async throws {
        let controller = try editor()
        let view = controller.editor
        let id = try await attachments.importImage(png())
        let image = try EditorProjection.image(id, store: attachments)
        view.insertText("前段\n\n文字\n", replacementRange: view.selectedRange())
        let imageLocation = view.string.utf16.count
        view.insertText(image, replacementRange: view.selectedRange())
        view.insertText("\n继续\n\n后段", replacementRange: view.selectedRange())
        let block = (view.string as NSString).range(of: "文字\n\u{FFFC}\n继续")
        view.setSelectedRange(NSRange(location: imageLocation, length: 0))
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), block)
        view.copy(nil)
        let url = try attachments.verifiedURL(for: id)
        // The existing exporter terminates each image path with a newline,
        // independently of the following newline in the selected source text.
        XCTAssertEqual(clipboard.string(forType: .string), "文字\n\(url.path)\n\n继续")
        view.cut(nil)
        XCTAssertEqual(view.string, "前段\n\n\n\n后段")
        XCTAssertNoThrow(try attachments.verifiedURL(for: id))
    }
}
