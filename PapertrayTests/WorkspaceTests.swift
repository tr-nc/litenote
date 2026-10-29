import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    private func withWorkspace(_ body: (PaperWorkspace, UserDefaults) throws -> Void) throws {
        let name = "local.papertray.workspace-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        let note = try editor()
        let workspace = PaperWorkspace(note: note, preferences: preferences)
        defer {
            note.window?.orderOut(nil)
            preferences.removePersistentDomain(forName: name)
        }
        try body(workspace, preferences)
    }

    func testRepeatedToggleOnlyShowsTheSamePaperAndPreservesItsContentAndSelection() throws {
        try withWorkspace { workspace, preferences in
            let note = workspace.note
            let window = try XCTUnwrap(note.window)
            note.editor.insertText("前后", replacementRange: note.editor.selectedRange())
            note.editor.setSelectedRange(NSRange(location: 1, length: 0))
            let document = note.noteDocument
            let visible = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
            window.setFrameOrigin(NSPoint(x: visible.midX - 180, y: visible.midY - 220))
            let frame = window.frame
            let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
            for _ in 0..<3 {
                try workspace.toggle(activate: false)
                XCTAssertTrue(window.isVisible)
                XCTAssertTrue(preferences.bool(forKey: "workspaceVisible"))
                XCTAssertEqual(window.animationBehavior, .none)
                XCTAssertEqual(note.editor.selectedRange(), NSRange(location: 1, length: 0))
                try workspace.toggle(activate: false)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(preferences.bool(forKey: "workspaceVisible"))
                XCTAssertEqual(note.noteDocument, document)
                XCTAssertEqual(window.frame, frame)
            }
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows, "No tray or extra paper is created")
            XCTAssertEqual(store.loadAll().notes, [document])
        }
    }

    func testShowRestoresTypingFocusAtTheExistingSelection() async throws {
        let name = "local.papertray.single-focus-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let note = try editor()
        let workspace = PaperWorkspace(note: note, preferences: preferences)
        note.editor.insertText("前后", replacementRange: note.editor.selectedRange())
        note.editor.setSelectedRange(NSRange(location: 1, length: 0))
        for _ in 0..<3 {
            workspace.show()
            let window = try XCTUnwrap(note.window)
            for _ in 0..<100 {
                if window.isKeyWindow { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(window.isKeyWindow)
            XCTAssertTrue(window.firstResponder === note.editor)
            XCTAssertEqual(note.editor.selectedRange(), NSRange(location: 1, length: 0))
            try workspace.hide()
        }
        workspace.show()
        let window = try XCTUnwrap(note.window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        window.sendEvent(event)
        XCTAssertEqual(note.editor.string, "前x后")
    }

    func testEscapeAndCloseUseTheSameHideOperationWithoutDeletingThePaper() throws {
        try withWorkspace { workspace, preferences in
            let note = workspace.note
            note.editor.insertText("保留内容", replacementRange: note.editor.selectedRange())
            workspace.show(activate: false)
            note.editor.cancelOperation(nil)
            XCTAssertFalse(workspace.isVisible)
            XCTAssertFalse(preferences.bool(forKey: "workspaceVisible"))
            workspace.show(activate: false)
            note.window?.performClose(nil)
            XCTAssertFalse(workspace.isVisible)
            XCTAssertFalse(preferences.bool(forKey: "workspaceVisible"))
            workspace.show(activate: false)
            XCTAssertEqual(note.editor.string, "保留内容")
            XCTAssertEqual(store.loadAll().notes.first?.id, note.noteDocument.id)
        }
    }

    func testFailedSaveDoesNotHideThePaperAndCanRetry() throws {
        try withWorkspace { workspace, preferences in
            workspace.show(activate: false)
            let note = workspace.note
            note.editor.insertText("不能丢", replacementRange: note.editor.selectedRange())
            let directory = root.appendingPathComponent("notes")
            try FileManager.default.removeItem(at: directory)
            try Data("blocked".utf8).write(to: directory)
            XCTAssertThrowsError(try workspace.hide())
            XCTAssertTrue(workspace.isVisible)
            XCTAssertTrue(preferences.bool(forKey: "workspaceVisible"))
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try workspace.hide()
            XCTAssertFalse(workspace.isVisible)
            XCTAssertEqual(store.loadAll().notes.first?.content, note.noteDocument.content)
        }
    }

    func testVisibilityRestoresAndFirstLaunchShowsThePaperWithoutATray() throws {
        try withWorkspace { workspace, preferences in
            workspace.restoreVisibility(activate: false)
            XCTAssertTrue(workspace.isVisible)
            try workspace.hide()
            let restored = PaperWorkspace(note: workspace.note, preferences: preferences)
            restored.restoreVisibility(activate: false)
            XCTAssertFalse(restored.isVisible)
            restored.show(activate: false)
            XCTAssertTrue(restored.isVisible)
        }
    }

    func testMenuHasNoCreateDeleteOrDocumentList() {
        let coordinator = AppCoordinator()
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["显示 / 收起横线纸", "设置…", "退出 Papertray"])
        XCTAssertTrue(menu.items.allSatisfy { $0.representedObject == nil })
    }
}
