import Foundation

/// The live path of the foundation: event → decoder → plausibility (G1b) → ride totals
/// (ARCHITECTURE §2.3, §5.2). The same pipeline runs for the real scooter, the in-app
/// simulator and the tests, so tests check what runs on the street. The P5 ride engine
/// (M1–M3, G1) plugs in after the plausibility step.
public struct ScooterPipeline {
    public private(set) var assembler = FrameAssembler()
    public private(set) var plausibility = Plausibility()
    public private(set) var totals = RideTotals()
    public private(set) var frame: ScooterFrame?
    /// B56: the battery % after the flip filter (per-scooter auto-detect); `frame.batteryPct` is the filtered value
    public private(set) var batteryFilter = BatteryFilter()
    /// B57: what the newest checked frame dropped (for the log line when the format watch trips)
    public private(set) var lastDropped: [Plausibility.Field] = []
    public private(set) var connected = false
    public private(set) var connects = 0
    public private(set) var disconnects = 0
    public private(set) var packets = 0
    /// Last event time
    public private(set) var now: Double = 0

    public init() {}

    public mutating func handle(_ e: TimedScooterEvent) {
        now = e.t
        switch e.event {
        case .connected:
            connected = true
            connects += 1
            plausibility.connected(at: e.t)
            // B27: nothing from before this connection is carried into its frames (a missed disconnect included); the last
            // frame of the previous connection is no live reading any more
            assembler.reset()
            frame = nil
            batteryFilter.newConnection()          // B56: the boot readings come again
        case .disconnected:
            connected = false
            disconnects += 1
            assembler.reset()
            totals.gap()
        case .packet(let bytes):
            packets += 1
            if !connected {                // a log that starts mid-connection
                connected = true
                plausibility.connected(at: e.t)
            }
            guard let raw = assembler.ingest(bytes, at: e.t), let kind = assembler.lastKind else {
                plausibility.tick(at: e.t)
                return
            }
            var checked = plausibility.check(raw, isPacketA: kind == .a)
            lastDropped = checked.dropped
            // B56: everything after this point sees the flip-filtered %
            if let pct = checked.frame.batteryPct { checked.frame.batteryPct = batteryFilter.reading(pct, at: e.t) }
            frame = checked.frame
            totals.add(checked.frame, kind: kind)
        }
    }

    /// B56b: the scooter's stored flip history (the app keeps it per scooter); the hysteresis keeps its state.
    public mutating func setBatteryDetector(_ d: BatteryFlipDetector) {
        batteryFilter.detector = d
    }

    public mutating func handle(_ events: [TimedScooterEvent]) {
        for e in events { handle(e) }
    }
}
