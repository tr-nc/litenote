import AppKit
import XCTest
@testable import Papertray

extension EditorAndStorageTests {
    func testInkButtonsRenderTheirActualColorsBeforeAndAfterSelectionInBothAppearances() throws {
        let tray = ToolTrayController(ink: .red)
        defer { tray.hide() }
        let window = try XCTUnwrap(tray.window)
        let content = try XCTUnwrap(window.contentView)
        let buttons = content.subviews.compactMap { $0 as? NSButton }.sorted { $0.tag < $1.tag }
        XCTAssertEqual(buttons.count, Ink.allCases.count)
        var selectedInk: Ink?
        tray.onInk = { selectedInk = $0 }
        var selected = Ink.red
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            tray.show(activate: false)
            for requestedInk in [nil] + Ink.allCases.map(Optional.some) {
                if let requestedInk {
                    selected = requestedInk
                    let selectedButton = try XCTUnwrap(buttons.first { $0.tag == Ink.allCases.firstIndex(of: selected) })
                    selectedButton.performClick(nil)
                    XCTAssertEqual(selectedInk, selected)
                }
                window.display()
                for (button, ink) in zip(buttons, Ink.allCases) {
                    XCTAssertEqual(button.accessibilityLabel(), "\(ink.title)色笔")
                    XCTAssertEqual(button.accessibilityValue() as? String, ink == selected ? "已选择" : "未选择")
                    XCTAssertEqual(button.title, ink == selected ? "◉" : "●")
                    let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
                    button.cacheDisplay(in: button.bounds, to: bitmap)
                    // Render the reference through the same display color profile.
                    let reference = InkColorReference(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                    reference.color = ink.color
                    content.addSubview(reference)
                    defer { reference.removeFromSuperview() }
                    let referenceBitmap = try XCTUnwrap(reference.bitmapImageRepForCachingDisplay(in: reference.bounds))
                    reference.cacheDisplay(in: reference.bounds, to: referenceBitmap)
                    let expected = try XCTUnwrap(referenceBitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
                    var matchingPixels = 0
                    // Sample the glyph region rather than the surrounding bezel.
                    for y in bitmap.pixelsHigh / 4..<bitmap.pixelsHigh * 3 / 4 {
                        for x in bitmap.pixelsWide / 4..<bitmap.pixelsWide * 3 / 4 {
                            guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            if abs(pixel.redComponent - expected.redComponent) < 0.04,
                               abs(pixel.greenComponent - expected.greenComponent) < 0.04,
                               abs(pixel.blueComponent - expected.blueComponent) < 0.04 {
                                matchingPixels += 1
                            }
                        }
                    }
                    XCTAssertGreaterThan(matchingPixels, 20,
                                         "\(appearanceName.rawValue): \(ink) must paint its ink color with \(selected) selected")
                }
            }
        }
    }
}

private final class InkColorReference: NSView {
    var color = NSColor.clear

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
