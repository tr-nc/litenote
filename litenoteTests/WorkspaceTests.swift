import AppKit
import XCTest
@testable import litenote

extension EditorAndStorageTests {
    private func withWorkspace(_ body: (PaperWorkspace, UserDefaults) throws -> Void) throws {
        let name = "local.litenote.workspace-tests.\(UUID())"
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
        let name = "local.litenote.single-focus-tests.\(UUID())"
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

    func testEscapeWithoutSelectionKeepsPaperVisibleAndCloseStillHidesIt() throws {
        try withWorkspace { workspace, preferences in
            let note = workspace.note
            note.editor.insertText("保留内容", replacementRange: note.editor.selectedRange())
            workspace.show(activate: false)
            let document = note.noteDocument
            note.editor.cancelOperation(nil)
            XCTAssertTrue(workspace.isVisible)
            XCTAssertTrue(preferences.bool(forKey: "workspaceVisible"))
            XCTAssertEqual(note.noteDocument, document)
            note.window?.performClose(nil)
            XCTAssertFalse(workspace.isVisible)
            XCTAssertFalse(preferences.bool(forKey: "workspaceVisible"))
            workspace.show(activate: false)
            XCTAssertEqual(note.editor.string, "保留内容")
            XCTAssertEqual(store.loadAll().notes.first?.id, note.noteDocument.id)
        }
    }

    func testEscapeKeyClearsPartialBlockAndWholeDocumentSelectionsWithoutHiding() throws {
        try withWorkspace { workspace, preferences in
            let note = workspace.note
            let view = note.editor
            let window = try XCTUnwrap(note.window)
            let text = "前段\n\n当前 👩🏽‍💻\n继续\n\n后段"
            view.insertText(text, replacementRange: view.selectedRange())
            workspace.show(activate: false)
            XCTAssertTrue(window.makeFirstResponder(view))
            let document = note.noteDocument
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                                      isARepeat: false, keyCode: 53))
            for level in 0...2 {
                view.setSelectedRange((text as NSString).range(of: "当前"))
                for _ in 0..<level { view.selectAll(nil) }
                let end = NSMaxRange(view.selectedRange())
                for _ in 0..<2 {
                    window.sendEvent(event)
                    XCTAssertEqual(view.selectedRange(), NSRange(location: end, length: 0))
                    XCTAssertTrue(workspace.isVisible)
                    XCTAssertTrue(preferences.bool(forKey: "workspaceVisible"))
                    XCTAssertTrue(window.firstResponder === view)
                    XCTAssertEqual(note.noteDocument, document)
                    XCTAssertEqual(view.string, text)
                }
            }
            view.insertText("续写", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, text + "续写", "Typing after Escape must not replace the old selection")
        }
    }

    func testEscapeDuringMarkedTextDoesNotHideOrCommitTheComposition() throws {
        try withWorkspace { workspace, preferences in
            let note = workspace.note
            let view = note.editor
            view.insertText("正文", replacementRange: view.selectedRange())
            let document = note.noteDocument
            workspace.show(activate: false)
            view.setMarkedText("ce'shi", selectedRange: NSRange(location: 2, length: 2),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            let markedRange = view.markedRange()
            let selection = view.selectedRange()
            view.cancelOperation(nil)
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.markedRange(), markedRange)
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertEqual(view.string, "正文ce'shi")
            XCTAssertTrue(workspace.isVisible)
            XCTAssertTrue(preferences.bool(forKey: "workspaceVisible"))
            XCTAssertEqual(note.noteDocument, document, "Escape must not persist unfinished pinyin via the hide path")
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
                       ["显示 / 收起横线纸", "设置…", "退出 litenote"])
        XCTAssertTrue(menu.items.allSatisfy { $0.representedObject == nil })
    }
}
