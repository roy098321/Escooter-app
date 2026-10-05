import CorckieCore
import CorckieSim
import Foundation
import GRDB
import Observation

/// M1-15: the simulator drives the REAL screens. A scenario (ride 1, ride 2, or a synthetic one) is fed at 1x to 50x
/// to its own Recorder, which writes into a temporary database (never the real corckie.sqlite). Home, the live view,
/// the ride summary and the Rides list read that temporary database while the simulation is active, and every
/// screen shows the SIMULATED banner. Nothing simulated goes to the real database, the notifier, the phone-battery
/// watch or the backups (the Recorder's hooks here skip them). d8 checks the real ride count at the end.
@Observable
final class ScreenSimulator {
    static let shared = ScreenSimulator()

    struct Source: Identifiable {
        let id: String
        let title: String
        let make: () throws -> SimStream
    }

    private(set) var running = false
    /// true from Start until "End simulation": the screens show simulated data and the banner
    private(set) var active = false
    private(set) var database: AppDatabase?
    private(set) var progress = 0.0
    private(set) var message: String?
    /// The virtual clock shifted to start at the real "now" (what the live view uses as its time)
    private(set) var virtualNow = Date().timeIntervalSince1970

    var sourceID = "F2"
    var speed: Double = 50

    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var continuation: AsyncStream<(RecorderInput, Double)>.Continuation?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inputs: [(t: Double, input: RecorderInput)] = []
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var firstT = 0.0
    @ObservationIgnored private var realStart = Date()
    @ObservationIgnored private var runSpeed = 50.0
    @ObservationIgnored private var realRidesBefore: Int?
    @ObservationIgnored private var realRoutesBefore: [Int]?

    private init() {}

    // MARK: Sources

    static func loadFixture(_ id: String) throws -> (text: String, fixture: SimFixture) {
        guard let fixture = SimFixture.all.first(where: { $0.id == id }),
              let url = Bundle.main.url(forResource: fixture.fileName, withExtension: "csv", subdirectory: "Fixtures") else {
            throw NSError(domain: "ScreenSimulator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found in the app"])
        }
        return (try String(contentsOf: url, encoding: .utf8), fixture)
    }

    static let sources: [Source] = {
        var list: [Source] = []
        list.append(Source(id: "F2", title: "Ride 1 · 16.3 km") {
            let (text, f) = try loadFixture("F2")
            return SimStream(scooter: try f.events(from: text), phone: [])
        })
        list.append(Source(id: "F5", title: "Ride 2 · 13.7 km") {
            let (text, f) = try loadFixture("F5")
            return SimStream(scooter: try f.events(from: text), phone: [])
        })
        list.append(Source(id: "F3", title: "Ride 2 with GPS · 1 per second") {
            let (text, f) = try loadFixture("F3")
            return SimStream(scooter: try f.events(from: text), phone: PhoneSource.events(fromMerged: try LogReader.mergedSamples(text)))
        })
        for s in SyntheticScenario.all {
            list.append(Source(id: s.id, title: s.title) { s.build() })
        }
        return list
    }()

    // MARK: Run

    func start(realScooterConnected: Bool, otherSimulatorRunning: Bool) {
        guard !realScooterConnected else {
            message = "The real scooter is connected · the simulator can't run during a real ride"
            return
        }
        guard !otherSimulatorRunning else {
            message = "The pipeline simulator is running · stop it first"
            return
        }
        guard !running else { return }
        guard let source = Self.sources.first(where: { $0.id == sourceID }) else { return }
        do {
            let stream = try source.make()
            var list = RecorderRunner.inputs(stream, tailS: 1500)
            guard let first = list.first?.t else { message = "Nothing to play"; return }
            let now = Date().timeIntervalSince1970
            list = list.map { (t: $0.t - first + now, input: $0.input) }
            endSimulationQuietly()
            let db = try AppDatabase.openTemporary(build: AppInfo.build)
            realRidesBefore = Self.realRideCount()
            realRoutesBefore = Self.realRouteCounts()
            let (s, c) = AsyncStream.makeStream(of: (RecorderInput, Double).self, bufferingPolicy: .unbounded)
            let rec = Recorder(database: db, simulated: true, build: AppInfo.build, stateURL: Recorder.stateURL(for: db),
                               hooks: Self.hooks())
            consumer = Task.detached(priority: .userInitiated) {
                for await (input, t) in s { await rec.process(input, at: t) }
            }
            continuation = c
            recorder = rec
            database = db
            inputs = list
            index = 0
            firstT = now
            virtualNow = now
            runSpeed = speed
            realStart = Date()
            progress = 0
            message = nil
            running = true
            active = true
            RecorderService.shared.beginSimulation { [weak self] input in self?.press(input) }
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            Log.info(source: "simulator", "Screens: started \(source.id) at \(Int(speed))×")
        } catch {
            message = "Couldn't start: \(error.localizedDescription)"
            Log.error(source: "simulator", message ?? "")
        }
    }

    /// Stops feeding; the simulated rides and the banner stay until `end()`.
    func stop(reason: String? = nil) {
        timer?.invalidate()
        timer = nil
        let wasRunning = running
        running = false
        if let reason { message = reason }
        if let rec = recorder {
            let t = virtualNow
            Task { await rec.flush(at: t) }
        }
        if wasRunning { checkRealDataApart() }
    }

    /// End simulation: back to the real screens, the temporary database is deleted.
    func end() {
        stop(reason: nil)
        endSimulationQuietly()
        message = "Simulation ended · simulated rides deleted"
    }

    private func endSimulationQuietly() {
        timer?.invalidate()
        timer = nil
        running = false
        continuation?.finish()
        continuation = nil
        let task = consumer
        let db = database
        consumer = nil
        recorder = nil
        database = nil
        active = false
        RecorderService.shared.endSimulation()
        Task {
            await task?.value
            db?.discardTemporary()
        }
    }

    private func press(_ input: RideEngineInput) {
        continuation?.yield((.press(input), virtualNow))
    }

    private func tick() {
        let virtual = firstT + Date().timeIntervalSince(realStart) * runSpeed
        virtualNow = virtual
        while index < inputs.count, inputs[index].t <= virtual {
            let item = inputs[index]
            continuation?.yield((item.input, item.t))
            index += 1
        }
        progress = inputs.isEmpty ? 1 : Double(index) / Double(inputs.count)
        if index >= inputs.count {
            stop(reason: "Finished · the simulated ride stays in the Rides list until you tap End simulation")
        }
    }

    private static func hooks() -> RecorderHooks {
        RecorderHooks(
            rideStarted: {},
            rideActive: { on in
                DispatchQueue.main.async {
                    guard RecorderService.shared.simActive else { return }
                    RecorderService.shared.setSimRideActive(on)
                }
            },
            location: { _ in },
            live: { input, state in
                DispatchQueue.main.async {
                    guard ScreenSimulator.shared.active else { return }
                    RecorderService.shared.handleLive(input, state, at: ScreenSimulator.shared.virtualNow, fromSimulator: true)
                }
            },
            rideClosed: { id, status in
                DispatchQueue.main.async {
                    guard ScreenSimulator.shared.active else { return }
                    RecorderService.shared.simRideClosed(id)
                    RouteNaming.start(rideId: id, database: ScreenSimulator.shared.database)
                    Log.info(source: "simulator", "Simulated ride closed (\(status))")
                }
            },
            log: { _ in })
    }

    /// d8: a simulator run never changes the real database.
    private func checkRealDataApart() {
        if let routesBefore = realRoutesBefore, let routesAfter = Self.realRouteCounts() {
            realRoutesBefore = nil
            CheckResults.shared.set("d12", routesAfter == routesBefore ? .pass : .fail,
                                    "Real places / routes / variants before \(routesBefore), after \(routesAfter) (simulated routes live in a temporary database)")
        }
        guard let before = realRidesBefore else { return }
        realRidesBefore = nil
        guard let after = Self.realRideCount() else { return }
        CheckResults.shared.set("d8", after == before ? .pass : .fail,
                                "Real rides before \(before), after \(after) (simulated rides kept in a temporary database)")
    }

    private static func realRouteCounts() -> [Int]? {
        guard let db = AppModel.shared.database, let c = try? RouteQueries(db).counts() else { return nil }
        return [c.places, c.routes, c.variants]
    }

    private static func realRideCount() -> Int? {
        guard let db = AppModel.shared.database else { return nil }
        return try? db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") ?? 0 }
    }
}
