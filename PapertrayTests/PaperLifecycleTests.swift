import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testNativeCloseButtonHidesWithoutDeletingContentOrBackups() throws {
        let controller = try editor()
        controller.editor.insertText("内容", replacementRange: controller.editor.selectedRange())
        try controller.flush()
        controller.editor.insertText("更新", replacementRange: controller.editor.selectedRange())
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.styleMask.contains(.titled))
        for type: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(type)?.isHidden ?? true)
        }
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(button.toolTip, "收起横线纸")
        XCTAssertEqual(button.accessibilityLabel(), "收起横线纸")
        button.performClick(nil)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(store.loadAll().notes.first?.content, controller.noteDocument.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(controller.noteDocument.id).json").path))
        controller.open()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(controller.editor.string, "内容更新")
    }

    func testFailedCloseKeepsEditorVisibleAndCanRetry() throws {
        let controller = try editor()
        controller.editor.insertText("不能丢", replacementRange: controller.editor.selectedRange())
        controller.open()
        let directory = root.appendingPathComponent("notes")
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        var errors = 0
        controller.editor.reportError = { _ in errors += 1 }
        controller.window?.performClose(nil)
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(controller.window!.isVisible)
        XCTAssertTrue(controller.editor.isEditable)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller.window?.performClose(nil)
        XCTAssertFalse(controller.window!.isVisible)
        XCTAssertEqual(store.loadAll().notes.first?.content, controller.noteDocument.content)
    }

    func testManualClearKeepsTheSameDocumentAcrossRestartAndRetainsExportedImages() async throws {
        let document = try store.loadPaper()
        let controller = try NoteController(document: document, store: store, attachments: attachments,
                                            frame: NSRect(x: 0, y: 0, width: 360, height: 440), glass: glass)
        controllers.append(controller)
        let imageID = try await attachments.importImage(png())
        let view = controller.editor
        view.insertText("文字", replacementRange: view.selectedRange())
        view.insertText(try EditorProjection.image(imageID, store: attachments), replacementRange: view.selectedRange())
        try controller.flush()
        let content = controller.noteDocument.content
        view.breakUndoCoalescing()
        view.undoManager?.removeAllActions()
        view.selectAll(nil)
        view.deleteBackward(nil)
        try controller.flush()
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(controller.noteDocument.id, document.id)
        XCTAssertEqual(controller.noteDocument.content, .ruled([]))
        let restarted = try NoteStore(root: root, attachments: attachments)
        XCTAssertEqual(try restarted.loadPaper().id, document.id)
        XCTAssertEqual(try restarted.loadPaper().content, .ruled([]))
        XCTAssertNoThrow(try attachments.verifiedURL(for: imageID))
        view.undoManager?.undo()
        XCTAssertEqual(controller.noteDocument.content, content)
    }

    func testLegacyChecklistCannotCreateAnEditorWindow() throws {
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        XCTAssertThrowsError(try editor(kind: .checklist))
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
    }
}
