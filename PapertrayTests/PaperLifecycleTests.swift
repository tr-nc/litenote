import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testNativeCloseButtonDeletesImmediatelyWithoutConfirmation() throws {
        let controller = try editor(kind: .ruled)
        controller.editor.insertText("删除内容", replacementRange: controller.editor.selectedRange())
        try controller.flush()
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        for type: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(type)?.isHidden ?? true)
        }
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(button.isEnabled)
        let frame = button.convert(button.bounds, to: nil)
        XCTAssertLessThan(frame.midX, window.frame.width / 2)
        XCTAssertGreaterThan(frame.midY, window.contentLayoutRect.maxY)
        XCTAssertEqual(button.toolTip, "永久删除这张纸")
        XCTAssertEqual(button.accessibilityLabel(), "永久删除这张纸")
        button.performClick(nil)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(controller.isDeleted)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(store.loadAll().notes.isEmpty)
    }

    func testPermanentDeleteRemovesNoteAndBackupButPreservesImageAndRejectsLateSave() async throws {
        let controller = try editor(kind: .ruled)
        let id = try await attachments.importImage(png())
        controller.editor.insertText(try EditorProjection.image(id, store: attachments), replacementRange: NSRange(location: 0, length: 0))
        try controller.flush()
        controller.editor.insertText("新版", replacementRange: controller.editor.selectedRange())
        try controller.flush()
        let previous = controller.noteDocument
        let imageURL = try attachments.verifiedURL(for: id)
        let backup = root.appendingPathComponent("backups/\(previous.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        // Leave a debounced save pending before deleting.
        controller.editor.insertText("尚未自动保存", replacementRange: controller.editor.selectedRange())
        var removed = false
        controller.onDelete = { _ in removed = true }
        controller.showWindow(nil)
        try controller.permanentlyDelete()
        XCTAssertTrue(removed)
        XCTAssertTrue(controller.isDeleted)
        XCTAssertFalse(controller.window!.isVisible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertThrowsError(try store.save(previous))
        try await Task.sleep(for: .milliseconds(500))
        try controller.flush()
        controller.open()
        XCTAssertFalse(controller.window!.isVisible)
        let restarted = try NoteStore(root: root, attachments: attachments)
        XCTAssertEqual(restarted.loadAll().notes, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("notes").path), [])
    }

    func testFailedPermanentDeleteKeepsEditorUsableAndCanRetry() throws {
        let controller = try editor(kind: .ruled)
        controller.editor.insertText("不能误删", replacementRange: controller.editor.selectedRange())
        try controller.flush()
        let backupDirectory = root.appendingPathComponent("backups")
        try FileManager.default.removeItem(at: backupDirectory)
        try Data("not a directory".utf8).write(to: backupDirectory)
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        var errors = 0
        controller.editor.reportError = { _ in errors += 1 }
        button.performClick(nil)
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(controller.isDeleted)
        XCTAssertTrue(controller.editor.isEditable)
        XCTAssertEqual(store.loadAll().notes.first?.content, controller.noteDocument.content)
        try FileManager.default.removeItem(at: backupDirectory)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        button.performClick(nil)
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(controller.isDeleted)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(store.loadAll().notes.isEmpty)
    }

    func testPermanentDeleteHandlesAnUnsavedNoteWithoutCreatingFiles() throws {
        let controller = try editor()
        try controller.permanentlyDelete()
        XCTAssertTrue(controller.isDeleted)
        XCTAssertTrue(store.loadAll().notes.isEmpty)
    }
}
