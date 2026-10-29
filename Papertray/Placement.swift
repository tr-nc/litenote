import AppKit

/// All geometry uses AppKit global screen points, including negative coordinates.
enum Placement {
    static func constrain(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

}
