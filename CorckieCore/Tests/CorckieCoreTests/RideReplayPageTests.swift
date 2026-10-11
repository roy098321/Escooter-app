import XCTest
@testable import CorckieCore

/// M5-04: Ride Replay data (1 Hz timeline, map frame, tiles) and the HTML around it.
final class RideReplayPageTests: XCTestCase {
    /// A made-up ride in the ocean: readings every 5 s for `seconds`, heading north-east at 18 km/h.
    private func rows(seconds: Int = 300, lat0: Double = 10, lon0: Double = -30) -> [ReplayRow] {
        var out: [ReplayRow] = []
        var t = 0
        while t <= seconds {
            let s = Double(t)
            let lat: Double = lat0 + s * 0.000_04
            let lon: Double = lon0 + s * 0.000_04
            let speed: Double = 10 + Double(t % 40)
            let battery: Double = 80 - Double(t / 100)
            out.append(ReplayRow(t: s, lat: lat, lon: lon, hAccM: 5, speedKmh: speed, gpsKmh: speed - 1, altM: 30 + s * 0.02,
                                 powerW: 200, batteryPct: battery, tempC: 30))
            t += 5
        }
        return out
    }

    private func data(seconds: Int = 300, stops: [(startS: Double, endS: Double)] = []) throws -> ReplayData {
        try XCTUnwrap(ReplayBuilder.make(title: "Morning ride", dateLabel: "6 Oct", startAtMs: 1_790_000_000_000, utcOffsetMin: 180,
                                         rows: rows(seconds: seconds), stops: stops, info: ReplayRideInfo(distanceM: 5_000, startPct: 80, endPct: 77)))
    }

    // MARK: Timeline

    func testTimelineIsOnePointPerSecondAndInterpolates() {
        let line = ReplayBuilder.timeline(rows(seconds: 100))
        XCTAssertEqual(line.count, 101)
        // speed at t=0 is 10, at t=5 it is 15: one second in is 11
        XCTAssertEqual(line[1].speedKmh ?? 0, 11, accuracy: 0.001)
        XCTAssertEqual(line[5].speedKmh ?? 0, 15, accuracy: 0.001)
        // the battery is a step, not a slope
        XCTAssertEqual(line[99].batteryPct, 80)
        XCTAssertEqual(line[100].batteryPct, 79)
    }

    func testTimelineHoldsAcrossALongGap() {
        let a = ReplayRow(t: 0, lat: 10, lon: -30, hAccM: 5, speedKmh: 20, batteryPct: 80)
        let b = ReplayRow(t: 100, lat: 10.01, lon: -30, hAccM: 5, speedKmh: 0, batteryPct: 79)
        let line = ReplayBuilder.timeline([a, b])
        XCTAssertEqual(line.count, 101)
        XCTAssertEqual(line[50].speedKmh, 20)
        XCTAssertEqual(line[50].lat, 10)
        XCTAssertEqual(line[100].lat ?? 0, 10.01, accuracy: 1e-9)
        XCTAssertTrue(ReplayBuilder.timeline([]).isEmpty)
    }

    // MARK: Data

    func testDataArraysAllHaveOnePointPerSecond() throws {
        let d = try data(seconds: 300)
        XCTAssertEqual(d.spd.count, 301)
        for n in [d.gps.count, d.ele.count, d.pwr.count, d.bat.count, d.tmp.count, d.x.count, d.y.count] { XCTAssertEqual(n, 301) }
        XCTAssertEqual(d.ele.first, 0)                                  // elevation is relative to the start
        XCTAssertEqual(d.ele.last ?? 0, 6, accuracy: 0.1)
        XCTAssertEqual(d.s.mins, 5)
        XCTAssertEqual(d.s.dist, 5)
        XCTAssertEqual(d.s.bat0, 80)
        XCTAssertEqual(d.s.bat1, 77)
    }

    func testClockLabelsFollowTheUtcOffset() throws {
        // 1_790_000_000 s = 2026-09-21 14:13:20 UTC; at +03:00 that is 17:13:20
        let d = try data(seconds: 120)
        XCTAssertEqual(d.s.start, "17:13")
        XCTAssertEqual(d.s.end, "17:15")
        XCTAssertEqual(d.t0, 17 * 3_600 + 13 * 60 + 20)
    }

    func testStopsBecomeIndexSpansAndShortOnesAreDropped() throws {
        let d = try data(stops: [(startS: 60, endS: 90), (startS: 100, endS: 103), (startS: 290, endS: 400)])
        XCTAssertEqual(d.stops, [[60, 90], [290, 300]])
    }

    func testMapFrameKeepsTheRouteInsideAndTilesAreBounded() throws {
        let d = try data(seconds: 600)
        let m = try XCTUnwrap(d.map)
        XCTAssertTrue((11...17).contains(m.z))
        XCTAssertLessThanOrEqual(m.w, 4_000)
        XCTAssertLessThanOrEqual(m.h, 4_000)
        for v in d.x { XCTAssertTrue(v >= 0 && v <= Double(m.w)) }
        for v in d.y { XCTAssertTrue(v >= 0 && v <= Double(m.h)) }
        let tiles = ReplayBuilder.tiles(for: d)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertLessThanOrEqual(tiles.count, ReplayBuilder.maxTiles)
        XCTAssertTrue(tiles.allSatisfy { $0.z == m.z })
        XCTAssertEqual(Set(tiles).count, tiles.count)
    }

    func testALongRideDropsToALowerZoomToStayUnderTheTileCap() throws {
        // ~40 km north-east: too many tiles at zoom 17
        var long: [ReplayRow] = []
        for i in 0..<400 {
            let s = Double(i)
            long.append(ReplayRow(t: s * 5, lat: 10 + s * 0.001, lon: -30 + s * 0.001, hAccM: 5, speedKmh: 20, batteryPct: 80))
        }
        let d = try XCTUnwrap(ReplayBuilder.make(title: "Long", dateLabel: "x", startAtMs: 0, utcOffsetMin: 0, rows: long, stops: [], info: ReplayRideInfo()))
        let z = try XCTUnwrap(d.map).z
        XCTAssertLessThan(z, 17)
        XCTAssertLessThanOrEqual(ReplayBuilder.tiles(for: d).count, ReplayBuilder.maxTiles)
    }

    func testNoGpsGivesNoMapAndNoTiles() throws {
        var plain = rows(seconds: 100)
        for i in plain.indices { plain[i].lat = nil; plain[i].lon = nil }
        let d = try XCTUnwrap(ReplayBuilder.make(title: "x", dateLabel: "y", startAtMs: 0, utcOffsetMin: 0, rows: plain, stops: [], info: ReplayRideInfo()))
        XCTAssertNil(d.map)
        XCTAssertTrue(d.x.isEmpty)
        XCTAssertTrue(ReplayBuilder.tiles(for: d).isEmpty)
    }

    func testTooLittleDataGivesNothing() {
        XCTAssertNil(ReplayBuilder.make(title: "x", dateLabel: "y", startAtMs: 0, utcOffsetMin: 0, rows: [ReplayRow(t: 0, speedKmh: 5)], stops: [], info: ReplayRideInfo()))
    }

    func testMercatorKnownPoints() {
        let a = ReplayBuilder.mercator(lat: 0, lon: 0, z: 0)
        XCTAssertEqual(a.x, 128, accuracy: 1e-9)
        XCTAssertEqual(a.y, 128, accuracy: 1e-9)
        let b = ReplayBuilder.mercator(lat: 0, lon: 0, z: 2)
        XCTAssertEqual(b.x, 512, accuracy: 1e-9)
        let c = ReplayBuilder.mercator(lat: 0, lon: -180, z: 1)
        XCTAssertEqual(c.x, 0, accuracy: 1e-9)
    }

    // MARK: HTML

    func testStandaloneFileHasEverythingInsideAndNoOutsideAddress() throws {
        let d = try data(seconds: 200)
        let html = ReplayHTML.build(d) { tile in "data:image/png;base64,AAAA#\(tile.z)/\(tile.x)/\(tile.y)" }
        XCTAssertTrue(html.contains("<title>Morning ride</title>"))
        XCTAssertTrue(html.contains("\"spd\":["))
        XCTAssertFalse(html.contains("/*DATA*/"))
        XCTAssertFalse(html.contains("/*TILES*/"))
        XCTAssertFalse(html.contains("/*TITLE*/"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("<link"))
        XCTAssertFalse(html.contains("src=\"http"))
        XCTAssertEqual(html.components(separatedBy: "<image ").count - 1, ReplayBuilder.tiles(for: d).count)
    }

    func testTheB01ChartFixIsInThePage() {
        let css = ReplayTemplate.html
        XCTAssertTrue(css.contains("#charts { grid-auto-rows: minmax(150px, 1fr); overflow-y: auto;"))
        XCTAssertTrue(css.contains(".chart { min-height: 150px; }"))
        XCTAssertTrue(css.contains(".crow { min-height: 96px; }"))
        XCTAssertTrue(css.contains("fix 2026-10-03"))
    }

    func testPlaybackSpeedsAreQuarterTo50() {
        let html = ReplayTemplate.html
        XCTAssertTrue(html.contains("var RATES = [0.25, 0.5, 1, 2, 5, 10, 20, 50];"))
        XCTAssertTrue(html.contains("window.__replay"))
        XCTAssertTrue(html.contains("@media (min-width:1000px)"))
        XCTAssertTrue(html.contains("id=\"tabs\""))
    }

    func testScriptBracketsBalance() {
        let html = ReplayTemplate.html
        guard let a = html.range(of: "<script>"), let b = html.range(of: "</script>") else { return XCTFail("no script") }
        let script = String(html[a.upperBound..<b.lowerBound])
        for (open, close) in [("{", "}"), ("(", ")"), ("[", "]")] {
            XCTAssertEqual(script.components(separatedBy: open).count, script.components(separatedBy: close).count, "\(open)\(close)")
        }
    }

    func testTilesLeftOutWhenNoSource() throws {
        let d = try data(seconds: 200)
        let html = ReplayHTML.build(d) { _ in nil }
        XCTAssertEqual(html.components(separatedBy: "<image ").count - 1, 0)
        XCTAssertTrue(html.contains("\"map\":{"))
    }

    func testTitleIsEscapedAndScriptCannotBeClosedByData() throws {
        var d = try data(seconds: 100)
        d.title = "A <b>&\"</script> ride"
        let html = ReplayHTML.build(d) { _ in nil }
        XCTAssertTrue(html.contains("<title>A &lt;b&gt;&amp;&quot;&lt;/script&gt; ride</title>"))
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 1)
    }

    func testFileName() {
        XCTAssertEqual(ReplayHTML.fileName(title: "Morning ride", isoDate: "2026-10-06"), "Ride Replay \u{2013} Morning ride 2026-10-06.html")
        XCTAssertEqual(ReplayHTML.fileName(title: "a/b:c", isoDate: "2026-10-06"), "Ride Replay \u{2013} a-b-c 2026-10-06.html")
        XCTAssertEqual(ReplayHTML.fileName(title: "  ", isoDate: "2026-10-06"), "Ride Replay \u{2013} Ride 2026-10-06.html")
    }
}
