import SwiftUI

/// Sidebar panel that exposes all makeup controls.
/// Bind `settings` to a `@State` / `@ObservedObject` value in the parent view.
/// Also requires `StudioViewModel` as an environment object for camera selection.
struct ControlsSidebarView: View {
    @EnvironmentObject private var viewModel: StudioViewModel
    @EnvironmentObject private var presetStore: PresetStore
    @Binding var settings: MakeupSettings

    @State private var showSaveSheet = false
    @State private var showPresetsPanel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Camera ───────────────────────────────────────────────────
                sectionHeader("Camera")
                cameraPickerRow
                    .padding(.bottom, 12)

                Divider().padding(.horizontal, 16)

                // ── My Look ──────────────────────────────────────────────────
                sectionHeader("My Look")
                presetActionsRow
                    .padding(.bottom, 12)

                Divider().padding(.horizontal, 16)

                // ── Skin ─────────────────────────────────────────────────────
                sectionHeader("Skin")
                intensityRow(
                    label: "Smoothing",
                    systemImage: "wand.and.stars",
                    value: $settings.smoothingStrength
                )
                .padding(.bottom, 8)

                Divider().padding(.horizontal, 16)

                // ── Brows ────────────────────────────────────────────────────
                sectionHeader("Brows")
                colorRow(
                    label: "Brow color",
                    systemImage: "eyebrow",
                    color: $settings.browColor
                )
                intensityRow(
                    label: "Intensity",
                    systemImage: "slider.horizontal.3",
                    value: $settings.browIntensity
                )
                intensityRow(
                    label: "Thickness",
                    systemImage: "slider.horizontal.3",
                    value: $settings.browThickness
                )
                signedSliderRow(
                    label: "Arch",
                    systemImage: "slider.horizontal.3",
                    value: $settings.browArchAmount,
                    range: -1...1
                )
                signedSliderRow(
                    label: "Tail Lift",
                    systemImage: "slider.horizontal.3",
                    value: $settings.browTailLift,
                    range: -1...1
                )
                signedSliderRow(
                    label: "Height",
                    systemImage: "slider.horizontal.3",
                    value: $settings.browHeightOffset,
                    range: -1...1
                )
                .padding(.bottom, 8)

                Divider().padding(.horizontal, 16)

                // ── Eyes ─────────────────────────────────────────────────────
                sectionHeader("Eyes")
                intensityRow(
                    label: "Eyeliner",
                    systemImage: "eye",
                    value: $settings.eyelinerIntensity
                )
                intensityRow(
                    label: "Lashes",
                    systemImage: "eye.fill",
                    value: $settings.lashesIntensity
                )
                .padding(.bottom, 8)

                Divider().padding(.horizontal, 16)

                // ── Lips ─────────────────────────────────────────────────────
                sectionHeader("Lips")
                colorRow(
                    label: "Lipstick color",
                    systemImage: "paintpalette",
                    color: $settings.lipstickColor
                )
                intensityRow(
                    label: "Lipstick opacity",
                    systemImage: "slider.horizontal.3",
                    value: $settings.lipstickOpacity
                )
                colorRow(
                    label: "Lip liner color",
                    systemImage: "pencil.tip",
                    color: $settings.lipLinerColor
                )
                intensityRow(
                    label: "Lip liner",
                    systemImage: "slider.horizontal.3",
                    value: $settings.lipLinerIntensity
                )
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 240, idealWidth: 260)
        .background(.regularMaterial)
        .sheet(isPresented: $showSaveSheet) {
            SavePresetSheet(settings: settings, isPresented: $showSaveSheet)
                .environmentObject(presetStore)
        }
        .sheet(isPresented: $showPresetsPanel) {
            PresetsListView(currentSettings: $settings, isPresented: $showPresetsPanel)
                .environmentObject(presetStore)
        }
    }

    // MARK: - Camera

    private var cameraPickerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera")
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text("Input")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker(
                "",
                selection: Binding(
                    get: { viewModel.selectedCamera?.id ?? "" },
                    set: { newID in
                        if let camera = viewModel.availableCameras.first(where: { $0.id == newID }) {
                            viewModel.selectCamera(camera)
                        }
                    }
                )
            ) {
                ForEach(viewModel.availableCameras) { camera in
                    Text(camera.localizedName).tag(camera.id)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    // MARK: - Preset actions row

    private var presetActionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Active preset name (if any)
            if let active = presetStore.activePreset {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(active.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                Button {
                    showPresetsPanel = true
                } label: {
                    Label("Load", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button {
                    settings = MakeupSettings()
                    presetStore.setActive(nil)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset to defaults")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func colorRow(
        label: String,
        systemImage: String,
        color: Binding<Color>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(label)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)

            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36, height: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func intensityRow(
        label: String,
        systemImage: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                Text(label)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if value.wrappedValue < 0.005 {
                        Text("Off")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("\(Int(value.wrappedValue * 100)) %")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(width: 36, alignment: .trailing)
            }

            Slider(value: value, in: 0...1)
                .padding(.leading, 28)
                .tint(.primary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func signedSliderRow(
        label: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                Text(label)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            Slider(value: value, in: range)
                .padding(.leading, 28)
                .tint(.primary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

#Preview {
    ControlsSidebarView(settings: .constant(MakeupSettings()))
        .environmentObject(StudioViewModel())
        .environmentObject(PresetStore())
        .frame(height: 680)
}
