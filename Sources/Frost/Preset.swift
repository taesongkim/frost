import AppKit

enum FrostMaterial: String, Codable, CaseIterable, Identifiable {
    case hud, popover, sidebar, menu, sheet, underWindow, fullScreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hud: return "HUD"
        case .popover: return "Popover"
        case .sidebar: return "Sidebar"
        case .menu: return "Menu"
        case .sheet: return "Sheet"
        case .underWindow: return "Under Window"
        case .fullScreen: return "Full Screen"
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .hud: return .hudWindow
        case .popover: return .popover
        case .sidebar: return .sidebar
        case .menu: return .menu
        case .sheet: return .sheet
        case .underWindow: return .underWindowBackground
        case .fullScreen: return .fullScreenUI
        }
    }
}

enum FrostAppearance: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

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
    var material: FrostMaterial = .hud
    var appearance: FrostAppearance = .auto
    /// 0...1 — opacity of the frosted layer (0 = clear glass, 1 = full material).
    var blur: Double = 1
    var tint: RGBA = .black
    /// 0...1
    var tintOpacity: Double = 0
    /// 0...1 — how much of the pixelated capture is blended over the frost.
    var pixelMix: Double = 0
    /// Block size in points.
    var pixelSize: Double = 16

    var usesPixelate: Bool { pixelMix > 0.001 }

    static let maxCount = 5

    static let seeds: [Preset] = [
        Preset(name: "Frost"),
        Preset(name: "Focus", material: .hud, appearance: .dark, blur: 1, tint: .black, tintOpacity: 0.35),
        Preset(name: "Privacy", material: .hud, appearance: .auto, blur: 1, tint: .black, tintOpacity: 0.1, pixelMix: 0.85, pixelSize: 18),
    ]
}
