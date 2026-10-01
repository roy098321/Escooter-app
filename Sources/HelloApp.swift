import SwiftUI

// P2 D01: proves the app can be built in the cloud and sideloaded. Throwaway.
@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "scooter")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Built in the cloud")
                .font(.largeTitle.bold())
            Text("No Mac involved")
                .foregroundStyle(.secondary)
            Button("Tapped \(taps) times") { taps += 1 }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
