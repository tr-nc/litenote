import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testRuledPaperRulesAlignWithMixedChineseAndLatinText() throws {
        let controller = try editor(kind: .ruled)
        controller.editor.insertText("ce'shi测试\ns'f是否", replacementRange: NSRange(location: 0, length: 0))
        try assertRuledAlignment(controller, screenshotName: "ruled-mixed-text")
    }

    func testEmptyTrailingLineKeepsItsSpacingAfterReturnTypingAndDeletion() throws {
        for text in ["测试", "Latin", "👩🏽‍💻"] {
            let controller = try editor(kind: .ruled)
            controller.open()
            let view = controller.editor
            view.insertText(text, replacementRange: view.selectedRange())
            let before = try assertRuledAlignment(controller, screenshotName: "ruled-before-return", minimumBaselines: 1, forceLayout: false)
            view.insertNewline(nil)
            let emptyCaret = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            for selectAndDelete in [false, true] {
                let end = view.selectedRange().location
                view.insertText("x", replacementRange: view.selectedRange())
                if selectAndDelete {
                    view.setSelectedRange(NSRange(location: end, length: 1))
                    view.deleteForward(nil)
                } else { view.deleteBackward(nil) }
                let after = try assertRuledAlignment(controller, screenshotName: "ruled-after-deleting-last-glyph", minimumBaselines: 2, forceLayout: false)
                XCTAssertEqual(view.string, text + "\n")
                XCTAssertGreaterThanOrEqual(before.count, 4)
                XCTAssertGreaterThanOrEqual(after.count, 4)
                for (expected, actual) in zip(before.prefix(4), after.prefix(4)) {
                    XCTAssertEqual(actual, expected, accuracy: 0.75,
                                   "Emptying the last line must not squeeze it or shift the remaining paper")
                }
                let caret = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
                XCTAssertEqual(caret.minY, emptyCaret.minY, accuracy: 0.75, "Fix the caret layout, not just the rules")
            }
        }
    }

    func testTrailingEmptyLinesKeepTheirSpacingAfterReloadResizeAndUndo() throws {
        let first = try editor(kind: .ruled)
        first.editor.insertText("第一行\n\n", replacementRange: first.editor.selectedRange())
        try first.flush()
        let saved = try XCTUnwrap(store.loadAll().notes.first { $0.id == first.noteDocument.id })
        let restored = try NoteController(document: saved, store: store, attachments: attachments,
                                          frame: NSRect(x: 0, y: 0, width: 360, height: 440), glass: glass)
        controllers.append(restored)
        restored.open()
        let view = restored.editor
        for width in [310.0, 500.0] {
            restored.window?.setContentSize(NSSize(width: width, height: 408))
            let before = try assertRuledAlignment(restored, screenshotName: "ruled-reloaded-empty-lines", minimumBaselines: 3, forceLayout: false)
            let spacing = before[1] - before[0]
            XCTAssertEqual(before[2] - before[1], spacing, accuracy: 0.75)
            view.breakUndoCoalescing()
            view.undoManager?.removeAllActions()
            view.insertText("继续", replacementRange: view.selectedRange())
            view.breakUndoCoalescing()
            view.undoManager?.undo()
            let after = try assertRuledAlignment(restored, screenshotName: "ruled-empty-line-undo", minimumBaselines: 3, forceLayout: false)
            XCTAssertEqual(view.string, "第一行\n\n")
            for (expected, actual) in zip(before.prefix(4), after.prefix(4)) {
                XCTAssertEqual(actual, expected, accuracy: 0.75)
            }
            view.undoManager?.redo()
            XCTAssertEqual(view.string, "第一行\n\n继续")
            view.undoManager?.undo()
            XCTAssertEqual(restored.noteDocument.content, saved.content)
        }
    }

    func testRuledPaperEmptyAndTrailingLine() throws {
        let controller = try editor(kind: .ruled)
        try assertRuledAlignment(controller, screenshotName: "ruled-empty", minimumBaselines: 1)
        controller.editor.insertText("第一行\n\n", replacementRange: NSRange(location: 0, length: 0))
        try assertRuledAlignment(controller, screenshotName: "ruled-blank-lines", minimumBaselines: 3)
    }

    func testRuledPaperTracksWrappingResizeScrollAndUndo() throws {
        let controller = try editor(kind: .ruled)
        let view = controller.editor
        let content = String(repeating: "中英混排 ABC 👩🏽‍💻 e\u{301} 自动换行不会越写越偏。", count: 40)
        view.insertText(content, replacementRange: NSRange(location: 0, length: 0))
        try assertRuledAlignment(controller, screenshotName: "ruled-wrapped")
        controller.window?.setContentSize(NSSize(width: 500, height: 408))
        try assertRuledAlignment(controller, screenshotName: "ruled-resized",
                                 scrollOrigin: NSPoint(x: 0, y: 137))
        controller.window?.setContentSize(NSSize(width: 310, height: 408))
        try assertRuledAlignment(controller, screenshotName: "ruled-narrow",
                                 scrollOrigin: NSPoint(x: 0, y: 237))
        view.breakUndoCoalescing()
        view.undoManager?.removeAllActions()
        view.selectAll(nil)
        view.insertText("替换一行\n再来一行", replacementRange: view.selectedRange())
        try assertRuledAlignment(controller, screenshotName: "ruled-replaced")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, content)
        try assertRuledAlignment(controller, screenshotName: "ruled-undo",
                                 scrollOrigin: NSPoint(x: 0, y: 137))
    }

    func testRuledPaperFollowsImageHeightWithoutDrawingThroughItsRow() async throws {
        let controller = try editor(kind: .ruled)
        let view = controller.editor
        view.insertText("图片上方\n", replacementRange: view.selectedRange())
        let id = try await attachments.importImage(png())
        let image = try EditorProjection.image(id, store: attachments)
        let attachment = try XCTUnwrap(image.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        attachment.bounds = NSRect(x: 0, y: 0, width: 244, height: 183) // Not a multiple of text line spacing.
        view.insertText(image, replacementRange: view.selectedRange())
        view.insertText("\n图片下方\n继续输入", replacementRange: view.selectedRange())
        try assertRuledAlignment(controller, screenshotName: "ruled-image")
        XCTAssertEqual(controller.noteDocument.attachmentIDs, [id])
        XCTAssertNotNil(view.textLayoutManager)
    }

    /// Compare the actually painted paper pixels against native glyph baselines, not a
    /// second copy of the paper's spacing calculation. Samples stay outside the text inset.
    @discardableResult
    private func assertRuledAlignment(_ controller: NoteController, screenshotName: String,
                                      minimumBaselines: Int = 2, forceLayout: Bool = true, scrollOrigin: NSPoint? = nil,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> [CGFloat] {
        let view = controller.editor
        controller.window?.orderFront(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let manager = try XCTUnwrap(view.textLayoutManager)
        if forceLayout { manager.ensureLayout(for: manager.documentRange) }
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        scroll.contentView.scroll(to: scrollOrigin ?? .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.window?.display()
        let rect = view.visibleRect
        let surface = try XCTUnwrap(controller.window?.contentView)
        let paperRect = scroll.convert(scroll.bounds, to: surface)
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: paperRect))
        surface.cacheDisplay(in: paperRect, to: bitmap)
        let sampleX = Int(6 * CGFloat(bitmap.pixelsWide) / rect.width)
        let scale = CGFloat(bitmap.pixelsHigh) / rect.height
        let background = try XCTUnwrap(bitmap.colorAt(x: sampleX, y: 0)?.usingColorSpace(.deviceRGB))
        var rules: [CGFloat] = []
        var previousPixel = -2
        for row in 0..<bitmap.pixelsHigh {
            let color = try XCTUnwrap(bitmap.colorAt(x: sampleX, y: row)?.usingColorSpace(.deviceRGB))
            if color.redComponent > background.redComponent + 0.015 {
                if row > previousPixel + 1 { rules.append(rect.minY + (CGFloat(row) + 0.5) / scale) }
                previousPixel = row
            }
        }
        XCTAssertFalse(rules.isEmpty, "No horizontal rules were painted", file: file, line: line)
        var baselines: [CGFloat] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            for textLine in fragment.textLineFragments {
                let baseline = view.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                    + textLine.typographicBounds.minY + textLine.glyphOrigin.y
                baselines.append(baseline)
            }
            return true
        }
        let visibleBaselines = baselines.filter { $0 > rect.minY && $0 + 4 < rect.maxY }
        XCTAssertGreaterThanOrEqual(visibleBaselines.count, minimumBaselines, file: file, line: line)
        for baseline in visibleBaselines {
            // A rule sits just below the glyph baseline; it must not drift by line number.
            let expected = baseline + 3
            let error = rules.map { abs($0 - expected) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(error, 0.75,
                "Baseline \(baseline), painted rules \(rules.prefix(8)); nearest rule is \(error)pt from the writing line",
                file: file, line: line)
        }
        // Within occupied content, extra grid lines (especially through a tall image)
        // are just as wrong as missing lines. Only empty space below the document is tiled.
        let lastBaseline = try XCTUnwrap(baselines.last)
        for rule in rules where rule > rect.minY + 1 && rule < min(rect.maxY - 1, lastBaseline + 4) {
            let error = baselines.map { abs($0 + 3 - rule) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(error, 0.75, "Unexpected rule at \(rule)", file: file, line: line)
        }
        XCTAssertNotNil(view.textLayoutManager, file: file, line: line)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = screenshotName
        attachment.lifetime = .keepAlways
        add(attachment)
        return rules
    }
}
