import AppKit

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double

    static let black = RGBA(r: 0, g: 0, b: 0)
    static let white = RGBA(r: 1, g: 1, b: 1)

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = Double(c.redComponent); g = Double(c.greenComponent); b = Double(c.blueComponent)
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Gaussian blur radius in points, 0...maxBlur.
    var blur: Double = 30
    var tint: RGBA = .black
    /// 0...1
    var tintOpacity: Double = 0

    static let maxCount = 5
    static let maxBlur: Double = 80

    static let seeds: [Preset] = [
        Preset(name: "Cover", blur: 40, tint: .white, tintOpacity: 0.08),
        Preset(name: "Focus", blur: 10, tint: .black, tintOpacity: 0.35),
    ]
}
