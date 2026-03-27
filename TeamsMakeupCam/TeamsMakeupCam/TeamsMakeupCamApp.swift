import SwiftUI

@main
struct TeamsMakeupCamApp: App {
    @StateObject private var studioViewModel = StudioViewModel()
    @StateObject private var presetStore = PresetStore()

    var body: some Scene {
        WindowGroup {
            MainStudioView()
                .environmentObject(studioViewModel)
                .environmentObject(presetStore)
        }
    }
}
