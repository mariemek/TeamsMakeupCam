import SwiftUI

struct MainStudioView: View {
    @EnvironmentObject private var viewModel: StudioViewModel
    @StateObject private var presetStore = PresetStore()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
        }
        .alert(item: Binding(
            get: { viewModel.errorMessage.map { ErrorWrapper(message: $0) } },
            set: { _ in viewModel.errorMessage = nil }
        )) { wrapper in
            Alert(
                title: Text("Camera Error"),
                message: Text(wrapper.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: viewModel.makeupSettings) { _ in
            viewModel.syncMakeupSettingsToProcessor()
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Text(viewModel.isSessionRunning ? "● Live" : "○ Stopped")
                .foregroundColor(viewModel.isSessionRunning ? .green : .secondary)
                .font(.caption)
        }
        .padding()
    }

    private var content: some View {
        HStack(spacing: 0) {
            ControlsSidebarView(settings: $viewModel.makeupSettings)
                .frame(width: 260)
                .background(.regularMaterial)
                .environmentObject(viewModel)
                .environmentObject(presetStore)

            Divider()

            CameraPreviewView(
                session: viewModel.captureSession,
                landmarks: viewModel.debugLandmarks,
                makeupSettings: viewModel.makeupSettings,
                showDebugLandmarks: false,
                processedFrame: viewModel.processedFrame
            )
            .background(Color.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct ErrorWrapper: Identifiable {
        let id = UUID()
        let message: String
    }
}
