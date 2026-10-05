import CorckieCore
import SwiftUI

/// Tab bar per IA.md (Routes · Rides · Home · Stats · Scooter); screens arrive in P5.
struct RootView: View {
    @State private var tab = 2
    private let model = AppModel.shared

    var body: some View {
        // v1 on every tab and pushed screen (owner, P4 D3); sheets add their own `.v1Label()`.
        content.v1Label()
    }

    /// M1-12: read in the body, so the cover follows the recorder (observation)
    private var liveCoverShown: Bool { RecorderService.shared.rideActive || RecorderService.shared.readyRequested }

    private var summaryShown: Bool { RecorderService.shared.summaryRideId != nil }

    @ViewBuilder private var content: some View {
        if let error = model.databaseError {
            DataUpdateFailedView(message: error)
        } else if let shot = UIShot.requested, shot != "home" {   // "home" = the real tab bar
            UIShot.screen(shot)
        } else {
            tabs
                .fullScreenCover(isPresented: .constant(liveCoverShown || summaryShown)) {
                    // M1-12: no tab bar, no navigation, no swipe-down while a ride is on.
                    // M1-13: when the ride is over the same cover turns into its summary.
                    RideCover()
                        .v1Label()
                }
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 0) {
                        if model.simulator.running || ScreenSimulator.shared.active {
                            Banner(text: "SIMULATED · fake scooter replay", tint: .purple)
                        }
                        if model.database?.isReadOnly == true {
                            Banner(text: "Install the newest build · your data is from a newer version (read-only)")
                        }
                    }
                }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            RoutesListView()
                .tabItem { Label("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(0)
            RidesListView()
                .tabItem { Label("Rides", systemImage: "list.bullet") }
                .tag(1)
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
                .screen(title)
        }
        .tabItem { Label(title, systemImage: symbol) }
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

/// CI ui-shots: `-uiShot <screen>` opens one screen straight away (TESTING §7).
enum UIShot {
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiShot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @ViewBuilder static func screen(_ name: String) -> some View {
        NavigationStack {
            switch name {
            case "settings": SettingsView()
            case "developer": DeveloperView()
            case "checks": ChecksView()
            case "results": ResultsView()
            case "simulator": SimulatorView()
            case "rides": RidesListView()
            case "ride-detail", "ride-nogps", "ride-gap", "ride-walk":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model(name))
            case "routes-empty", "routes-list", "routes-greyed":
                RoutesListView(preview: RoutesPreview.list(name))
            case "route-card", "route-card-sparse":
                RouteCardView(preview: RoutesPreview.card(name))
            case "places":
                PlacesView(preview: RoutesPreview.places())
            case "ride-save-route":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model("ride-detail"),
                               previewOffer: RouteOfferModel.make(routeId: "preview", state: .suggested, title: "Route 1", ridesOnRoute: 2))
            case "route-arriveby":
                ScrollView { ArriveByCard(routeId: nil, destination: "Work", rides: RoutesPreview.arriveByRides(), preview: true).padding() }
            case "outside": OutsideDataView()
            case "scooter": ScooterCheckView()
            case "onboarding1": OnboardingView(previewFound: true) { _ in }
            case "onboarding2": OnboardingView(startAt: .location, previewFound: true) { _ in }
            case "onboarding3": OnboardingView(startAt: .notifications, previewFound: true) { _ in }
            default:
                if let live = LivePreview.make(name) {
                    LiveRideView(preview: live)
                } else if let input = HomePreview.input(name) {
                    HomeView(preview: input, previewChips: HomePreview.chips(name), previewSelected: name == "home-whereto" ? "a" : nil)
                } else {
                    HomeView()
                }
            }
        }
    }
}

/// M1-12 / M1-13: the full-screen cover shows the live view while a ride (or Ready) is on, then the ride's summary.
struct RideCover: View {
    var body: some View {
        cover.safeAreaInset(edge: .top, spacing: 0) {
            if ScreenSimulator.shared.active {
                Banner(text: "SIMULATED · fake scooter replay", tint: .purple)
            }
        }
    }

    @ViewBuilder private var cover: some View {
        let service = RecorderService.shared
        if service.rideActive || service.readyRequested {
            LiveRideView()
        } else if let id = service.summaryRideId {
            NavigationStack {
                RideDetailView(rideId: id, onDone: { RecorderService.shared.dismissSummary() })
            }
            .interactiveDismissDisabled(true)
        }
    }
}
