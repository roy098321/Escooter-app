import CorckieCore
import Foundation

/// Batch 103.081126.00 checks, on made-up input only (nothing real is read or written).
/// u194 B73 every reading starts empty on a new connection, u195 B74 25 / 50 m places, u196 B75 fuel price digits,
/// u197 B76 the ride screen waits for the real ride, u198 V-U1 above usual and extreme, u199 V-U2 battery decay levels.
@MainActor
enum B103Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        runFreshReadings()
        runSmallPlaces()
        runFuelDigits()
        runRideScreenWaits()
        runUsage()
        runDecay()
    }

    private static func frame(_ t: Double, speed: Double = 0, pct: Int? = 80, tempC: Double? = nil, noTemp: Bool = false, current: Double = 0) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = speed
        f.batteryPct = pct
        f.odometerKm = 100
        f.voltage = 50
        f.temperatureC = tempC
        f.temperatureNoReading = noTemp
        f.currentA = current
        return f
    }

    // MARK: u194

    private static func runFreshReadings() {
        let expect = Expect()
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, pct: 62, tempC: 87)), at: 1)
        e.handle(.disconnected, at: 2)
        e.handle(.connected, at: 50_000)
        expect(e.temperatureC == nil && e.batteryPct == nil && e.odometerKm == nil && e.speedKmh == nil, "a new connection starts empty")
        e.handle(.frame(frame(50_001, tempC: nil, noTemp: true)), at: 50_001)
        expect(e.temperatureC == nil, "the boot \"no temperature yet\" never brings back 87 \u{00B0}C")
        var d = V09Director()
        var said: [V09Message] = []
        for t in stride(from: 0.0, through: 40, by: 1) { said += d.update(V09Input(t: t, pct: 98, tempC: 87, rideKm: 0, speedKmh: 0, currentA: 0)) }
        expect(!said.contains(.engineHot(c: 87)), "no engine line before the motor ran")
        expect.report("u194")
    }

    // MARK: u195

    private static func runSmallPlaces() {
        let expect = Expect()
        expect(Array(PlaceListBuilder.radiusChoices.prefix(2)) == [25, 50], "25 and 50 m are offered")
        let p = PlaceInfo(id: "p", point: GeoPoint(lat: 0, lon: 0), radiusM: 25)
        expect(PlaceMatcher.reaches(p, GeoPoint(lat: 0.00018, lon: 0), tripLengthM: 5_000), "an end 20 m away is inside 25 m")
        expect(!PlaceMatcher.reaches(p, GeoPoint(lat: 0.00036, lon: 0), tripLengthM: 5_000), "40 m is outside")
        expect(TripRules.widenRadius(endDistancesM: [30, 45], radiusM: 25, choices: PlaceListBuilder.radiusChoices) == 50, "widen 25 \u{2192} 50 m")
        expect.report("u195")
    }

    // MARK: u196

    private static func runFuelDigits() {
        let expect = Expect()
        expect(FuelPriceEntry.format("827") == "8.27", "8 2 7 \u{2192} 8.27")
        expect(FuelPriceEntry.format("82") == "8.2", "8 2 \u{2192} 8.2")
        expect(FuelPriceEntry.value("8.2") == nil, "Save waits for the 3rd digit")
        expect(FuelPriceEntry.format("8.27") == "8.27", "pasted with a point")
        expect.report("u196")
    }

    // MARK: u197

    private static func runRideScreenWaits() {
        let expect = Expect()
        var e = RideEngine()
        e.handle(.connected, at: 0)
        for t in stride(from: 1.0, through: 20, by: 0.5) { e.handle(.frame(frame(t, speed: 3)), at: t) }
        expect(e.rideActive && !e.liveInput(at: 20).ridingEngaged, "wheeled out at 3 km/h for 20 s: recording, no ride screen")
        for t in stride(from: 20.5, through: 30, by: 0.5) { e.handle(.frame(frame(t, speed: 12, current: 6)), at: t) }
        expect(e.liveInput(at: 30).ridingEngaged, "rode off: the screen opens")
        expect.report("u197")
    }

    // MARK: u198

    private static func runUsage() {
        let expect = Expect()
        let mine: [Double] = [2.35, 2.41, 2.44, 2.48, 2.50, 2.54, 2.55, 2.58, 2.60, 2.61, 2.63, 2.64, 2.65, 2.66,
                              2.66, 2.68, 2.70, 2.72, 2.74, 2.78, 2.82, 2.87, 2.89, 2.91, 2.95, 2.98, 3.02, 3.09]
        let l = UsageLines.from(perKm: mine)
        expect(abs(l.level1Share - 0.11) < 0.03 && abs(l.level2Share - 0.32) < 0.04,
               String(format: "a rider like you: above usual from +%.0f %%, extreme from +%.0f %%", l.level1Share * 100, l.level2Share * 100))
        func drive(_ pctPerKm: Double, _ headings: [Double]) -> UsageWatch.Cause? {
            var w = UsageWatch()
            var t = 0.0, km = 0.0
            while km <= 5 {
                if let c = w.update(t: t, rideKm: km, livePct: 90 - km * pctPerKm, powerW: pctPerKm * 8 * 20, speedKmh: 20,
                                    courseDeg: headings[Int(km) % headings.count], whPerPct: 8, usualPctPerKm: 2.66, lines: l) { return c }
                t += 1
                km += 20.0 / 3600
            }
            return nil
        }
        expect(drive(2.8, [0, 180]) == nil, "+5 %: quiet")
        expect(drive(2.66 * 1.5, [0, 180]) == .drag, "+50 % both ways: Unusual drag, check brakes and tyres")
        expect(drive(2.66 * 1.5, [90]) != .drag, "+50 % one way only is not drag")
        expect(V09Message.unusualDrag.urgent && V09Message.unusualDrag.line == "Unusual drag, check brakes and tyres.", "the drag line, said at once")
        expect.report("u198")
    }

    // MARK: u199

    private static func runDecay() {
        let expect = Expect()
        let day: Int64 = 86_400_000
        var rides: [DecayRide] = []
        var t: Int64 = 0
        while t < 7 * 365 * day {
            let doy = Double(t / day % 365)
            let temp = 17.5 + 7.5 * cos(doy / 365 * 2 * .pi)
            let cold = temp < 20 ? 1 - 0.015 * (20 - temp) : 1.0
            let health = 1 - 0.05 * Double(t) / Double(365 * day)
            rides.append(DecayRide(startAt: t, distanceM: 15_000, usedPct: 15 / (38 * health * cold) * 100, airTempC: temp))
            t += 2 * day
        }
        var sent: Set<Int> = []
        var said: [Int] = []
        var at = 120 * day
        while at < 7 * 365 * day {
            let r = BatteryDecay.report(rides: rides.filter { $0.startAt <= at }, nowMs: at)
            if let l = BatteryDecay.noticeLevel(report: r, sent: sent) {
                said.append(l)
                sent.formUnion(stride(from: 90, through: l, by: -5))
            }
            at += 15 * day
        }
        expect(said == [90, 85, 80, 75, 70], "made-up 7 years at 5 %/year: notices at " + said.map(String.init).joined(separator: ", "))
        let r = BatteryDecay.report(rides: rides, nowMs: 5 * 365 * day)
        expect(r.nowKm != nil && r.healthPct != nil && r.points.count > 10, "the report has km, health and a curve")
        expect(BatteryDecay.notice(level: 70, report: r).title == "Battery worn", "70 % = Battery worn")
        expect.report("u199")
    }
}
