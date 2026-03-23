import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = StudioViewModel()

    var body: some View {
        MainStudioView()
            .environmentObject(viewModel)
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 600)
}
