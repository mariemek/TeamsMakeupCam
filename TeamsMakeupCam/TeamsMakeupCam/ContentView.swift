import SwiftUI

struct ContentView: View {
    var body: some View {
        MainStudioView()
    }
}

#Preview {
    ContentView()
        .environmentObject(StudioViewModel())
}
