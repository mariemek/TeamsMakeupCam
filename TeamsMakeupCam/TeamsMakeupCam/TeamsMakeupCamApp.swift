import SwiftUI

@main
struct TeamsMakeupCamApp: App {
    @StateObject private var studioViewModel = StudioViewModel()
    @StateObject private var presetStore = PresetStore()

    init() {
        // Launch MediaPipe helper sidecar (port 9001).
        SidecarLauncher.shared.start()
        // Start HTTP virtual camera server (port 9010).
        LocalVirtualCameraServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            MainStudioView()
                .environmentObject(studioViewModel)
                .environmentObject(presetStore)
        }
    }
}
