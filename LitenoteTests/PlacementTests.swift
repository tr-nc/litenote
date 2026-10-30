import XCTest
@testable import Litenote

final class PlacementTests: XCTestCase {
    func testPaperRemainsReachableOnNegativeAndVerticallyStackedDisplays() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900),
                       NSRect(x: -1920, y: -100, width: 1920, height: 1080),
                       NSRect(x: 0, y: 900, width: 1440, height: 900)]
        for screen in screens {
            for frame in [NSRect(x: -3000, y: -1000, width: 360, height: 440),
                          NSRect(x: 3000, y: 3000, width: 360, height: 440)] {
                let constrained = Placement.constrain(frame, to: screen)
                XCTAssertTrue(screen.contains(constrained))
                XCTAssertEqual(constrained.size, frame.size)
            }
        }
    }

    func testOversizedPaperFitsTheRemainingScreenAfterDisconnect() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let constrained = Placement.constrain(NSRect(x: -2000, y: 1000, width: 1600, height: 1200), to: visible)
        XCTAssertEqual(constrained, visible)
    }
}
