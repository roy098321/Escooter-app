import CorckieCore
import Foundation
import GRDB
import Observation
import UIKit

/// N10 (batch 10): fault recognition glue. After a ride closes, the ride's raw scooter readings are decoded again and run through
/// `AfterRideFaults` (CorckieCore, unit tested). The books (the rider's normals per scooter), the open faults and each route's
/// wheel/GPS ratios are kept as JSON in the `setting` table, so Export everything and the backup carry them. At most one finding
/// becomes the pop-up over the ride summary. Read-only: nothing is ever written to the scooter.
@Observable
final class FaultCenter {
    static let shared = FaultCenter()

    /// The finding shown over the ride summary (or over Home at switch-on)
    var popup: FaultRecord?
    /// Open faults, for the Maintenance screen, the Scooter tab and the tab dot
    private(set) var records: [FaultRecord] = []
    /// N10-19: the orange dot on the Scooter tab (an open issue or a due reminder)
    private(set) var tabDot = false
    /// N10-20: the Home line under the status pill, only when something needs doing
    private(set) var homeLine: String?

    private init() {}

    func reload(_ db: AppDatabase?) {
        records = FaultStore.records(db)
        guard let db else { return }
        let parts = MaintenanceService.parts(db)
        tabDot = MaintParts.tabDot(parts)
        homeLine = MaintParts.homeLine(parts)
    }

    func dismissPopup() { popup = nil }
}

enum FaultStore {
    static let bookKey = "faults.book"
    static let heatKey = "faults.heat"
    static let recordsKey = "faults.records"
    static let ratiosKey = "faults.routeRatios"
    static let lastOdoKey = "faults.lastOdo"
    static let occurrencesKey = "faults.occurrences"

    static func load<T: Decodable>(_ db: AppDatabase?, _ key: String, as: T.Type) -> T? {
        guard let s = SettingsValue.text(db, key), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ db: AppDatabase?, _ key: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value), let s = String(data: d, encoding: .utf8) else { return }
        SettingsValue.set(db, key, s)
    }

    static func records(_ db: AppDatabase?) -> [FaultRecord] { load(db, recordsKey, as: [FaultRecord].self) ?? [] }
    static func saveRecords(_ db: AppDatabase?, _ list: [FaultRecord]) { save(db, recordsKey, list) }

    /// "Checked, it's fine": the gate raises its bar (twice → quiet) and the record closes
    static func checkedFine(_ id: String, _ db: AppDatabase?) {
        var list = records(db)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        var book = load(db, bookKey, as: FaultBook.self) ?? FaultBook()
        let r = list[i]
        let variants = book.baselines.keys.filter { $0.hasPrefix(FaultBook.key(r.scooterId, r.kind)) }
        for key in variants {
            if let b = book.baselines[key] { book.baselines[key] = FaultGate.checkedFine(b, kind: r.kind) }
        }
        save(db, bookKey, book)
        list[i].status = .checkedFine
        list[i].closedDay = FaultGate.day(epochMs: Int64(Date().timeIntervalSince1970 * 1000))
        saveRecords(db, list)
        FaultCenter.shared.reload(db)
    }

    /// "I fixed it" on a fault page: the record closes and that part's faults start learning again (A30)
    static func fixed(_ id: String, _ db: AppDatabase?) {
        var list = records(db)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        var book = load(db, bookKey, as: FaultBook.self) ?? FaultBook()
        book.partReplaced(list[i].kind.part, scooterId: list[i].scooterId)
        save(db, bookKey, book)
        list[i].status = .fixed
        list[i].closedDay = FaultGate.day(epochMs: Int64(Date().timeIntervalSince1970 * 1000))
        saveRecords(db, list)
        FaultCenter.shared.reload(db)
    }

    /// "Log what I did" → a part was replaced or serviced: its faults relearn (A30)
    static func partServiced(_ part: MaintPart, scooterId: String, _ db: AppDatabase?) {
        var book = load(db, bookKey, as: FaultBook.self) ?? FaultBook()
        book.partReplaced(part, scooterId: scooterId)
        save(db, bookKey, book)
    }
}

enum FaultService {
    /// A gap in the scooter's readings longer than this counts as a link drop / restart (F7 "no reading" after a restart is normal)
    static let linkDropS = 5.0

    static func rideClosed(rideId: String, database: AppDatabase?) {
        guard let db = database, !db.isReadOnly, let ride = try? RideQueries(db).ride(id: rideId), ride.isSimulated == false else { return }
        if GarageService.activeIsBorrowed(db) { return }   // N11-2: a borrowed scooter gets no maintenance alerts
        let chunks = ((try? RideQueries(db).chunks(rideId: rideId)) ?? []).filter { $0.kind == "scooter" }.sorted { $0.seq < $1.seq }
        let samples = (try? RideQueries(db).samples(rideId: rideId)) ?? []
        let scooter = ScooterRecord.latest(in: db)
        let extra = try? db.writer.read { d in
            try Row.fetchOne(d, sql: "SELECT routeId, airTempC, headwindKmh FROM ride WHERE id = ?", arguments: [rideId])
        }
        let context = RideContext(routeId: extra?["routeId"], airTempC: extra?["airTempC"], headwindKmh: extra?["headwindKmh"])
        DispatchQueue.global(qos: .utility).async {
            let frames = Self.frames(chunks)
            guard frames.count > 60 else {
                DispatchQueue.main.async {
                    if let d = FaultSwitchOn.shared.deferred { FaultCenter.shared.popup = d }
                    FaultSwitchOn.shared.deferred = nil
                }
                return
            }
            let result = Self.run(ride: ride, context: context, frames: frames, samples: samples, scooterId: ride.scooterId ?? scooter?.id ?? "scooter",
                                  firmware: scooter?.firmware, db: db)
            // N11-1: the tyre-pressure hint learns from the same ride (it lights a tile; it never pops up)
            EnergyHintService.rideClosed(ride: ride, frames: frames, samples: samples, scooterId: ride.scooterId ?? scooter?.id ?? "scooter",
                                         firmware: scooter?.firmware, db: db)
            DispatchQueue.main.async {
                FaultCenter.shared.reload(db)
                // one at a time: this ride's finding first, else a switch-on finding that waited for the summary
                if let shown = result ?? FaultSwitchOn.shared.deferred { FaultCenter.shared.popup = shown }
                FaultSwitchOn.shared.deferred = nil
            }
        }
    }

    /// The ride's raw scooter packets → frames (the same decoder as live)
    static func frames(_ chunks: [RawChunkRecord]) -> [ScooterFrame] {
        var asm = FrameAssembler()
        var out: [ScooterFrame] = []
        for c in chunks {
            let data: Data
            if c.codec == "zlib-v1" {
                guard let d = try? (c.blob as NSData).decompressed(using: .zlib) as Data else { continue }
                data = d
            } else {
                data = c.blob
            }
            for p in RecorderRaw.unpack(data, startT: Double(c.startAt) / 1000) {
                if let f = asm.ingest(p.bytes, at: p.t) { out.append(f) }
            }
        }
        return out
    }

    /// Wheel distance / GPS distance on this ride, from the 5-second samples with a good fix and both speeds above 2 m/s
    static func wheelGpsRatio(_ samples: [RideSampleRecord]) -> Double? {
        var wheel = 0.0, gps = 0.0
        for s in samples {
            guard let w = s.speedMps, let g = s.gpsSpeedMps, w > 2, g > 2, (s.hAccM ?? 99) <= 20 else { continue }
            wheel += w
            gps += g
        }
        return gps > 300 ? wheel / gps : nil
    }

    /// Runs the gate; returns the record to pop up (at most one)
    /// Ride columns RideRecord doesn't carry
    struct RideContext {
        var routeId: String?
        var airTempC: Double?
        var headwindKmh: Double?
    }

    static func run(ride: RideRecord, context: RideContext, frames: [ScooterFrame], samples: [RideSampleRecord], scooterId: String, firmware: String?,
                    db: AppDatabase) -> FaultRecord? {
        var book = FaultStore.load(db, FaultStore.bookKey, as: FaultBook.self) ?? FaultBook()
        var heat = FaultStore.load(db, FaultStore.heatKey, as: HeatBook.self) ?? HeatBook()
        var ratios = FaultStore.load(db, FaultStore.ratiosKey, as: [String: [Double]].self) ?? [:]
        var lastOdo = FaultStore.load(db, FaultStore.lastOdoKey, as: [String: Double].self) ?? [:]

        let distKm = (ride.distanceM ?? 0) / 1000
        let rule = FaultRuleOuts(
            airC: context.airTempC,
            minBatteryPct: ride.endRestPct.map { Int($0.rounded()) },
            weakGps: ride.hasGps == false || (ride.gapGpsS ?? 0) > 60,
            phoneLinkTrouble: (ride.gapScooterS ?? 0) > 60,
            hilly: distKm > 0 && (ride.elevGainM ?? 0) / distKm > 15,
            windy: (context.headwindKmh ?? 0) > 20)

        var routeRatios: [Double] = []
        if let route = context.routeId, let r = wheelGpsRatio(samples) {
            var list = ratios[route] ?? []
            list.append(r)
            if list.count > 40 { list.removeFirst(list.count - 40) }
            ratios[route] = list
            routeRatios = list
        }
        var heatPoint: FaultDetectors.HeatPoint?
        if let peak = ride.tempPeakC, let air = context.airTempC, let wh = ride.energyWhCal, let moving = ride.movingS, moving > 300 {
            heatPoint = .init(riseC: peak - air, whPerMin: wh / (moving / 60), minutes: moving / 60)
        }
        var drops: [Double] = []
        for k in 1..<frames.count where frames[k].t - frames[k - 1].t > linkDropS { drops.append(frames[k].t) }

        // F7: the phone's GPS speed at a reading's time (samples are ms from the ride start; frames are epoch seconds)
        let startMs = ride.startAt
        let gps: [(t: Int64, kmh: Double)] = samples.compactMap { s in
            guard let g = s.gpsSpeedMps, (s.hAccM ?? 99) <= 20 else { return nil }
            return (s.t, g * 3.6)
        }.sorted { $0.t < $1.t }
        let gpsKmhAt: @Sendable (Double) -> Double? = { t in
            let rel = Int64(t * 1000) - startMs
            var lo = 0, hi = gps.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if gps[mid].t < rel { lo = mid + 1 } else { hi = mid }
            }
            guard lo < gps.count, abs(gps[lo].t - rel) <= 6_000 else { return nil }
            return gps[lo].kmh
        }
        let day = FaultGate.day(epochMs: ride.endAt ?? ride.startAt)
        let input = RideFaultInput(scooterId: scooterId, firmware: firmware, frames: frames, day: day, ruleOuts: rule,
                                   routeId: context.routeId, routeRatios: routeRatios, heat: heatPoint, gpsKmhAt: gpsKmhAt, linkDropTimes: drops,
                                   previousOdoKm: lastOdo[scooterId])
        let report = AfterRideFaults.run(input, book: &book, heat: &heat)
        if let odo = frames.last(where: { $0.odometerKm != nil })?.odometerKm { lastOdo[scooterId] = odo }

        FaultStore.save(db, FaultStore.bookKey, book)
        FaultStore.save(db, FaultStore.heatKey, heat)
        FaultStore.save(db, FaultStore.ratiosKey, ratios)
        FaultStore.save(db, FaultStore.lastOdoKey, lastOdo)
        // N10-15: every occurrence past the bar (told or watching) is kept for the mechanic report
        if !report.beyond.isEmpty {
            let occ = FaultOccurrence.fromRide(kinds: Set(report.beyond.keys), values: report.beyond, frames: frames, scooterId: scooterId,
                                               rideId: ride.id, day: day, airC: context.airTempC)
            let old = FaultStore.load(db, FaultStore.occurrencesKey, as: [FaultOccurrence].self) ?? []
            FaultStore.save(db, FaultStore.occurrencesKey, FaultOccurrence.append(old, occ))
        }

        guard !report.findings.isEmpty else { return nil }
        var list = FaultStore.records(db)
        let odoNow = lastOdo[scooterId]
        for f in report.findings {
            list = FaultRecord.merge(list, FaultRecord(kind: f.kind, scooterId: scooterId, value: f.value, day: day, odoKm: odoNow))
        }
        FaultStore.saveRecords(db, list)
        let codes: [String] = report.findings.map { (f: FaultFinding) -> String in f.kind.code }
        Log.info(source: "faults", "After ride: " + codes.joined(separator: ", "))
        guard let show = report.show else { return nil }
        let kind: FaultKind = show.kind
        return list.first { (rec: FaultRecord) -> Bool in rec.kind == kind && rec.scooterId == scooterId && rec.status == .open }
    }
}

/// N10-12 (batch 10) switch-on alerts: F11 "Your battery needs checking" (parked drain), F12 "Your charger needs checking"
/// (battery not filled), F16 "Km counter reset" across a park. Judged on the first 20 s of readings after the scooter connects.
/// App open → pop-up over Home; app in the background → a notification (tapping it opens the app, where the pop-up waits);
/// a ride starting within those seconds → the pop-up waits for the ride summary.
final class FaultSwitchOn {
    static let shared = FaultSwitchOn()
    static let collectS = 20.0
    /// The voltage rose this much across the park: a charge happened
    static let chargedV = 0.3

    private var collecting = false
    private var assembler = FrameAssembler()
    private var frames: [ScooterFrame] = []
    /// A switch-on finding that waits for the ride summary
    var deferred: FaultRecord?

    private init() {}

    func connected() {
        guard !RecorderService.shared.simActive else { return }
        collecting = true
        assembler = FrameAssembler()
        frames = []
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collectS) { [weak self] in self?.evaluate() }
    }

    func packet(_ bytes: [UInt8], at t: Double) {
        guard collecting, let f = assembler.ingest(bytes, at: t) else { return }
        frames.append(f)
    }

    private func evaluate() {
        guard collecting else { return }
        collecting = false
        // EXPERIMENTAL charging speed: while measuring, a switch-on is a charging reading only. The charger lifts the voltage,
        // so these readings must never teach the F11 / F12 normals.
        if ChargeAutoStore.active(AppModel.shared.database) {
            ChargeAutoStore.switchedOn(frames, db: AppModel.shared.database)
            frames = []
            return
        }
        guard let db = AppModel.shared.database, !db.isReadOnly, frames.count > 5, !GarageService.activeIsBorrowed(db) else { return }
        let id = ScooterRecord.latest(in: db)?.id ?? "scooter"
        let last = try? db.writer.read { d in
            try Row.fetchOne(d, sql: """
                SELECT endAt, endRestV, odoEndKm FROM ride
                WHERE (scooterId = ? OR scooterId IS NULL) AND endAt IS NOT NULL AND isSimulated = 0
                ORDER BY endAt DESC LIMIT 1
                """, arguments: [id])
        }
        let endAt: Int64? = last?["endAt"]
        let endV: Double? = last?["endRestV"]
        let odoEnd: Double? = last?["odoEndKm"]
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let firstV = FaultDetectors.f12RestingVoltage(frames)
        let odoNow = frames.lazy.compactMap(\.odometerKm).first
        let charged = firstV != nil && endV != nil && firstV! > endV! + Self.chargedV
        var park: (startV: Double, endV: Double, hours: Double, odoStartKm: Double?, odoEndKm: Double?)?
        if let a = endAt, let v0 = endV, let v1 = firstV {
            park = (v0, v1, Double(nowMs - a) / 3_600_000, odoEnd, odoNow)
        }
        var book = FaultStore.load(db, FaultStore.bookKey, as: FaultBook.self) ?? FaultBook()
        let day = FaultGate.day(epochMs: nowMs)
        let report = AfterRideFaults.switchOn(scooterId: id, day: day, park: park, firstFrames: frames, charged: charged, book: &book)
        FaultStore.save(db, FaultStore.bookKey, book)
        frames = []
        guard let show = report.show else { return }
        var list = FaultStore.records(db)
        for f in report.findings {
            list = FaultRecord.merge(list, FaultRecord(kind: f.kind, scooterId: id, value: f.value, day: day, odoKm: odoNow))
        }
        FaultStore.saveRecords(db, list)
        FaultCenter.shared.reload(db)
        guard let rec = list.first(where: { $0.kind == show.kind && $0.scooterId == id && $0.status == .open }) else { return }
        Log.info(source: "faults", "Switch-on: \(show.kind.code)")
        if RecorderService.shared.rideActive {
            deferred = rec                                  // waits for the ride summary
        } else {
            FaultCenter.shared.popup = rec
            if UIApplication.shared.applicationState != .active {
                let t = FaultCopy.text(rec.kind)
                Notifier.shared.send(id: "fault.\(rec.kind.rawValue)", title: t.title, body: t.line, soundName: GoingForARideContent.soundName)   // the app's own chime
            }
        }
    }
}
