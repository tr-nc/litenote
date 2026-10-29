import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    private func withWorkspace(_ body: (PaperWorkspace, ToolTrayController, UserDefaults) throws -> Void) rethrows {
        let name = "local.papertray.workspace-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        let tray = ToolTrayController(glass: glass)
        let workspace = PaperWorkspace(tray: tray, preferences: preferences)
        defer {
            tray.hide()
            for note in workspace.notes.values { note.window?.orderOut(nil) }
            preferences.removePersistentDomain(forName: name)
        }
        try body(workspace, tray, preferences)
    }

    func testWorkspaceToggleShowsAndHidesEveryPaperWithoutChangingLayoutOrSelection() throws {
        try withWorkspace { workspace, tray, preferences in
            let ruled = try editor(kind: .ruled)
            let checklist = try editor()
            ruled.editor.insertText("普通纸", replacementRange: ruled.editor.selectedRange())
            checklist.editor.insertText("待办纸", replacementRange: checklist.editor.selectedRange())
            workspace.add(ruled)
            workspace.add(checklist)
            ruled.window?.setFrameOrigin(NSPoint(x: 150, y: 160))
            checklist.window?.setFrameOrigin(NSPoint(x: 250, y: 260))
            let frames = [ruled.window!.frame, checklist.window!.frame]
            let selections = [ruled.editor.selectedRange(), checklist.editor.selectedRange()]
            let documents = [ruled.noteDocument, checklist.noteDocument]
            for _ in 0..<3 {
                try workspace.toggle(activate: false)
                XCTAssertTrue(workspace.isVisible)
                XCTAssertTrue(tray.window!.isVisible)
                XCTAssertTrue(ruled.window!.isVisible)
                XCTAssertTrue(checklist.window!.isVisible)
                XCTAssertEqual([ruled.window!.frame, checklist.window!.frame], frames)
                XCTAssertEqual([ruled.editor.selectedRange(), checklist.editor.selectedRange()], selections)
                try workspace.toggle(activate: false)
                XCTAssertFalse(workspace.isVisible)
                XCTAssertFalse(tray.window!.isVisible)
                XCTAssertFalse(ruled.window!.isVisible)
                XCTAssertFalse(checklist.window!.isVisible)
                XCTAssertEqual([ruled.noteDocument, checklist.noteDocument], documents)
            }
            XCTAssertEqual(store.loadAll().notes.count, 2)
            XCTAssertFalse(preferences.bool(forKey: "workspaceVisible"))
        }
    }

    private func withFocusedWorkspace(_ body: (PaperWorkspace, ToolTrayController) async throws -> Void) async rethrows {
        let name = "local.papertray.focus-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        let tray = ToolTrayController(glass: glass)
        let workspace = PaperWorkspace(tray: tray, preferences: preferences)
        defer {
            tray.hide()
            for note in workspace.notes.values { note.window?.orderOut(nil) }
            preferences.removePersistentDomain(forName: name)
        }
        try await body(workspace, tray)
    }

    private func waitForKeyWindow(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) async throws {
        // App activation and WindowServer focus changes complete on the run loop.
        for _ in 0..<100 {
            if window.isKeyWindow { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(window.isKeyWindow, "Window did not receive keyboard focus", file: file, line: line)
    }

    func testWorkspaceToggleRestoresLastPaperAndTypingAtItsSelection() async throws {
        try await withFocusedWorkspace { workspace, tray in
            let ruled = try editor(kind: .ruled)
            let checklist = try editor()
            ruled.editor.insertText("前后", replacementRange: ruled.editor.selectedRange())
            checklist.editor.insertText("待办", replacementRange: checklist.editor.selectedRange())
            workspace.add(ruled)
            workspace.add(checklist)
            workspace.show(focusing: ruled.noteDocument.id)
            try await waitForKeyWindow(ruled.window!)
            // Both editors already have a first responder; switching windows must
            // still update the remembered paper, without refocusing the text view.
            for note in [checklist, ruled, checklist, ruled] {
                let window = try XCTUnwrap(note.window)
                window.makeKeyAndOrderFront(nil)
                try await waitForKeyWindow(window)
                XCTAssertTrue(workspace.lastFocusedNote === note)
                let selection = NSRange(location: 1, length: 0)
                note.editor.setSelectedRange(selection)
                let frame = window.frame
                let scrollOrigin = note.editor.enclosingScrollView?.contentView.bounds.origin
                // Visiting the tray must not replace the last paper.
                tray.window?.makeKeyAndOrderFront(nil)
                try workspace.toggle()
                try workspace.toggle()
                try await waitForKeyWindow(window)
                XCTAssertTrue(window.isKeyWindow)
                XCTAssertTrue(window.firstResponder === note.editor)
                XCTAssertEqual(note.editor.selectedRange(), selection)
                XCTAssertEqual(window.frame, frame)
                XCTAssertEqual(note.editor.enclosingScrollView?.contentView.bounds.origin, scrollOrigin)
                XCTAssertFalse(tray.window!.isKeyWindow)
                XCTAssertTrue(workspace.lastFocusedNote === note)
            }
            let window = try XCTUnwrap(ruled.window)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: "x", charactersIgnoringModifiers: "x",
                                                      isARepeat: false, keyCode: 7))
            window.sendEvent(event)
            XCTAssertEqual(ruled.editor.string, "前x后")
            ruled.editor.cancelOperation(nil)
            XCTAssertFalse(workspace.isVisible)
            try workspace.toggle()
            try await waitForKeyWindow(window)
            XCTAssertTrue(window.firstResponder === ruled.editor)
            XCTAssertEqual(ruled.editor.selectedRange(), NSRange(location: 2, length: 0))
        }
    }

    func testExplicitPaperSelectionOverridesRecallAndDeletedPaperIsNotRestored() async throws {
        try await withFocusedWorkspace { workspace, tray in
            let a = try editor(kind: .ruled)
            let b = try editor()
            workspace.add(a)
            workspace.add(b)
            workspace.show(focusing: a.noteDocument.id)
            try await waitForKeyWindow(a.window!)
            workspace.show(focusing: b.noteDocument.id)
            try await waitForKeyWindow(b.window!)
            try workspace.toggle()
            try workspace.toggle()
            try await waitForKeyWindow(b.window!)
            try b.permanentlyDelete()
            try workspace.toggle()
            try workspace.toggle()
            try await waitForKeyWindow(a.window!)
            XCTAssertTrue(a.window!.firstResponder === a.editor)
            XCTAssertFalse(b.window!.isVisible)
            try a.permanentlyDelete()
            try workspace.toggle()
            try workspace.toggle()
            try await waitForKeyWindow(tray.window!)
            XCTAssertTrue(workspace.notes.isEmpty)
        }
    }

    func testWorkspacePresentationWithoutActivationDoesNotStealFocus() async throws {
        try await withFocusedWorkspace { workspace, _ in
            let note = try editor(kind: .ruled)
            workspace.add(note)
            workspace.show(focusing: note.noteDocument.id)
            try await waitForKeyWindow(note.window!)
            try workspace.hide()
            let other = try editor()
            other.open()
            try await waitForKeyWindow(other.window!)
            workspace.show(activate: false)
            XCTAssertTrue(other.window!.isKeyWindow)
            XCTAssertFalse(note.window!.isKeyWindow)
            try workspace.hide()
            workspace.show()
            try await waitForKeyWindow(note.window!)
        }
    }

    func testWorkspaceWindowsDisableAutomaticAnimationBeforeFirstShowAndAfterToggling() throws {
        try withWorkspace { workspace, tray, _ in
            let ruled = try editor(kind: .ruled)
            let checklist = try editor()
            workspace.add(ruled)
            workspace.add(checklist)
            let windows = try [tray.window, ruled.window, checklist.window].map { try XCTUnwrap($0) }
            for window in windows { XCTAssertEqual(window.animationBehavior, .none) }
            for _ in 0..<3 {
                try workspace.toggle(activate: false)
                for window in windows {
                    XCTAssertTrue(window.isVisible)
                    XCTAssertEqual(window.animationBehavior, .none)
                }
                try workspace.toggle(activate: false)
                for window in windows {
                    XCTAssertFalse(window.isVisible)
                    XCTAssertEqual(window.animationBehavior, .none)
                }
            }
        }
    }

    func testPaperDragPreviewDisablesAutomaticAnimation() throws {
        try withWorkspace { _, tray, _ in
            let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
            tray.press(kind: .ruled, point: NSPoint(x: 100, y: 100), anchor: .zero)
            tray.move(to: NSPoint(x: 130, y: 130))
            let preview = try XCTUnwrap(NSApp.windows.first {
                !existing.contains(ObjectIdentifier($0)) && $0.ignoresMouseEvents
            })
            XCTAssertEqual(preview.animationBehavior, .none)
            XCTAssertTrue(preview.isVisible)
            tray.hide()
            XCTAssertFalse(preview.isVisible)
        }
    }

    func testWorkspaceHandlesZeroNotesAndNewNotesWhileHidden() throws {
        try withWorkspace { workspace, tray, _ in
            try workspace.toggle(activate: false)
            XCTAssertTrue(tray.window!.isVisible)
            try workspace.toggle(activate: false)
            let note = try editor()
            workspace.add(note)
            XCTAssertFalse(note.window!.isVisible)
            try workspace.toggle(activate: false)
            XCTAssertTrue(note.window!.isVisible)
            XCTAssertTrue(tray.window!.isVisible)
        }
    }

    func testDragCreationKeepsTheWorkspaceTogether() throws {
        try withWorkspace { workspace, tray, _ in
            workspace.show(activate: false)
            let screen = try XCTUnwrap(NSScreen.screens.first)
            let drop = NSPoint(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30)
            var created = false
            tray.onCreate = { kind, _, _ in
                do {
                    let note = try self.editor(kind: kind)
                    workspace.add(note)
                    created = true
                    return true
                } catch { XCTFail(error.localizedDescription); return false }
            }
            let start = NSPoint(x: tray.window!.frame.midX, y: tray.window!.frame.midY)
            tray.press(kind: .checklist, point: start, anchor: .zero)
            tray.move(to: drop)
            tray.release(at: drop)
            XCTAssertTrue(created)
            XCTAssertTrue(workspace.isVisible)
            XCTAssertTrue(tray.window!.isVisible)
            XCTAssertTrue(workspace.notes.values.allSatisfy { $0.window!.isVisible })
        }
    }

    func testEscOrTrayDismissalHidesTheWholeWorkspaceNotDeletePaper() throws {
        try withWorkspace { workspace, tray, _ in
            let a = try editor(kind: .ruled)
            let b = try editor()
            workspace.add(a)
            workspace.add(b)
            workspace.show(activate: false)
            a.editor.cancelOperation(nil)
            XCTAssertNil(a.window?.attachedSheet)
            XCTAssertFalse(workspace.isVisible)
            XCTAssertFalse(tray.window!.isVisible)
            XCTAssertFalse(b.window!.isVisible)
            XCTAssertEqual(workspace.notes.count, 2)
            XCTAssertFalse(a.isDeleted)
            workspace.show(activate: false)
            tray.onDismiss?()
            XCTAssertFalse(workspace.isVisible)
            XCTAssertFalse(a.window!.isVisible)
            XCTAssertFalse(b.window!.isVisible)
        }
    }

    func testFailedWorkspaceFlushDoesNotPartiallyHideWindows() throws {
        try withWorkspace { workspace, tray, preferences in
            let a = try editor(kind: .ruled)
            let b = try editor()
            workspace.add(a)
            workspace.add(b)
            workspace.show(activate: false)
            a.editor.insertText("不能丢", replacementRange: a.editor.selectedRange())
            let directory = root.appendingPathComponent("notes")
            try FileManager.default.removeItem(at: directory)
            try Data("blocked".utf8).write(to: directory)
            XCTAssertThrowsError(try workspace.hide())
            XCTAssertTrue(workspace.isVisible)
            XCTAssertTrue(preferences.bool(forKey: "workspaceVisible"))
            XCTAssertTrue(tray.window!.isVisible)
            XCTAssertTrue(a.window!.isVisible)
            XCTAssertTrue(b.window!.isVisible)
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try workspace.hide()
            XCTAssertFalse(workspace.isVisible)
            XCTAssertEqual(store.loadAll().notes.first?.content, a.noteDocument.content)
        }
    }

    func testWorkspaceVisibilityRestoresAsOneStateAndMigratesLegacyFlags() throws {
        try withWorkspace { workspace, tray, preferences in
            let note = try editor(kind: .ruled)
            workspace.add(note)
            workspace.restoreVisibility(legacyVisible: true, activate: false)
            XCTAssertTrue(note.window!.isVisible)
            XCTAssertTrue(tray.window!.isVisible)
            try workspace.hide()
            let nextTray = ToolTrayController(glass: glass)
            defer { nextTray.hide() }
            let restored = PaperWorkspace(tray: nextTray, preferences: preferences)
            restored.add(note)
            restored.restoreVisibility(legacyVisible: true, activate: false)
            XCTAssertFalse(restored.isVisible, "Persisted group state takes precedence over old per-note flags")
            XCTAssertFalse(note.window!.isVisible)
            try restored.toggle(activate: false)
            XCTAssertTrue(note.window!.isVisible)
            XCTAssertTrue(nextTray.window!.isVisible)
            try restored.hide()
        }
    }

    func testImmediateDeletionRemovesPaperFromWorkspaceAndItNeverTogglesBack() throws {
        let name = "local.papertray.workspace-delete-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        let tray = ToolTrayController(glass: glass)
        let workspace = PaperWorkspace(tray: tray, preferences: preferences)
        defer { tray.hide(); preferences.removePersistentDomain(forName: name) }
        let removed = try editor(kind: .ruled)
        let retained = try editor()
        removed.editor.insertText("立即删除", replacementRange: removed.editor.selectedRange())
        try removed.flush()
        workspace.add(removed)
        workspace.add(retained)
        workspace.show(activate: false)
        let id = removed.noteDocument.id
        preferences.set("old frame", forKey: "frame.\(id)")
        let window = try XCTUnwrap(removed.window)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        button.performClick(nil)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(workspace.isVisible)
        XCTAssertTrue(retained.window!.isVisible)
        XCTAssertTrue(tray.window!.isVisible)
        XCTAssertTrue(removed.isDeleted)
        XCTAssertNil(workspace.notes[id])
        XCTAssertNil(preferences.object(forKey: "frame.\(id)"))
        try workspace.toggle(activate: false)
        try workspace.toggle(activate: false)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(retained.window!.isVisible)
        XCTAssertTrue(tray.window!.isVisible)
        XCTAssertFalse(store.loadAll().notes.contains { $0.id == id })
        try workspace.hide()
    }
}
