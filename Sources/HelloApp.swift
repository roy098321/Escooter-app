import SwiftUI

// P2 D01–D02: proves cloud builds, sideloading, and that saved data survives
// a SideStore refresh and an app update. Throwaway.
@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    // Saved on the phone; must still be there after a refresh or an update (D02).
    @AppStorage("taps") private var taps = 0
    @AppStorage("firstOpened") private var firstOpened = ""

    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "scooter")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Built in the cloud")
                .font(.largeTitle.bold())
            Text("Build \(build)")
                .foregroundStyle(.secondary)
            Button("Saved taps: \(taps)") { taps += 1 }
                .buttonStyle(.borderedProminent)
            Text("First opened \(firstOpened)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if firstOpened.isEmpty {
                firstOpened = Date.now.formatted(date: .abbreviated, time: .shortened)
            }
        }
    }
}
