import AppKit
import Combine

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value (device-independent bits only).
    var modifiers: UInt
    var display: String

    // ⇧⌘/
    static let `default` = KeyCombo(
        keyCode: 44,
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        display: "⇧⌘/"
    )

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
}

final class Store: ObservableObject {
    static let shared = Store()

    @Published var presets: [Preset] { didSet { save() } }
    @Published var defaultID: UUID { didSet { save() } }
    @Published var hotKey: KeyCombo { didSet { save() } }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let presets = "presets.v2"
        static let defaultID = "defaultPresetID.v2"
        static let hotKey = "hotKey.v1"
    }

    private init() {
        let decoder = JSONDecoder()
        let loaded = defaults.data(forKey: Keys.presets)
            .flatMap { try? decoder.decode([Preset].self, from: $0) } ?? []
        let presets = loaded.isEmpty ? Preset.seeds : Array(loaded.prefix(Preset.maxCount))
        self.presets = presets

        let storedDefault = defaults.string(forKey: Keys.defaultID).flatMap(UUID.init(uuidString:))
        self.defaultID = presets.contains { $0.id == storedDefault } ? storedDefault! : presets[0].id

        self.hotKey = defaults.data(forKey: Keys.hotKey)
            .flatMap { try? decoder.decode(KeyCombo.self, from: $0) } ?? .default
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(presets) { defaults.set(data, forKey: Keys.presets) }
        defaults.set(defaultID.uuidString, forKey: Keys.defaultID)
        if let data = try? encoder.encode(hotKey) { defaults.set(data, forKey: Keys.hotKey) }
    }

    func preset(_ id: UUID?) -> Preset {
        presets.first { $0.id == id } ?? presets.first { $0.id == defaultID } ?? presets[0]
    }

    var canAdd: Bool { presets.count < Preset.maxCount }
    var canDelete: Bool { presets.count > 1 }

    @discardableResult
    func addPreset(copying source: Preset) -> Preset? {
        guard canAdd else { return nil }
        var p = source
        p.id = UUID()
        p.name = uniqueName(from: source.name)
        presets.append(p)
        return p
    }

    func deletePreset(_ id: UUID) {
        guard canDelete else { return }
        presets.removeAll { $0.id == id }
        if !presets.contains(where: { $0.id == defaultID }) { defaultID = presets[0].id }
    }

    func resetHotKey() { hotKey = .default }

    private func uniqueName(from base: String) -> String {
        let names = Set(presets.map(\.name))
        var n = 2
        var candidate = "\(base) \(n)"
        while names.contains(candidate) { n += 1; candidate = "\(base) \(n)" }
        return candidate
    }
}
