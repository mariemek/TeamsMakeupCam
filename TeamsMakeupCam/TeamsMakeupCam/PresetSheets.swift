import SwiftUI

// MARK: - Save Preset Sheet

struct SavePresetSheet: View {
    let settings: MakeupSettings
    @Binding var isPresented: Bool
    @EnvironmentObject var presetStore: PresetStore
    @State private var name = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Preset")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Give your look a name to load it in future meetings.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            TextField("e.g. Work Meeting, Date Night…", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }

                    presetStore.savePreset(name: trimmed, settings: settings)

                    if let newPreset = presetStore.presets.first {
                        presetStore.setActive(newPreset)
                    }

                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

// MARK: - Presets List View

struct PresetsListView: View {
    @Binding var currentSettings: MakeupSettings
    @Binding var isPresented: Bool
    @EnvironmentObject var presetStore: PresetStore

    @State private var presetToDelete: MakeupPreset? = nil
    @State private var showDeleteConfirm = false

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("My Presets")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(16)

            Divider()

            if presetStore.presets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)

                    Text("No presets saved yet.")
                        .foregroundColor(.secondary)

                    Text("Customize your makeup and tap \"Save\".")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(Array(presetStore.presets.enumerated()), id: \.element.id) { _, preset in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(presetStore.activePresetID == preset.id ? Color.green : Color.clear)
                                .overlay(
                                    Circle()
                                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                )
                                .frame(width: 10, height: 10)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .fontWeight(
                                        presetStore.activePresetID == preset.id
                                        ? .semibold
                                        : .regular
                                    )

                                Text(df.string(from: preset.createdAt))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color(nsColor: preset.settings.lipstickNSColor))
                                    .frame(width: 10, height: 10)

                                Circle()
                                    .fill(Color(nsColor: preset.settings.lipLinerNSColor))
                                    .frame(width: 10, height: 10)
                            }

                            Button("Load") {
                                currentSettings = preset.settings
                                presetStore.setActive(preset)
                                isPresented = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(role: .destructive) {
                                presetToDelete = preset
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 400, height: 460)
        .alert(
            "Delete \"\(presetToDelete?.name ?? "")\"?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                if let preset = presetToDelete {
                    presetStore.deletePreset(preset)
                }
            }

            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
    }
}
