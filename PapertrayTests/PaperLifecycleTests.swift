import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testPaperTitlebarHasOnlyPermanentDeleteActionAndCancellationPreservesNote() async throws {
        let controller = try editor(kind: .ruled)
        controller.editor.insertText("保留内容", replacementRange: controller.editor.selectedRange())
        try controller.flush()
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(type)?.isHidden ?? true)
        }
        let buttons = window.titlebarAccessoryViewControllers.flatMap { $0.view.subviews.compactMap { $0 as? NSButton } }
        XCTAssertEqual(buttons.count, 1)
        let button = try XCTUnwrap(buttons.first)
        XCTAssertEqual(button.accessibilityLabel(), "永久删除这张纸")
        button.performClick(nil)
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isDeleted)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(store.loadAll().notes.first?.content, controller.noteDocument.content)
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
        XCTAssertThrowsError(try controller.permanentlyDelete())
        XCTAssertFalse(controller.isDeleted)
        XCTAssertTrue(controller.editor.isEditable)
        XCTAssertEqual(store.loadAll().notes.first?.content, controller.noteDocument.content)
        try FileManager.default.removeItem(at: backupDirectory)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try controller.permanentlyDelete()
        XCTAssertTrue(store.loadAll().notes.isEmpty)
    }

    func testPermanentDeleteHandlesAnUnsavedNoteWithoutCreatingFiles() throws {
        let controller = try editor()
        try controller.permanentlyDelete()
        XCTAssertTrue(controller.isDeleted)
        XCTAssertTrue(store.loadAll().notes.isEmpty)
    }
}
