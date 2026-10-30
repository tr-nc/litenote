import AppKit
import XCTest
@testable import litenote

extension EditorAndStorageTests {
    func testBottomResizeKeepsExistingTextureInPlace() throws {
        let (window, texture, patch) = try textureWindow()
        let before = try grainPatch(texture, at: patch)
        var frame = window.frame
        frame.origin.y -= 37
        frame.size.height += 37 // Move the bottom edge; the top stays still.
        window.setFrame(frame, display: true)
        XCTAssertTrue(before == (try grainPatch(texture, at: patch)),
                      "Bottom-edge resizing must not slide grain within the existing paper")
    }

    func testTopResizeKeepsExistingTextureInPlace() throws {
        let (window, texture, patch) = try textureWindow()
        let before = try grainPatch(texture, at: patch)
        var frame = window.frame
        frame.size.height += 31 // Move the top edge; the bottom stays still.
        window.setFrame(frame, display: true)
        XCTAssertTrue(before == (try grainPatch(texture, at: patch)),
                      "Top-edge resizing must not slide grain within the existing paper")
    }

    func testMovingTheWholeWindowCarriesItsTextureWithIt() throws {
        let (window, texture, patch) = try textureWindow()
        let before = try grainPatch(texture, at: patch)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 19, y: window.frame.minY + 23))
        XCTAssertTrue(before == (try grainPatch(texture, at: patch.offsetBy(dx: 19, dy: 23))),
                      "Texture belongs to the paper, not the desktop")
    }

    func testAllEdgesAndCornersPreserveTheOverlapAtDifferentGrainSizes() throws {
        for grainSize in [0.5, 0.7, 1.0, 1.35, 2.0] {
            let (window, texture, patch) = try textureWindow(grainSize: grainSize)
            defer { window.orderOut(nil) }
            let originalFrame = window.frame
            let before = try grainPatch(texture, at: patch)
            let changes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (0, -37, 0, 37), (0, 0, 0, 31), // bottom, top
                (-29, 0, 29, 0), (0, 0, 23, 0), // left, right
                (-17, -19, 17, 19), (0, -13, 11, 13), // bottom corners
                (-11, 0, 11, 17), (0, 0, 13, 19) // top corners
            ]
            for (dx, dy, dw, dh) in changes {
                var frame = window.frame
                frame.origin.x += dx
                frame.origin.y += dy
                frame.size.width += dw
                frame.size.height += dh
                window.setFrame(frame, display: true)
                XCTAssertTrue(before == (try grainPatch(texture, at: patch)),
                              "Overlap changed at grain size \(grainSize), edge delta \((dx, dy, dw, dh))")
            }
            window.setFrame(originalFrame, display: true)
            XCTAssertTrue(before == (try grainPatch(texture, at: patch)), "Shrinking back must not reset the material")
        }
    }

    func testMovementBetweenResizesAndWhileHiddenDoesNotPinGrainToTheScreen() throws {
        let (window, texture, patch) = try textureWindow(grainSize: 0.7)
        let before = try grainPatch(texture, at: patch)
        var frame = window.frame
        frame.origin.y -= 27
        frame.size.height += 27
        window.setFrame(frame, display: true)
        for hidden in [false, true] {
            if hidden { window.orderOut(nil) }
            window.setFrameOrigin(NSPoint(x: window.frame.minX + 13, y: window.frame.minY + 17))
            // Resize before redrawing/showing, to catch stale geometry snapshots.
            frame = window.frame
            frame.origin.x -= 21
            frame.size.width += 21
            window.setFrame(frame, display: false)
        }
        window.orderFront(nil)
        XCTAssertTrue(before == (try grainPatch(texture, at: patch.offsetBy(dx: 26, dy: 34))),
                      "Moving between resizes must carry the material's accumulated offset")
    }

    func testPartialRedrawUsesTheSameTextureCoordinatesAsAFullRedraw() throws {
        let (window, texture, patch) = try textureWindow(grainSize: 0.7)
        var frame = window.frame
        frame.origin.x -= 17
        frame.origin.y -= 23
        frame.size.width += 17
        frame.size.height += 23
        window.setFrame(frame, display: true)
        let full = try grainPatch(texture, at: patch)
        let partial = try grainPatch(texture, at: patch, partial: true)
        XCTAssertTrue(full == partial,
                      "Dirty-rectangle drawing must not restart the noise pattern")
    }

    func testSmallPixelAlignedResizeStepsDoNotAccumulateTextureDrift() throws {
        let (window, texture, patch) = try textureWindow(grainSize: 0.7)
        let before = try grainPatch(texture, at: patch)
        let pixel = 1 / window.backingScaleFactor
        for steps in [1.0, 3.0, 1.0, -1.0, -3.0, -1.0] {
            let delta = steps * pixel
            var frame = window.frame
            frame.origin.x -= delta
            frame.origin.y -= delta
            frame.size.width += delta
            frame.size.height += delta
            window.setFrame(frame, display: true)
            XCTAssertTrue(before == (try grainPatch(texture, at: patch)), "One-pixel drags must not accumulate phase errors")
        }
    }

    func testNewlyExposedAreaContinuesTheSameMaterialInsteadOfStretchingAnOldSnapshot() throws {
        let (window, texture, _) = try textureWindow()
        let newPatch = NSRect(x: window.frame.midX - 24, y: window.frame.minY - 72, width: 48, height: 48)
        // With one-point grain the cached tile repeats every 128pt. Its expected
        // continuation can be sampled inside the old paper before expanding it.
        let expected = try grainPatch(texture, at: newPatch.offsetBy(dx: 0, dy: 128))
        var frame = window.frame
        frame.origin.y -= 96
        frame.size.height += 96
        window.setFrame(frame, display: true)
        XCTAssertTrue(expected == (try grainPatch(texture, at: newPatch)), "New paper must reveal the same continuous tile grid")
    }

    func testTextureCoordinatesSurviveDisabledGrainAndReducedTransparency() throws {
        let (window, texture, patch) = try textureWindow(grainSize: 0.7)
        let before = try grainPatch(texture, at: patch)
        let style = texture.style
        texture.style.grainStrength = 0
        texture.reduceTransparency = true
        var frame = window.frame
        frame.origin.y -= 43
        frame.size.height += 43
        window.setFrame(frame, display: true)
        texture.reduceTransparency = false
        texture.style = style
        XCTAssertTrue(before == (try grainPatch(texture, at: patch)), "Hidden grain must keep tracking the paper geometry")
    }

    private func textureWindow(grainSize: Double = 1) throws -> (NSWindow, GlassTexture, NSRect) {
        var style = GlassStyle()
        style.grainSize = grainSize
        style.grainStrength = 0.16
        glass.update(style)
        let controller = try editor()
        let window = try XCTUnwrap(controller.window)
        let visible = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        window.setFrameOrigin(NSPoint(x: visible.midX - 180, y: visible.midY - 220))
        controller.present(focus: false)
        let texture = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? GlassTexture }.first)
        // Isolate the app-owned grain from WindowServer backdrop changes and the text.
        texture.reduceTransparency = false
        let patch = NSRect(x: window.frame.midX - 24, y: window.frame.midY - 24, width: 48, height: 48)
        return (window, texture, patch)
    }

    private func grainPatch(_ texture: GlassTexture, at screenRect: NSRect, partial: Bool = false) throws -> Data {
        let window = try XCTUnwrap(texture.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let rect = texture.convert(window.convertFromScreen(screenRect), from: nil)
        XCTAssertTrue(texture.bounds.contains(rect))
        let capture = partial ? rect : texture.bounds
        let bitmap = try XCTUnwrap(texture.bitmapImageRepForCachingDisplay(in: capture))
        texture.cacheDisplay(in: capture, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / capture.width
        let x = Int((rect.minX - capture.minX) * scale)
        let y = Int((capture.maxY - rect.maxY) * scale)
        let width = Int(rect.width * scale)
        let height = Int(rect.height * scale)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        let pixelBytes = bitmap.bitsPerPixel / 8
        var patch = Data()
        for row in y..<y + height {
            patch.append(bytes.advanced(by: row * bitmap.bytesPerRow + x * pixelBytes), count: width * pixelBytes)
        }
        return patch
    }
}
