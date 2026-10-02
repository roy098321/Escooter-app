import SwiftUI

/// Tab bar per IA.md (Routes · Rides · Home · Stats · Scooter); screens arrive in P5.
struct RootView: View {
    @State private var tab = 2
    private let model = AppModel.shared

    var body: some View {
        if let error = model.databaseError {
            DataUpdateFailedView(message: error)
        } else {
            tabs
                .safeAreaInset(edge: .top) {
                    if model.database?.isReadOnly == true {
                        Banner(text: "Install the newest build · your data is from a newer version (read-only)")
                    }
                }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            placeholder("Routes", "point.topleft.down.to.point.bottomright.curvepath").tag(0)
            placeholder("Rides", "list.bullet").tag(1)
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(2)
            placeholder("Stats", "chart.bar").tag(3)
            placeholder("Scooter", "scooter").tag(4)
        }
    }

    private func placeholder(_ title: String, _ symbol: String) -> some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: symbol,
                                   description: Text("Arrives with the first milestone (M1)."))
                .navigationTitle(title)
        }
        .tabItem { Label(title, systemImage: symbol) }
    }
}

struct HomeView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Foundation build", systemImage: "scooter",
                                   description: Text("Settings → Developer → Checks has this build's check list."))
                .navigationTitle("Home")
                .toolbar {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
        }
    }
}

/// DATA_MODEL V4: never run on half-migrated data.
struct DataUpdateFailedView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Data update failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Your rides are safe: a copy was made before the update. Send the report to Claude.\n\n\(message)")
        } actions: {
            ShareLink(item: "CorckieApp \(AppInfo.versionLine) · data update failed\n\(message)") {
                Label("Send report", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A one-line banner under the status bar (STATES patterns).
struct Banner: View {
    let text: String
    var tint: Color = .orange

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal)
            .background(tint.opacity(0.9))
            .foregroundStyle(.white)
    }
}
