import CorckieCore
import Foundation

/// The fixtures bundled with the app and used by the tests (TESTING §2 table F1–F5).
public struct SimFixture: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// Raw packets with their original timing (packet replay)
        case packets
        /// 1-per-second values, re-encoded into packets A / B (sample replay)
        case samples
    }

    public let id: String
    public let title: String
    public let fileName: String
    public let kind: Kind

    public static let all: [SimFixture] = [
        SimFixture(id: "F2", title: "Ride 1 · 16.3 km · raw packets", fileName: "F2_ride1_nrf", kind: .packets),
        SimFixture(id: "F5", title: "Ride 2 · 13.7 km · raw packets", fileName: "F5_ride2_nrf", kind: .packets),
        SimFixture(id: "F3", title: "Ride 2 · 1 per second (re-encoded)", fileName: "F3_ride2_merged", kind: .samples),
        SimFixture(id: "F1", title: "P2 scooter session · modes, brake, power off", fileName: "F1_p2lab_2oct", kind: .packets)
    ]

    /// The event stream of this fixture's text.
    public func events(from text: String) throws -> [TimedScooterEvent] {
        switch kind {
        case .packets: return try LogReader.scooterLog(text).events
        case .samples: return PacketEncoder.events(from: try LogReader.mergedSamples(text))
        }
    }
}

/// Scenarios from TESTING §4 that the fake scooter can play on its own today.
/// The rest need the P5 ride engine and phone replay; they are listed with `playable = false`.
public struct SimScenario: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let playable: Bool
    /// Faults placed relative to the start of the fixture (seconds)
    public let faults: @Sendable (_ start: Double) -> [Fault]

    public static let clean = SimScenario(id: "clean", title: "No fault", playable: true) { _ in [] }

    public static let all: [SimScenario] = [
        .clean,
        SimScenario(id: "SC-01", title: "Scooter disconnects for 60 s while moving", playable: true) {
            [.disconnect(at: $0 + 600, durationS: 60)]
        },
        // d7: 40% into ride 2 (1,810 s), 60 s without the scooter; the phone takes over
        SimScenario(id: "D7", title: "Disconnect at 40% (phone takes over)", playable: true) {
            [.disconnect(at: $0 + 724, durationS: 60)]
        },
        SimScenario(id: "SC-02", title: "Disconnect for 40 s", playable: true) {
            [.disconnect(at: $0 + 300, durationS: 40)]
        },
        SimScenario(id: "SC-04", title: "30% corrupt packets (data format changed)", playable: true) {
            [.corruptBytes(from: $0 + 120, to: $0 + 300, share: 0.3)]
        },
        SimScenario(id: "SC-15", title: "Plausibility spikes (80 km/h, battery +20%)", playable: true) {
            [.speedSpike(at: $0 + 200, kmh: 80), .batterySpike(at: $0 + 400, points: 20)]
        },
        SimScenario(id: "T8", title: "Scooter switches itself off (0x80)", playable: true) {
            [.shutdown(at: $0 + 900)]
        },
        SimScenario(id: "SC-07", title: "GPS lost for 2 min (phone replay ready; plays in the real screens from M1-15)", playable: false) {
            [.gpsLoss(from: $0 + 600, to: $0 + 720)]
        },
        SimScenario(id: "SC-14", title: "App killed mid-ride (phone replay ready; plays with the recorder, M1-09 / M1-15)", playable: false) {
            [.appRelaunch(at: $0 + 600)]
        }
    ]
}

/// G1 phone takeover for the simulator (d7): the ride's recorded GPS speed at a virtual time.
public enum PhoneTakeover {
    public static func gpsSpeedKmh(track: [MergedSample], at t: Double) -> Double? {
        guard !track.isEmpty else { return nil }
        let index = min(track.count - 1, max(0, Int(t - (track.first?.t ?? 0))))
        return track[index].gpsSpeedKmh
    }
}
