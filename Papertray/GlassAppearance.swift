import AppKit
import Combine

/// The only persisted owner of surface styling; document contents never depend on it.
struct GlassStyle: Codable, Equatable {
    enum Material: String, Codable, CaseIterable {
        case sidebar, hud, underWindow
        var title: String {
            switch self {
            case .sidebar: return "侧栏"
            case .hud: return "悬浮面板"
            case .underWindow: return "窗口底衬"
            }
        }
        var appKit: NSVisualEffectView.Material {
            switch self {
            case .sidebar: return .sidebar
            case .hud: return .hudWindow
            case .underWindow: return .underWindowBackground
            }
        }
    }

    var material: Material = .hud
    var red = 0.20
    var green = 0.23
    var blue = 0.29
    var tintStrength = 0.48
    var grainSize = 0.7
    var grainStrength = 0.045

    var tintColor: NSColor {
        // Keep even bright picker colors dark enough for the fixed white ink.
        let scale = 0.22 / max(0.22, max(red, max(green, blue)))
        return NSColor(srgbRed: red * scale, green: green * scale, blue: blue * scale, alpha: 1)
    }

    func normalized() -> Self {
        var result = self
        let defaults = Self()
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        result.red = clamp(red, 0...1, defaults.red)
        result.green = clamp(green, 0...1, defaults.green)
        result.blue = clamp(blue, 0...1, defaults.blue)
        result.tintStrength = clamp(tintStrength, 0...0.85, defaults.tintStrength)
        result.grainSize = clamp(grainSize, 0.5...2, defaults.grainSize)
        result.grainStrength = clamp(grainStrength, 0...0.16, defaults.grainStrength)
        return result
    }
}

@MainActor
final class GlassPreferences: ObservableObject {
    static let shared = GlassPreferences(defaults: .standard)
    static let key = "glassStyle.v1"
    @Published private(set) var style: GlassStyle
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        style = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(GlassStyle.self, from: $0) }?.normalized() ?? GlassStyle()
    }

    func update(_ value: GlassStyle) {
        let value = value.normalized()
        guard value != style else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key)
        style = value
    }

    func reset() { update(GlassStyle()) }
}

enum PaperPalette {
    static let ink = NSColor.white
    static let rule = NSColor.white.withAlphaComponent(0.16)
    static let border = NSColor.white.withAlphaComponent(0.18)
}

/// A native backdrop plus a non-interactive texture. Editors and controls are siblings,
/// not vibrant children of the material, so white text and original images stay intact.
final class GlassSurface: NSView {
    private let effect = NSVisualEffectView()
    private let texture = GlassTexture()
    private var subscription: AnyCancellable?
    private var accessibilityObserver: NSObjectProtocol?

    init(preferences: GlassPreferences? = nil) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        effect.blendingMode = .behindWindow
        effect.state = .active // Floating notes keep their finish while another app is active.
        for view in [effect, texture] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        subscription = (preferences ?? .shared).$style.sink { [weak self] style in
            self?.effect.material = style.material.appKit
            self?.texture.style = style
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }
        refreshAccessibility()
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private func refreshAccessibility() {
        texture.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effect.isHidden = texture.reduceTransparency
    }

    static func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        if window.styleMask.contains(.titled) { window.styleMask.insert(.fullSizeContentView) }
    }
}

/// Static, seeded noise: no animation, timer, screen capture or per-frame random work.
/// A cached tile is reused across windows and repainted only when AppKit invalidates it.
final class GlassTexture: NSView {
    var style = GlassStyle() { didSet { needsDisplay = true } }
    // Persistent material coordinates, local to this paper. Resizing exposes more
    // of the same material; moving the paper carries that coordinate system along.
    private var materialOrigin = NSPoint.zero
    private var lastWindowFrame: NSRect?
    private var geometryObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        geometryObservers.forEach(NotificationCenter.default.removeObserver)
        geometryObservers.removeAll()
        lastWindowFrame = window?.frame
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            geometryObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMaterialOrigin() }
            })
        }
    }

    deinit {
        geometryObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func updateMaterialOrigin() {
        guard let window else { return }
        let frame = window.frame
        defer { lastWindowFrame = frame }
        guard let previous = lastWindowFrame else { return }
        // During live resize AppKit can deliver movement and sizing separately.
        // Outside it, an unchanged size means an ordinary whole-window move.
        if window.inLiveResize || frame.size != previous.size {
            materialOrigin.x += previous.minX - frame.minX
            materialOrigin.y += previous.minY - frame.minY
            if frame != previous { needsDisplay = true }
        }
    }
    var reduceTransparency = false { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let noise: CGImage = {
        let side = 128
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: side * 4, bitsPerPixel: 32)!
        var seed: UInt32 = 0x50415052
        for y in 0..<side {
            for x in 0..<side {
                seed = seed &* 1664525 &+ 1013904223
                let value = UInt8(seed >> 24)
                let offset = y * bitmap.bytesPerRow + x * 4
                let color: UInt8 = value < 128 ? 0 : 255
                bitmap.bitmapData![offset] = color
                bitmap.bitmapData![offset + 1] = color
                bitmap.bitmapData![offset + 2] = color
                bitmap.bitmapData![offset + 3] = UInt8(min(255, abs(Int(value) - 128) * 2))
            }
        }
        return bitmap.cgImage!
    }()

    override func draw(_ dirtyRect: NSRect) {
        // Also synchronize before painting: do not depend on notification/draw order.
        updateMaterialOrigin()
        style.tintColor.withAlphaComponent(reduceTransparency ? 1 : style.tintStrength).setFill()
        dirtyRect.fill()
        guard !reduceTransparency, style.grainStrength > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clip(to: dirtyRect)
        context.interpolationQuality = .none
        context.setAlpha(style.grainStrength)
        // Place tiles on a persistent view-space grid, not on the graphics
        // context's pattern phase. Each partial redraw uses the same tile rects,
        // even when grain size produces fractional-point tiles.
        let side = 128 * style.grainSize
        let columns = Int(floor((dirtyRect.minX - materialOrigin.x) / side))..<Int(ceil((dirtyRect.maxX - materialOrigin.x) / side))
        let rows = Int(floor((dirtyRect.minY - materialOrigin.y) / side))..<Int(ceil((dirtyRect.maxY - materialOrigin.y) / side))
        for row in rows {
            for column in columns {
                let tile = NSRect(x: materialOrigin.x + Double(column) * side,
                                  y: materialOrigin.y + Double(row) * side, width: side, height: side)
                context.draw(Self.noise, in: tile)
            }
        }
    }
}
