import Foundation
import Combine
import SwiftUI
import AppKit

struct MakeupPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var settings: MakeupSettings
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        settings: MakeupSettings,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case settings
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        let snapshot = try container.decode(MakeupSettingsSnapshot.self, forKey: .settings)
        settings = snapshot.makeupSettings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(MakeupSettingsSnapshot(settings: settings), forKey: .settings)
    }

    static func == (lhs: MakeupPreset, rhs: MakeupPreset) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.createdAt == rhs.createdAt &&
        MakeupSettingsSnapshot(settings: lhs.settings) == MakeupSettingsSnapshot(settings: rhs.settings)
    }
}

final class PresetStore: ObservableObject {
    private static let presetsKey = "makeup_presets_v2"
    private static let activePresetIDKey = "active_makeup_preset_id_v2"

    @Published private(set) var presets: [MakeupPreset] = []
    @Published private(set) var activePresetID: UUID?

    var activePreset: MakeupPreset? {
        guard let activePresetID else { return nil }
        return presets.first(where: { $0.id == activePresetID })
    }

    init() {
        load()
    }

    func savePreset(name: String, settings: MakeupSettings) {
        let preset = MakeupPreset(name: name, settings: settings)
        presets.insert(preset, at: 0)
        persist()
    }

    func upsertPreset(_ preset: MakeupPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        persist()
    }

    func deletePreset(_ preset: MakeupPreset) {
        presets.removeAll { $0.id == preset.id }

        if activePresetID == preset.id {
            activePresetID = nil
        }

        persist()
    }

    func setActive(_ preset: MakeupPreset?) {
        activePresetID = preset?.id
        persist()
    }

    func clearAll() {
        presets.removeAll()
        activePresetID = nil
        persist()
    }

    private func load() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.presetsKey) {
            do {
                presets = try JSONDecoder().decode([MakeupPreset].self, from: data)
            } catch {
                presets = []
                print("Failed to decode presets: \(error)")
            }
        } else {
            presets = []
        }

        if let rawID = defaults.string(forKey: Self.activePresetIDKey),
           let uuid = UUID(uuidString: rawID) {
            activePresetID = uuid
        } else {
            activePresetID = nil
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard

        do {
            let data = try JSONEncoder().encode(presets)
            defaults.set(data, forKey: Self.presetsKey)
        } catch {
            print("Failed to encode presets: \(error)")
        }

        defaults.set(activePresetID?.uuidString, forKey: Self.activePresetIDKey)
    }
}

private struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        self.red = srgb.redComponent
        self.green = srgb.greenComponent
        self.blue = srgb.blueComponent
        self.alpha = srgb.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

private struct MakeupSettingsSnapshot: Codable, Equatable {
    var lipstickColor: RGBAColor
    var lipstickOpacity: Double

    var lipLinerColor: RGBAColor
    var lipLinerIntensity: Double

    var smoothingStrength: Double
    var eyelinerIntensity: Double

    init(settings: MakeupSettings) {
        self.lipstickColor = RGBAColor(settings.lipstickNSColor)
        self.lipstickOpacity = settings.lipstickOpacity

        self.lipLinerColor = RGBAColor(settings.lipLinerNSColor)
        self.lipLinerIntensity = settings.lipLinerIntensity

        self.smoothingStrength = settings.smoothingStrength
        self.eyelinerIntensity = settings.eyelinerIntensity
    }

    var makeupSettings: MakeupSettings {
        var settings = MakeupSettings()

        settings.lipstickNSColor = lipstickColor.nsColor
        settings.lipstickOpacity = lipstickOpacity

        settings.lipLinerNSColor = lipLinerColor.nsColor
        settings.lipLinerIntensity = lipLinerIntensity

        settings.smoothingStrength = smoothingStrength
        settings.eyelinerIntensity = eyelinerIntensity

        return settings
    }
}
