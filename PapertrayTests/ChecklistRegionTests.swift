import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testEmptyChecklistCheckboxSurvivesSelectionMoveAndReopen() async throws {
        let controller = try editor()
        let view = controller.editor
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))
        assertVisibleCheckboxes(controller, count: 1)
        // Drag-selection changes include the structural marker but must never hide its control.
        for range in [NSRange(location: 0, length: 1), NSRange(location: 1, length: 0)] {
            view.setSelectedRange(range)
            controller.window?.setFrameOrigin(NSPoint(x: 80, y: 140))
            try await Task.sleep(for: .milliseconds(50))
            assertVisibleCheckboxes(controller, count: 1)
        }
        controller.window?.performClose(nil)
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))
        assertVisibleCheckboxes(controller, count: 1)
        XCTAssertEqual(try tasks(controller).count, 1)
        let emptyBody = try tasks(controller)[0].body
        XCTAssertTrue(emptyBody.isEmpty, "\(emptyBody)")
        XCTAssertNotNil(view.textLayoutManager)
    }

    func testChecklistRegionsGrowWithContentAndKeepStableControls() async throws {
        let controller = try editor()
        let view = controller.editor
        view.insertText("第一项", replacementRange: view.selectedRange())
        view.insertNewline(nil)
        view.insertText("第二项", replacementRange: view.selectedRange())
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let paper = try XCTUnwrap(view.enclosingScrollView?.documentView as? ChecklistDocumentView)
        XCTAssertEqual(paper.regions.count, 2)
        let before = paper.regions
        XCTAssertEqual(paper.frame.width, view.enclosingScrollView!.contentSize.width, accuracy: 0.5)
        XCTAssertEqual(view.frame.width, paper.frame.width, accuracy: 0.5)
        XCTAssertLessThan(before[0].frame.maxY, before[1].frame.minY)
        let originalIDs = try tasks(controller).map(\.id)
        let firstButton = try XCTUnwrap(checkboxButtons(in: paper).first)
        let firstButtonFrame = firstButton.frame
        // Add paragraphs inside the first task, not a second NSTextView or scrolling cell.
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertLineBreak(nil)
        view.insertText(String(repeating: "继续写中文和 emoji 🥳 内容，自动换行。\n", count: 35),
                        replacementRange: view.selectedRange())
        let id = try await attachments.importImage(png())
        view.insertText(try EditorProjection.image(id, store: attachments), replacementRange: view.selectedRange())
        view.insertText("图片后的正文", replacementRange: view.selectedRange())
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(try tasks(controller).map(\.id), originalIDs)
        XCTAssertEqual(paper.regions.count, 2)
        XCTAssertGreaterThan(paper.regions[0].frame.height, view.enclosingScrollView!.contentSize.height * 2)
        XCTAssertLessThan(paper.regions[0].frame.maxY, paper.regions[1].frame.minY)
        XCTAssertGreaterThan(paper.regions[1].frame.minY - before[1].frame.minY, 400)
        XCTAssertTrue(checkboxButtons(in: paper).contains { $0 === firstButton })
        XCTAssertEqual(firstButton.frame, firstButtonFrame)
        XCTAssertEqual(try tasks(controller)[1].body, [.text("第二项", .blue)])
        // Scrolling away/back and resizing must not recreate a task's checkbox.
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.window?.setContentSize(NSSize(width: 310, height: 408))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.window?.display()
        XCTAssertTrue(checkboxButtons(in: paper).contains { $0 === firstButton })
        view.breakUndoCoalescing()
        view.undoManager?.removeAllActions()
        firstButton.performClick(nil)
        XCTAssertTrue(try tasks(controller)[0].isChecked)
        try await Task.sleep(for: .milliseconds(50))
        view.undoManager?.undo()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(try tasks(controller)[0].isChecked)
        XCTAssertEqual(firstButton.state, .off)
        view.selectAll(nil)
        view.copy(nil)
        XCTAssertTrue(clipboard.string(forType: .string)?.hasSuffix("☐ 第二项") == true)
        XCTAssertTrue(clipboard.string(forType: .string)?.contains(try attachments.verifiedURL(for: id).path) == true)
    }

    func testChecklistRegionBoundariesSurviveForwardDeleteAndSelectionReplacement() throws {
        for selectSeparator in [false, true] {
            let controller = try editor()
            let view = controller.editor
            view.insertText("前", replacementRange: view.selectedRange())
            view.insertNewline(nil)
            view.insertText("后", replacementRange: view.selectedRange())
            controller.showWindow(nil)
            // Remove just the inter-task newline: the tasks must merge, not overlap.
            view.setSelectedRange(NSRange(location: 2, length: selectSeparator ? 1 : 0))
            if selectSeparator { view.insertText("", replacementRange: view.selectedRange()) }
            else { view.deleteForward(nil) }
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(try tasks(controller).count, 1)
            let paper = try XCTUnwrap(view.enclosingScrollView?.documentView as? ChecklistDocumentView)
            XCTAssertEqual(paper.regions.count, 1)
            XCTAssertEqual(try tasks(controller)[0].body, [.text("前后", .blue)])
        }
    }

    func testChecklistGutterHitTestingAndImageWidth() async throws {
        let controller = try editor()
        let view = controller.editor
        view.insertText("正文区域\n", replacementRange: view.selectedRange())
        let id = try await attachments.importImage(png())
        let image = try EditorProjection.image(id, store: attachments)
        let attachment = try XCTUnwrap(image.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        attachment.bounds = NSRect(x: 0, y: 0, width: 700, height: 525)
        let imageRange = NSRange(location: view.selectedRange().location, length: 1)
        view.insertText(image, replacementRange: view.selectedRange())
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: 300, height: 408))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let paper = try XCTUnwrap(view.enclosingScrollView?.documentView as? ChecklistDocumentView)
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let button = try XCTUnwrap(checkboxButtons(in: paper).first)
        let checkboxPoint = button.convert(NSPoint(x: 11, y: 11), to: paper.superview)
        XCTAssertTrue(paper.hitTest(checkboxPoint) === button)
        let textPoint = paper.convert(NSPoint(x: 120, y: paper.regions[0].firstLineTop + 10), to: paper.superview)
        let textHit = paper.hitTest(textPoint)
        XCTAssertTrue(textHit === view || textHit?.isDescendant(of: view) == true,
                      "Region chrome must not intercept text selection")
        let screenRect = view.firstRect(forCharacterRange: imageRange, actualRange: nil)
        let windowRect = try XCTUnwrap(controller.window).convertFromScreen(screenRect)
        let imageRect = paper.convert(windowRect, from: nil)
        XCTAssertGreaterThan(imageRect.width, 100)
        XCTAssertLessThanOrEqual(imageRect.maxX, paper.regions[0].frame.maxX)
        XCTAssertGreaterThanOrEqual(imageRect.minX, ChecklistDocumentView.textInset)
        XCTAssertEqual(attachment.bounds.width, 700, "Display layout must not rewrite the original image")
    }

    func testChecklistRegionScreenshot() async throws {
        let controller = try editor()
        controller.showWindow(nil)
        let view = controller.editor
        view.insertText("整理这周的工作\n补充背景、问题和截图。", replacementRange: view.selectedRange())
        let id = try await attachments.importImage(png())
        view.insertLineBreak(nil)
        view.insertText(try EditorProjection.image(id, store: attachments), replacementRange: view.selectedRange())
        view.insertNewline(nil)
        view.insertText("第二件事\n每个区域有自己的横线，内容增加时自然扩展。", replacementRange: view.selectedRange())
        view.insertNewline(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.display()
        let surface = try XCTUnwrap(controller.window?.contentView)
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
        for button in checkboxButtons(in: surface) {
            let rect = button.convert(button.bounds, to: surface)
            let top = surface.isFlipped ? rect.minY : surface.bounds.height - rect.maxY
            var darkPixels = 0
            for y in Int(top * scale)..<min(bitmap.pixelsHigh, Int((top + rect.height) * scale)) {
                for x in Int(rect.minX * scale)..<min(bitmap.pixelsWide, Int(rect.maxX * scale)) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent < 0.75 { darkPixels += 1 }
                }
            }
            XCTAssertGreaterThan(darkPixels, 20, "Checkbox exists but is not painted")
        }
        let image = NSImage(size: surface.bounds.size)
        image.addRepresentation(bitmap)
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "checklist-regions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        assertVisibleCheckboxes(controller, count: 3)
    }

    private func checkboxButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? checkboxButtons(in: child)
        }
    }

    private func assertVisibleCheckboxes(_ controller: NoteController, count: Int,
                                         file: StaticString = #filePath, line: UInt = #line) {
        guard let content = controller.window?.contentView else { return XCTFail("Missing content view", file: file, line: line) }
        let buttons = checkboxButtons(in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(buttons.count, count, "Checkbox must exist even for an empty task", file: file, line: line)
        for button in buttons {
            let frame = button.convert(button.bounds, to: content)
            XCTAssertTrue(content.bounds.intersects(frame), file: file, line: line)
            XCTAssertGreaterThan(frame.width, 10, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 10, file: file, line: line)
        }
    }
}
