import XCTest
@testable import Papertray

final class PlacementTests: XCTestCase {
    let screens = [
        NSRect(x: 0, y: 0, width: 1440, height: 900),
        NSRect(x: -1920, y: -100, width: 1920, height: 1080),
        NSRect(x: 0, y: 900, width: 1440, height: 900)
    ]
    let tray = NSRect(x: 1160, y: 650, width: 250, height: 200)

    func testUsesGlobalPointsAcrossNegativeAndVerticallyStackedDisplays() {
        XCTAssertEqual(Placement.screen(at: NSPoint(x: -100, y: 20), frames: screens), 1)
        XCTAssertEqual(Placement.screen(at: NSPoint(x: 100, y: 1200), frames: screens), 2)
        XCTAssertNil(Placement.screen(at: NSPoint(x: -2200, y: 0), frames: screens))
        let frame = Placement.noteFrame(at: NSPoint(x: -1200, y: 600),
                                        anchor: NSPoint(x: 30, y: 20), visible: screens[1])
        XCTAssertEqual(frame.origin, NSPoint(x: -1230, y: 180))
    }

    func testEdgePlacementKeepsEntireWindowReachable() {
        for screen in screens {
            let frame = Placement.noteFrame(at: NSPoint(x: screen.maxX - 1, y: screen.minY + 1),
                                            anchor: .zero, visible: screen)
            XCTAssertTrue(screen.contains(frame))
        }
    }

    func testClickAndSubthresholdMovementNeverCreate() {
        var gesture = PlacementGesture()
        gesture.press(at: NSPoint(x: 1200, y: 700))
        gesture.move(to: NSPoint(x: 1202, y: 702))
        XCTAssertFalse(gesture.release(at: NSPoint(x: 500, y: 300), screens: screens, tray: tray))
    }

    func testCrossScreenDropCommitsExactlyOnce() {
        var gesture = PlacementGesture()
        gesture.press(at: NSPoint(x: 1200, y: 700))
        gesture.move(to: NSPoint(x: -800, y: 600))
        XCTAssertTrue(gesture.release(at: NSPoint(x: -800, y: 600), screens: screens, tray: tray))
        XCTAssertFalse(gesture.release(at: NSPoint(x: -800, y: 600), screens: screens, tray: tray))
    }

    func testEscapeReturnToTrayAndDisconnectedScreenCancel() {
        for destination in [NSPoint(x: 1200, y: 700), NSPoint(x: -3000, y: 100)] {
            var gesture = PlacementGesture()
            gesture.press(at: NSPoint(x: 1200, y: 700))
            gesture.move(to: NSPoint(x: 100, y: 100))
            XCTAssertFalse(gesture.release(at: destination, screens: screens, tray: tray))
        }
        var gesture = PlacementGesture()
        gesture.press(at: NSPoint(x: 1200, y: 700))
        gesture.move(to: NSPoint(x: 100, y: 100))
        gesture.cancel()
        XCTAssertFalse(gesture.release(at: NSPoint(x: 100, y: 100), screens: screens, tray: tray))
        gesture.press(at: NSPoint(x: 1200, y: 700))
        gesture.move(to: NSPoint(x: -100, y: 100))
        XCTAssertFalse(gesture.release(at: NSPoint(x: -100, y: 100), screens: [screens[0]], tray: tray))
    }
}
