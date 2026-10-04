import CorckieCore
import Foundation
import Observation
import UIKit

/// M1-09: connects the real sources to the one Recorder actor. Scooter events, phone fixes, barometer
/// readings, the buttons and a 1-s tick go through ONE ordered stream (an `AsyncStream`), so the Recorder sees
/// them in the order they happened. Recording happens in the background too: the scooter wake path (P4 c1)
/// relaunches the app, the link reconnects, the packets arrive here and the ride engine starts the ride.
/// The link stays read-only: nothing here writes to the scooter.
/// Used from the main thread only (like `PhoneSensors` and `Notifier`).
@Observable
final class RecorderService {
    static let shared = RecorderService()

    /// What the live view shows (M1-12 reads it); nil before the first tick
    private(set) var live: LiveState?
    private(set) var rideActive = false
    private(set) var lastClosedRideId: String?

    let recorder: Recorder
    private let continuation: AsyncStream<(RecorderInput, Double)>.Continuation
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var locationByRecorder = false

    private init() {
        let (stream, continuation) = AsyncStream.makeStream(of: (RecorderInput, Double).self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let hooks = RecorderHooks(
            rideStarted: { DispatchQueue.main.async { Notifier.shared.rideStarted() } },
            rideActive: { on in
                DispatchQueue.main.async {
                    Notifier.shared.rideActive = on
                    RecorderService.shared.rideActive = on
                }
            },
            location: { on in DispatchQueue.main.async { RecorderService.shared.setLocation(on) } },
            live: { _, state in DispatchQueue.main.async { RecorderService.shared.live = state } },
            rideClosed: { id, status in
                DispatchQueue.main.async {
                    RecorderService.shared.lastClosedRideId = id
                    Log.info(source: "recorder", "Ride closed (\(status))")
                }
            },
            log: { text in DispatchQueue.main.async { Log.info(source: "recorder", text) } })
        let recorder = Recorder(database: nil, simulated: false, build: AppInfo.build, stateURL: nil, hooks: hooks)
        self.recorder = recorder
        Task.detached(priority: .userInitiated) {
            for await (input, t) in stream {
                await recorder.process(input, at: t)
            }
        }
    }

    static func now() -> Double { Date().timeIntervalSince1970 }

    /// Called at launch (also the background relaunch for the scooter): the 1-s tick starts at once.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            RecorderService.shared.send(.tick)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let recorder = self.recorder
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { await recorder.flush(at: Date().timeIntervalSince1970) }
        }
    }

    /// The database is readable (after the first unlock): queued writes go in, an open ride is recovered.
    func attach(_ database: AppDatabase) {
        guard !attached else { return }
        attached = true
        let url = Recorder.stateURL(for: database)
        let recorder = self.recorder
        let now = Self.now()
        Task { await recorder.attachReal(database, stateURL: url, now: now) }
    }

    func send(_ input: RecorderInput, at t: Double = RecorderService.now()) {
        continuation.yield((input, t))
    }

    // MARK: Sources

    func scooterConnected(at date: Date) { send(.scooter(TimedScooterEvent(t: date.timeIntervalSince1970, event: .connected)), at: date.timeIntervalSince1970) }
    func scooterDisconnected(at date: Date) { send(.scooter(TimedScooterEvent(t: date.timeIntervalSince1970, event: .disconnected)), at: date.timeIntervalSince1970) }
    func packet(_ bytes: [UInt8], at date: Date) {
        send(.scooter(TimedScooterEvent(t: date.timeIntervalSince1970, event: .packet(bytes))), at: date.timeIntervalSince1970)
    }

    func fix(lat: Double, lon: Double, hAccM: Double, speedMps: Double, courseDeg: Double, altitudeM: Double?, at date: Date) {
        let t = date.timeIntervalSince1970
        send(.fix(PhoneFix(t: t, lat: lat, lon: lon, hAccM: hAccM, speedMps: speedMps, courseDeg: courseDeg, altitudeM: altitudeM)), at: t)
    }

    func barometer(relativeAltitudeM: Double, pressureKPa: Double?, at date: Date) {
        let t = date.timeIntervalSince1970
        send(.baro(BaroReading(t: t, relativeAltitudeM: relativeAltitudeM, pressureKPa: pressureKPa)), at: t)
    }

    /// Home → Start ride, live view → Not riding / hold to end / Same ride? (M1-11, M1-12)
    func press(_ input: RideEngineInput) { send(.press(input)) }

    // MARK: Location (ARCHITECTURE §5.1: on at stage 1, off when the ride closes)

    private func setLocation(_ on: Bool) {
        if on {
            if !PhoneSensors.shared.recording {
                PhoneSensors.shared.start()
                locationByRecorder = true
            }
        } else if locationByRecorder {
            PhoneSensors.shared.stop()
            locationByRecorder = false
        }
    }
}

extension Recorder {
    /// The real app: the state file goes next to the real database.
    func attachReal(_ database: AppDatabase, stateURL: URL, now: Double) {
        setStateURL(stateURL)
        attach(database, now: now)
    }
}
