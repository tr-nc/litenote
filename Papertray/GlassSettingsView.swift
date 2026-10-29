import AppKit
import SwiftUI

struct GlassSettingsView: View {
    @ObservedObject var preferences: GlassPreferences

    private func binding<Value>(_ keyPath: WritableKeyPath<GlassStyle, Value>) -> Binding<Value> {
        Binding(get: { preferences.style[keyPath: keyPath] }, set: { value in
            var style = preferences.style
            style[keyPath: keyPath] = value
            preferences.update(style)
        })
    }

    var body: some View {
        Picker("毛玻璃材质", selection: binding(\.material)) {
            ForEach(GlassStyle.Material.allCases, id: \.self) { material in
                Text(material.title).tag(material)
            }
        }
        .help("使用系统材质改变模糊观感，不是精确的模糊半径。")
        ColorPicker("Tint", selection: Binding(get: {
            Color(nsColor: NSColor(srgbRed: preferences.style.red, green: preferences.style.green,
                                   blue: preferences.style.blue, alpha: 1))
        }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            var style = preferences.style
            style.red = color.redComponent
            style.green = color.greenComponent
            style.blue = color.blueComponent
            preferences.update(style)
        }), supportsOpacity: false)
        .help("保留所选色相，以深色呈现，保证白字清晰。")
        Slider(value: binding(\.tintStrength), in: 0...0.85) { Text("Tint 浓度") }
        Slider(value: binding(\.grainSize), in: 0.5...2) { Text("颗粒大小") }
        Slider(value: binding(\.grainStrength), in: 0...0.16) { Text("颗粒强度") }
        Button("恢复默认外观") { preferences.reset() }
    }
}
