import SwiftUI

struct MainStudioView: View {
    @EnvironmentObject private var viewModel: StudioViewModel
    @EnvironmentObject private var presetStore: PresetStore

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
        }
        .alert(item: errorWrapperBinding) { wrapper in
            Alert(
                title: Text("Camera Error"),
                message: Text(wrapper.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var errorWrapperBinding: Binding<ErrorWrapper?> {
        Binding<ErrorWrapper?>(
            get: {
                guard let message = viewModel.errorMessage else { return nil }
                return ErrorWrapper(message: message)
            },
            set: { newValue in
                if newValue == nil {
                    viewModel.errorMessage = nil
                }
            }
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer()

            Text(viewModel.isSessionRunning ? "Live" : "Stopped")
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

    private struct ErrorWrapper: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }
}
