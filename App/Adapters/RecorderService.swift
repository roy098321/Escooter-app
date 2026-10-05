import CorckieCore
import Foundation
import Network
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
    /// M1-13: the ride whose summary is waiting to be shown once the live view is done (nil = none)
    private(set) var summaryRideId: String?
    /// M1-12: everything the live ride screen draws (computed here once a second by `LiveScreenDriver`)
    private(set) var liveScreen: LiveScreenState?
    private(set) var livePath = LivePath()
    /// Last known position for the map dot (nil before the first fix)
    private(set) var livePosition: LivePath.Coord?
    /// "Ready" (D2): the live view was asked for (notification tap) before any ride
    private(set) var readyRequested = false
    @ObservationIgnored private var driver = LiveScreenDriver()
    @ObservationIgnored private var lastLiveMode: LiveMode = .ready
    @ObservationIgnored private var followChecked = false

    /// M1-15: the simulator drives the screens; the real Recorder's live output is ignored meanwhile
    private(set) var simActive = false
    @ObservationIgnored private var simSink: ((RideEngineInput) -> Void)?

    let recorder: Recorder
    private let continuation: AsyncStream<(RecorderInput, Double)>.Continuation
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var locationByRecorder = false

    private init() {
        let (stream, continuation) = AsyncStream.makeStream(of: (RecorderInput, Double).self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let hooks = RecorderHooks(
            rideStarted: {
                DispatchQueue.main.async {
                    Notifier.shared.rideStarted()
                    PhoneBatteryWatch.shared.rideStarted()
                }
            },
            rideActive: { on in
                DispatchQueue.main.async {
                    guard !RecorderService.shared.simActive else { return }
                    Notifier.shared.rideActive = on
                    RecorderService.shared.rideActive = on
                }
            },
            location: { on in DispatchQueue.main.async { RecorderService.shared.setLocation(on) } },
            live: { input, state in DispatchQueue.main.async { RecorderService.shared.handleLive(input, state) } },
            rideClosed: { id, status in
                DispatchQueue.main.async {
                    RecorderService.shared.lastClosedRideId = id
                    RecorderService.shared.summaryRideId = id
                    PhoneBatteryWatch.shared.rideEnded()
                    BackupWriter.shared.rideEnded(rideId: id)
                    RideChecks.run(database: AppModel.shared.database)
                    RouteNaming.start(rideId: id, database: AppModel.shared.database)
                    MaintenanceService.checkAtRideEnd(AppModel.shared.database)
                    OutsideDataService.shared.refresh(database: AppModel.shared.database, reason: "ride closed")
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
        PhoneBatteryWatch.shared.enable()
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
        if case .press(let p) = input, let sink = simSink { sink(p); return }
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

    // MARK: Live view (M1-12)

    /// Once a second, on the main thread: the engine's live input goes through the display rules.
    func handleLive(_ rawInput: LiveInput, _ state: LiveState, at time: Double? = nil, fromSimulator: Bool = false) {
        if simActive != fromSimulator { return }     // while simulating only the simulator's output counts
        live = state
        var input = rawInput
        input.mapOffline = NetworkStatus.shared.offline
        // M2-06: the route chosen with Where to? is followed from the start of the ride to its end (once per ride).
        // M2-09 (Q9): at ride start, when the way back will not fit, one warning (needs the battery reading, so it waits for it).
        let rideOn = input.phase == .starting || input.phase == .riding
        if rideOn, !followChecked, input.scooterBatteryPct != nil || input.phase == .riding {
            followChecked = true
            if let db = AppModel.shared.displayDatabase {
                let battery = input.scooterBatteryPct.map { BatteryNow(pct: $0) } ?? BatteryNowSource.current(database: db)
                // M4-03: the ride-start insights (Q9 folded in, Q1 destination guess, Q2 tight battery, Q15 headwind) are stored as
                // candidates; the live view shows Q9's line as before (M2-09), the rest wait for the message budget (M4-04).
                let start = InsightRunner.atRideStart(db, routeId: RouteFollowSelection.shared.routeId, battery: battery, lat: input.lat, lon: input.lon)
                if let id = RouteFollowSelection.shared.routeId {
                    let warning = (start.shown + start.toSummary).first { $0.type == .q9Live }?.text
                    driver.follow(RouteFollowLoader.follower(routeId: id, database: db), utcOffsetMin: RouteCardLoader.currentOffsetMin(),
                                  returnWarning: warning)
                }
            }
        } else if !rideOn, followChecked {
            followChecked = false
            RouteFollowSelection.shared.routeId = nil
        }
        let screen = driver.update(input, at: time ?? Self.now())
        if screen.mode != .ready, lastLiveMode == .ready { livePath.reset() }
        lastLiveMode = screen.mode
        if screen.mode != .ready { readyRequested = false }
        if let lat = input.lat, let lon = input.lon {
            livePosition = screen.dotOverride ?? LivePath.Coord(lat: lat, lon: lon)   // M2-08: no GPS on a followed route
            if screen.mode != .ready, input.secondsWithoutGps == 0 {
                livePath.add(lat: lat, lon: lon, speedKmh: Double(screen.tiles.speedKmh ?? 0), dashed: screen.dashedPath)
            }
        }
        liveScreen = screen
    }

    /// The rider taps the shown banner (refused at 5 km/h or more) or answers "Same ride?".
    func tapBanner() {
        let speed = Double(liveScreen?.tiles.speedKmh ?? 0)
        driver.tapBanner(speedKmh: speed)
    }

    func answerSameRide(_ yes: Bool) {
        press(.sameRideAnswer(yes))
    }

    // MARK: Simulator (M1-15)

    func beginSimulation(press: @escaping (RideEngineInput) -> Void) {
        resetScreens()
        simSink = press
        simActive = true
    }

    func endSimulation() {
        simSink = nil
        simActive = false
        resetScreens()
    }

    func setSimRideActive(_ on: Bool) { rideActive = on }

    func simRideClosed(_ id: String) {
        lastClosedRideId = id
        summaryRideId = id
    }

    private func resetScreens() {
        live = nil
        liveScreen = nil
        livePosition = nil
        livePath.reset()
        rideActive = false
        summaryRideId = nil
        readyRequested = false
        driver = LiveScreenDriver()
        lastLiveMode = .ready
        followChecked = false
    }

    /// M1-13: the rider closed the summary (Done) or it could not load
    func dismissSummary() { summaryRideId = nil }

    /// D2: the "Going for a ride?" notification was tapped: open the live view in "Ready".
    func requestReady() { readyRequested = true }
    func closeReady() { readyRequested = false }

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

/// "Offline map" chip (STATES S5): true while the phone has no internet route.
final class NetworkStatus {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private(set) var offline = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let off = path.status != .satisfied
            DispatchQueue.main.async { self?.offline = off }
        }
        monitor.start(queue: DispatchQueue(label: "corckie.network"))
    }
}
