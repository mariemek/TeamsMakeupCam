import Foundation
import Combine

// MARK: - MakeupPreset

/// A named, saved snapshot of MakeupSettings that the user can reload.
struct MakeupPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var settings: MakeupSettings
    let createdAt: Date

    init(name: String, settings: MakeupSettings) {
        self.id        = UUID()
        self.name      = name
        self.settings  = settings
        self.createdAt = Date()
    }
}

// MARK: - PresetStore

/// Persists MakeupPresets in UserDefaults and tracks the active preset.
final class PresetStore: ObservableObject {

    private static let presetsKey      = "teamsMakeupCam.presets"
    private static let activePresetKey = "teamsMakeupCam.activePresetID"

    @Published private(set) var presets: [MakeupPreset] = []
    @Published private(set) var activePresetID: UUID?

    var activePreset: MakeupPreset? {
        guard let id = activePresetID else { return nil }
        return presets.first { $0.id == id }
    }

    init() {
        load()
    }

    // MARK: - Mutating

    func save(preset: MakeupPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(preset: MakeupPreset) {
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        persist()
    }

    func setActive(_ preset: MakeupPreset?) {
        activePresetID = preset?.id
        UserDefaults.standard.set(preset?.id.uuidString, forKey: Self.activePresetKey)
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.presetsKey),
           let decoded = try? JSONDecoder().decode([MakeupPreset].self, from: data) {
            presets = decoded
        }
        if let idString = UserDefaults.standard.string(forKey: Self.activePresetKey),
           let uuid = UUID(uuidString: idString) {
            activePresetID = uuid
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }
}
