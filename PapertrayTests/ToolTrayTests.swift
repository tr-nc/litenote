import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testTrayContainsOnlyPaperChoicesAndUsesDarkGlassInBothSystemAppearances() throws {
        let tray = ToolTrayController(glass: glass)
        defer { tray.hide() }
        let window = try XCTUnwrap(tray.window)
        let content = try XCTUnwrap(window.contentView as? GlassSurface)
        XCTAssertTrue(content.subviews.compactMap { $0 as? NSButton }.isEmpty, "No ink controls remain")
        let choices = content.subviews.compactMap { $0 as? PaperChoice }
        XCTAssertEqual(choices.map(\.kind), PaperKind.allCases)
        for systemAppearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: systemAppearance)
            tray.show(activate: false)
            window.display()
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertEqual(window.title, "Papertray", "Retain the window name for accessibility")
            XCTAssertTrue(window.styleMask.contains(.titled), "Retain native titlebar dragging")
            XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
            for choice in choices {
                XCTAssertTrue(content.hitTest(NSPoint(x: choice.frame.midX, y: choice.frame.midY)) === choice)
            }
        }
    }

    func testClickingPaperOnlySelectsAndDoesNotCreateANote() throws {
        let tray = ToolTrayController(glass: glass)
        defer { tray.hide() }
        tray.show(activate: false)
        var created = false
        tray.onCreate = { _, _, _ in created = true; return true }
        let window = try XCTUnwrap(tray.window)
        let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
        tray.press(kind: .checklist, point: point, anchor: .zero)
        tray.release(at: point)
        XCTAssertFalse(created)
        let selected = window.contentView?.subviews.compactMap { $0 as? PaperChoice }.filter(\.selected)
        XCTAssertEqual(selected?.map(\.kind), [.checklist])
        XCTAssertTrue(window.isVisible)
    }
}
