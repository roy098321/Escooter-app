import AppIntents
import SwiftUI
import WidgetKit

// N7-9 (batch 7): Control Center / Lock Screen / Action button controls that start a ride (iOS 18). Free ride ∞, and Next = the
// usual destination from the place you are at (never by time of day). Both run the shared StartRideIntent in the app, which opens
// the Live screen. Per-place controls need the place list inside this extension (an App Group), not available on unsigned
// SideStore builds; "Ride to <place>" works through Siri and Spotlight instead (the app's RideToPlaceIntent).

@available(iOS 18.0, *)
struct FreeRideControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.corckieapp.control.freeride") {
            ControlWidgetButton(action: StartRideIntent(destination: nil)) {
                Label("Free ride", systemImage: "infinity")
            }
        }
        .displayName("Free ride")
        .description("Starts a ride with no destination.")
    }
}

@available(iOS 18.0, *)
struct NextRideControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.corckieapp.control.next") {
            ControlWidgetButton(action: StartRideIntent(destination: "next")) {
                Label("Ride to next", systemImage: "arrow.triangle.turn.up.right.circle")
            }
        }
        .displayName("Ride to next")
        .description("Starts a ride to your usual destination from where you are.")
    }
}
