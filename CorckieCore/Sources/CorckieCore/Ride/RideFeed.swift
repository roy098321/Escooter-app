import Foundation

/// The live path with the ride engine plugged in after the plausibility step (ARCHITECTURE §2.3):
/// scooter event → decoder → G1b → `RideEngine`, phone fix → `RideEngine`. The Recorder (M1-09), the
/// in-app simulator and the tests all drive the engine through this one type.
public struct RideFeed {
    public private(set) var pipeline = ScooterPipeline()
    public var engine: RideEngine

    public init(engine: RideEngine = RideEngine()) {
        self.engine = engine
    }

    /// Why the scooter readings are untrusted ("Scooter data format changed"), nil while they are trusted
    public var formatChangeReason: String? {
        engine.untrustedSince != nil ? pipeline.plausibility.formatChangeReason : nil
    }

    /// The newest checked frame, when the last scooter event produced one (nil while the readings are untrusted)
    public private(set) var lastNewFrame: ScooterFrame?

    @discardableResult
    public mutating func scooter(_ e: TimedScooterEvent) -> [RideEngineEvent] {
        lastNewFrame = nil
        switch e.event {
        case .connected:
            pipeline.handle(e)
            return engine.handle(.connected, at: e.t)
        case .disconnected:
            pipeline.handle(e)
            return engine.handle(.disconnected, at: e.t)
        case .packet:
            let before = pipeline.assembler.packetCount - pipeline.assembler.unknownCount
            pipeline.handle(e)
            let after = pipeline.assembler.packetCount - pipeline.assembler.unknownCount
            // G1b format-change watch → phone mode (SC-04); raw packets keep being stored by the Recorder
            var out: [RideEngineEvent] = []
            // (the failed-share rule only: "no valid packet A for 10 s" is "scooter gone" in the engine, and the P2
            // lab log F1 trips it while standing with the scooter on)
            if pipeline.plausibility.failedShareTripped, engine.untrustedSince == nil, engine.connected {
                out += engine.handle(.formatChanged, at: e.t)
            }
            guard after > before, let f = pipeline.frame else { return out + engine.handle(.tick, at: e.t) }
            if engine.untrustedSince == nil { lastNewFrame = f }
            return out + engine.handle(.frame(f), at: e.t)
        }
    }

    @discardableResult
    public mutating func fix(_ f: PhoneFix) -> [RideEngineEvent] {
        engine.handle(.fix(f), at: f.t)
    }

    @discardableResult
    public mutating func input(_ i: RideEngineInput, at t: Double) -> [RideEngineEvent] {
        engine.handle(i, at: t)
    }
}
