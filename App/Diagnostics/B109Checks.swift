import CorckieCore
import Foundation

/// Batch 109.131226.03 (batch 9, audit 18 Nov) check u201, on made-up input only: the new-rider rules, one km-left number for the
/// tile, the voice and the summary, a ride's cost adding up to the week, and the shared copy without its ends (in the ocean, no real place).
@MainActor
enum B109Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        let expect = Expect()
        expect(NewRider.opensOnboarding(onboardingDone: false, paired: false) && !NewRider.opensOnboarding(onboardingDone: true, paired: false),
               "A-01: a fresh install opens onboarding; Set up later is not forced again")
        expect(NewRider.isFreshInstall(lastSeenWhatsNew: nil, onboardingDone: false, paired: false), "A-02: no What's new on a fresh install")
        expect(!NewRider.outsideDataAllowed(onboardingDone: false, paired: false, locationAllowed: true), "A-03: no outside data before onboarding")
        expect(NewRider.cantFind(searchingSinceS: 0, nowS: 30, found: false), "A-07: Can't find after 30 s")
        // A-14 / A-15: the tile and the voice from one number
        let km = KmLeft.km(levelPct: 80, pctPerKm: 2.5, reservePct: 5)
        expect(km == 30 && KmLeft.tileText(km) == "\u{2248} 30 km left", "A-14: tile \(KmLeft.tileText(km))")
        expect(V09Message.everyTen(pct: 80, kmLeft: km).line == "Battery at eighty percent, about thirty kilometres left.",
               "A-15: the voice says the same km")
        expect(KmLeft.tileText(nil) == "learning range" && V09Message.everyTen(pct: 80).line == "Battery at eighty percent.",
               "learning: no km on the tile or in the voice")
        // A-16: a week of rides adds up
        let day: Int64 = 86_400_000
        let rides = (0..<5).map { StatsRide(startAt: 1_790_000_000_000 + Int64($0) * day, utcOffsetMin: 120, kind: "ride",
                                             distanceM: 6_000, totalS: 1_200, usedPct: 10 + Double($0)) }
        let prices = StatsPrices(packWh: 760)
        let sum = rides.reduce(0.0) { $0 + StatsCalc.rideCostIls($1, prices: prices) }
        let period = StatsCalc.period(span: .week, mode: .rolling, nowMs: 1_790_000_000_000 + 4 * day + 3_600_000, utcOffsetMin: 120)
        let week = StatsCalc.totals(rides, period: period, prices: prices, utcOffsetMin: 120).electricityIls
        expect(abs(sum - week) < 0.000_1, String(format: "A-16: 5 ride costs %.3f = week %.3f", sum, week))
        // A-17: nothing left within 200 m of the start or the end
        let rows = (0..<60).map { i in ReplayRow(t: Double(i) * 5, lat: 0.0 + Double(i) * 0.000_5, lon: -30.0, speedKmh: 20, batteryPct: 80) }
        let cut = ShareTrim.hideEnds(rows)
        let ends = ShareTrim.ends(rows)
        let leftNear = cut.contains { r in
            guard let lat = r.lat, let lon = r.lon else { return false }
            return PrivacyExport.inZone(lat: lat, lon: lon, zones: ends)
        }
        expect(!leftNear && cut.count == rows.count && cut.compactMap(\.speedKmh).count == rows.count,
               "A-17: no point within 200 m of the ends; speed and battery kept")
        expect.report("u201")
    }
}
