import AppKit

/// All geometry uses AppKit global screen points, including negative coordinates.
enum Placement {
    static func screen(at point: NSPoint, frames: [NSRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    static func constrain(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func noteFrame(at point: NSPoint, anchor: NSPoint, visible: NSRect) -> NSRect {
        constrain(NSRect(x: point.x - anchor.x, y: point.y + anchor.y - 440,
                         width: 360, height: 440), to: visible)
    }
}

struct PlacementGesture {
    enum State: Equatable { case idle, pressed, dragging, committed, cancelled }
    private(set) var state: State = .idle
    private var origin = NSPoint.zero

    mutating func press(at point: NSPoint) { origin = point; state = .pressed }
    mutating func move(to point: NSPoint) {
        guard state == .pressed else { return }
        if hypot(point.x - origin.x, point.y - origin.y) >= 5 { state = .dragging }
    }
    mutating func cancel() { state = .cancelled }
    mutating func release(at point: NSPoint, screens: [NSRect], tray: NSRect) -> Bool {
        guard state == .dragging, !tray.contains(point),
              Placement.screen(at: point, frames: screens) != nil else {
            state = .cancelled
            return false
        }
        state = .committed
        return true
    }
}
