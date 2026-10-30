import AppKit
import SwiftUI
import XCTest
@testable import Litenote

extension EditorAndStorageTests {
    func testGlassPreferencesPersistResetAndRejectInvalidValues() throws {
        let suite = "local.litenote.glass-persistence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = GlassPreferences(defaults: defaults)
        XCTAssertEqual(preferences.style, GlassStyle())
        var style = GlassStyle()
        style.material = .sidebar
        style.red = 1
        style.tintStrength = 0.73
        style.grainSize = 1.8
        style.grainStrength = 0.12
        preferences.update(style)
        XCTAssertEqual(GlassPreferences(defaults: defaults).style, style)
        style.red = .infinity
        style.tintStrength = 20
        style.grainSize = -1
        style.grainStrength = .nan
        preferences.update(style)
        XCTAssertEqual(preferences.style.red, GlassStyle().red)
        XCTAssertEqual(preferences.style.tintStrength, 0.85)
        XCTAssertEqual(preferences.style.grainSize, 0.5)
        XCTAssertEqual(preferences.style.grainStrength, GlassStyle().grainStrength)
        preferences.reset()
        XCTAssertEqual(GlassPreferences(defaults: defaults).style, GlassStyle())
        defaults.set(Data("broken".utf8), forKey: GlassPreferences.key)
        XCTAssertEqual(GlassPreferences(defaults: defaults).style, GlassStyle())
    }

    func testAppearanceUpdatesAllExistingAndNewSurfacesWithoutChangingTheDocument() throws {
        let ruled = try editor(kind: .ruled)
        ruled.editor.insertText("白字与玻璃", replacementRange: ruled.editor.selectedRange())
        ruled.editor.setSelectedRange(NSRange(location: 1, length: 2))
        let document = ruled.noteDocument
        let selection = ruled.editor.selectedRange()
        var style = GlassStyle()
        style.material = .sidebar
        style.red = 0.7
        style.grainSize = 1.5
        glass.update(style)
        let next = try editor(kind: .ruled)
        for controller in [ruled, next] {
            let window = try XCTUnwrap(controller.window)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor, .clear)
            XCTAssertEqual(window.appearance?.name, .darkAqua)
            let surface = try XCTUnwrap(window.contentView as? GlassSurface)
            let effect = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSVisualEffectView }.first)
            XCTAssertEqual(effect.material, .sidebar)
            XCTAssertEqual(effect.blendingMode, .behindWindow)
            XCTAssertEqual(effect.state, .active)
            XCTAssertEqual(surface.subviews.compactMap { $0 as? GlassTexture }.first?.style, style)
            XCTAssertFalse(controller.editor.drawsBackground)
            XCTAssertFalse(try XCTUnwrap(controller.editor.enclosingScrollView).drawsBackground)
            window.contentView?.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(controller.editor.enclosingScrollView)
            XCTAssertLessThanOrEqual(scroll.frame.maxY, window.contentLayoutRect.maxY + 0.5,
                                     "The glass extends under the titlebar, not the text editor")
        }
        XCTAssertEqual(ruled.noteDocument, document)
        XCTAssertEqual(ruled.editor.selectedRange(), selection)
    }

    func testTextureIsStableAdjustableAndNeverTakesInput() throws {
        let texture = GlassTexture(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        var style = GlassStyle()
        style.grainStrength = 0
        texture.style = style
        let flat = try texturePixels(texture)
        style.grainStrength = 0.16
        texture.style = style
        let fine = try texturePixels(texture)
        XCTAssertNotEqual(flat, fine)
        XCTAssertEqual(fine, try texturePixels(texture), "Noise must not flicker on redraw")
        style.grainSize = 2
        texture.style = style
        XCTAssertNotEqual(fine, try texturePixels(texture))
        XCTAssertNil(texture.hitTest(NSPoint(x: 40, y: 40)))
        texture.reduceTransparency = true
        let opaque = try texturePixels(texture)
        style.grainStrength = 0
        texture.style = style
        XCTAssertEqual(opaque, try texturePixels(texture), "Reduced transparency must suppress grain")
        let bitmap = try textureBitmap(texture)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 40, y: 40)).alphaComponent, 1, accuracy: 0.001)
    }

    func testTintKeepsWhiteInkLegibleEvenWithABrightPickerColor() throws {
        var style = GlassStyle()
        style.red = 1
        style.green = 0.8
        style.blue = 0.5
        let color = try XCTUnwrap(style.tintColor.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0.22, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent / color.redComponent, 0.8, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent / color.redComponent, 0.5, accuracy: 0.001)
        XCTAssertEqual(PaperPalette.ink, .white)
    }

    func testGlassSettingsAndDefaultDarkNoteRender() throws {
        glass.reset()
        let controller = try editor(kind: .ruled)
        controller.editor.insertText("深色磨砂玻璃\n白色文字，保留轻盈的横线。", replacementRange: controller.editor.selectedRange())
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.display()
        let surface = try XCTUnwrap(controller.window?.contentView)
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let image = NSImage(size: surface.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "dark-glass-note-view-only"
        attachment.lifetime = .keepAlways
        add(attachment)
        let settings = NSHostingView(rootView: Form { GlassSettingsView(preferences: glass) }.padding(24))
        settings.appearance = NSAppearance(named: .darkAqua)
        settings.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        settings.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(settings.fittingSize.height, 150)
    }

    private func textureBitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func texturePixels(_ view: NSView) throws -> Data {
        let bitmap = try textureBitmap(view)
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
