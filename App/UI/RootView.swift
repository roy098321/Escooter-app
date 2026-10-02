import SwiftUI

/// Tab bar per IA.md (Routes · Rides · Home · Stats · Scooter); screens arrive in P5.
struct RootView: View {
    @State private var tab = 2

    var body: some View {
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
