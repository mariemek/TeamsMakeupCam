import SwiftUI

@main
struct TeamsMakeupCamApp: App {
    @StateObject private var viewModel = StudioViewModel()

    init() {
        SidecarLauncher.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
