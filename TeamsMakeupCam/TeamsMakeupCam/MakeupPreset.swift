import Foundation
import Combine

struct MakeupPreset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var settings: MakeupSettings
}

// MARK: - Preset Store

final class PresetStore: ObservableObject {
    @Published var presets: [MakeupPreset] = []
    @Published var activePresetID: UUID? = nil

    private let saveKey   = "TeamsMakeupCam_Presets"
    private let activeKey = "TeamsMakeupCam_ActivePreset"

    init() { load() }

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
        UserDefaults.standard.set(preset?.id.uuidString, forKey: activeKey)
    }

    var activePreset: MakeupPreset? {
        guard let id = activePresetID else { return nil }
        return presets.first { $0.id == id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([MakeupPreset].self, from: data) {
            presets = decoded
        }
        if let str = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: str) {
            activePresetID = id
        }
    }
}
