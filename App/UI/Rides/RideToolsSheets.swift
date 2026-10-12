import Charts
import CorckieCore
import SwiftUI

// M5-01 / M5-02: the sheets behind the ride detail's ... menu: Compare, Merge, Trim.
// Rules and wording are made in CorckieCore (`RideTools/`); these views only draw them and call `RideToolsService`.

// MARK: Compare

struct CompareSheet: View {
    let rideId: String
    /// ui-shot only: two made-up rides
    var preview: (CompareRide, CompareRide)?

    @Environment(\.dismiss) private var dismiss
    @State private var me: CompareRide?
    @State private var all: [CompareRide] = []
    @State private var other: CompareRide?

    var body: some View {
        NavigationStack {
            List {
                if let a = preview?.0 ?? me, let b = preview?.1 ?? other {
                    Section {
                        Text(RideCompareBuilder.relation(a, b)).font(.subheadline).foregroundStyle(.secondary)
                        header(a, b)
                        ForEach(Array(RideCompareBuilder.rows(a, b).enumerated()), id: \.offset) { _, row in line(row) }
                    } footer: {
                        Text("The last column is this ride minus the other one.")
                    }
                        .glassRows()
                }
                if preview == nil {
                    if let me {
                        let suggested = RideCompareBuilder.suggestions(for: me, among: all)
                        if !suggested.isEmpty {
                            Section("Same trip") { ForEach(suggested, id: \.id) { pickRow($0) } }
                                .glassRows()
                        }
                        let rest = others(me, excluding: suggested)
                        if !rest.isEmpty {
                            Section("Other rides") { ForEach(rest, id: \.id) { pickRow($0) } }
                                .glassRows()
                        }
                        if suggested.isEmpty && rest.isEmpty {
                            Text("There is no other ride to compare with yet.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
                .glassList()
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear(perform: load)
            .screen("Compare rides")
        }
    }

    private func others(_ me: CompareRide, excluding suggested: [CompareRide]) -> [CompareRide] {
        let skip = Set(suggested.map(\.id))
        var out: [CompareRide] = []
        for r in all where r.id != me.id && r.isSimulated == me.isSimulated && !skip.contains(r.id) {
            out.append(r)
            if out.count == 30 { break }
        }
        return out
    }

    private func header(_ a: CompareRide, _ b: CompareRide) -> some View {
        HStack(alignment: .top) {
            Spacer().frame(width: 92)
            Text(a.title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .trailing)
            Text(b.title).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .trailing)
            Spacer().frame(width: 84)
        }
        .multilineTextAlignment(.trailing)
    }

    private func line(_ row: CompareRow) -> some View {
        HStack {
            Text(row.label).font(.footnote).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(row.a).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.b).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.difference).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 84, alignment: .trailing)
        }
        .font(.subheadline)
    }

    private func pickRow(_ r: CompareRide) -> some View {
        Button {
            other = r
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).foregroundStyle(.primary)
                    Text(RidesListView.detail(RideListItem(id: r.id, startAt: r.startAt, utcOffsetMin: nil, kind: "ride", distanceM: r.distanceM, totalS: r.totalS)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if other?.id == r.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private func load() {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        all = (try? RideToolsService.compareRides(db)) ?? []
        me = all.first { $0.id == rideId }
        if let me {
            other = RideCompareBuilder.suggestions(for: me, among: all, limit: 1).first
        }
    }
}

// MARK: Merge

struct MergeSheet: View {
    let rideId: String
    let previousId: String
    let offer: MergeOffer
    /// ui-shot only
    var preview: (CompareRide, CompareRide)?
    var onMerged: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var first: CompareRide?
    @State private var second: CompareRide?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let a = preview?.0 ?? first, let b = preview?.1 ?? second {
                    Section("Earlier ride") { rideLine(a) }
                        .glassRows()
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "pause.circle").foregroundStyle(.secondary)
                            Text(offer.text).font(.subheadline)
                        }
                    } header: {
                        Text("The stop between")
                    }
                        .glassRows()
                    Section("This ride") { rideLine(b) }
                        .glassRows()
                }
                Section {
                    Button("Merge into one ride") { merge() }
                        .fontWeight(.semibold)
                        .disabled(preview != nil)
                } footer: {
                    Text("The two rides become one. The stop counts as a stop, not as missing data. You can undo it right after, and later from the ... menu until the next merge.")
                }
                    .glassRows()
            }
                .glassList()
            .navigationTitle("Merge rides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .alert("Could not merge", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorText ?? "")
            }
            .onAppear(perform: load)
            .screen("Merge rides")
        }
    }

    private func rideLine(_ r: CompareRide) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r.title)
            Text(RidesListView.detail(RideListItem(id: r.id, startAt: r.startAt, utcOffsetMin: nil, kind: "ride", distanceM: r.distanceM, totalS: r.totalS)))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func load() {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        let all = (try? RideToolsService.compareRides(db)) ?? []
        first = all.first { $0.id == previousId }
        second = all.first { $0.id == rideId }
    }

    private func merge() {
        guard let db = AppModel.shared.database else { return }
        do {
            let kept = try RideToolsService.merge(db, firstId: previousId, secondId: rideId)
            dismiss()
            onMerged(kept)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: Trim

struct TrimSheet: View {
    let rideId: String
    /// ui-shot only: made-up samples
    var previewSamples: [RideSample]?
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var samples: [RideSample] = []
    @State private var stops: [RideStopSpan] = []
    @State private var walks: [RideStopSpan] = []
    @State private var bridges: [RideStopSpan] = []
    @State private var lastS: Double = 0
    @State private var startS: Double = 0
    @State private var endS: Double = 0
    @State private var isTrimmed = false
    @State private var original: RideMetrics?
    @State private var errorText: String?

    private var canTrim: Bool { lastS >= RideTrim.minLengthS }

    private var trimmed: RideMetrics {
        RideRecompute.metrics(samples: samples, stops: stops, walks: walks, bridges: bridges, trimStartS: startS, trimEndS: endS)
    }

    var body: some View {
        NavigationStack {
            List {
                if canTrim {
                    Section {
                        chart
                            .frame(height: 120)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start \(Self.clock(startS))").font(.subheadline)
                            Slider(value: Binding(get: { startS }, set: { setStart($0) }), in: 0...max(lastS - RideTrim.minLengthS, 1), step: 1)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("End \(Self.clock(endS))").font(.subheadline)
                            Slider(value: Binding(get: { endS }, set: { setEnd($0) }), in: min(RideTrim.minLengthS, lastS)...max(lastS, RideTrim.minLengthS), step: 1)
                        }
                    } header: {
                        Text("Drag the start and the end along the ride")
                    }
                        .glassRows()
                    Section("Numbers after trimming") {
                        let m = trimmed
                        numbers("Time", before: original.map { RideSummaryBuilder.duration($0.totalS) }, after: RideSummaryBuilder.duration(m.totalS))
                        numbers("Distance", before: original.map { RideSummaryBuilder.distance($0.distanceM) }, after: RideSummaryBuilder.distance(m.distanceM))
                        numbers("Battery", before: original?.usedPct.map { String(format: "%.0f%%", $0) },
                                after: m.usedPct.map { String(format: "%.0f%%", $0) } ?? "\u{2013}")
                        numbers("Top speed", before: original.map { RideSummaryBuilder.speed($0.topSpeedKmh) }, after: RideSummaryBuilder.speed(m.topSpeedKmh))
                    }
                        .glassRows()
                    Section {
                        Button("Save trim") { save() }.fontWeight(.semibold).disabled(previewSamples != nil)
                        if isTrimmed {
                            Button("Reset trim", role: .destructive) { reset() }
                        }
                    } footer: {
                        Text("Nothing is deleted. The ride keeps all its readings; only the numbers use the part you keep. At least one minute stays. Reset trim brings the original numbers back.")
                    }
                        .glassRows()
                } else {
                    Text("This ride is too short to trim.").foregroundStyle(.secondary)
                }
            }
                .glassList()
            .navigationTitle("Trim ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .alert("Could not trim", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorText ?? "")
            }
            .onAppear(perform: load)
            .screen("Trim ride")
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                AreaMark(x: .value("Time", s.t), y: .value("km/h", s.speedKmh ?? s.gpsSpeedKmh ?? 0))
                    .foregroundStyle(Color.accentColor.opacity(0.35))
            }
            RuleMark(x: .value("Start", startS)).foregroundStyle(.green)
            RuleMark(x: .value("End", endS)).foregroundStyle(.red)
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in
            AxisValueLabel { if let t = v.as(Double.self) { Text(Self.clock(t)) } }
        } }
    }

    private func numbers(_ label: String, before: String?, after: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let before, before != after {
                Text(before).foregroundStyle(.secondary).strikethrough()
            }
            Text(after).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func setStart(_ v: Double) {
        startS = v
        if endS - startS < RideTrim.minLengthS { endS = min(lastS, startS + RideTrim.minLengthS) }
    }

    private func setEnd(_ v: Double) {
        endS = v
        if endS - startS < RideTrim.minLengthS { startS = max(0, endS - RideTrim.minLengthS) }
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func load() {
        if let preview = previewSamples {
            samples = preview
            lastS = preview.last?.t ?? 0
            startS = 45
            endS = max(lastS - 30, 90)
            original = RideRecompute.metrics(samples: preview, stops: [], walks: [])
            return
        }
        guard let db = AppModel.shared.displayDatabase, let ride = try? RideQueries(db).ride(id: rideId) else { return }
        let q = RideQueries(db)
        let rows = (try? q.samples(rideId: rideId)) ?? []
        samples = rows.map(Recorder.sample(from:))
        lastS = Double(rows.last?.t ?? 0) / 1000
        let stopRows = (try? q.stops(rideId: rideId)) ?? []
        func span(_ s: StopRecord) -> RideStopSpan { RideStopSpan(startT: Double(s.startT) / 1000, endT: s.endT.map { Double($0) / 1000 }) }
        stops = stopRows.map(span)
        bridges = stopRows.filter { $0.id.hasPrefix("bridge-") }.map(span)
        walks = RideToolsService.walkSpans(rows)
        if let w = RideToolsService.trimWindow(ride) {
            isTrimmed = true
            startS = w.start
            endS = w.end
        } else {
            startS = 0
            endS = lastS
        }
        original = RideRecompute.metrics(samples: samples, stops: stops, walks: walks, bridges: bridges)
        // the numbers the ride had before the first trim, when there are some
        if isTrimmed, let json = try? q.setting(key: RideToolsService.originalKey(rideId)), let data = json.data(using: .utf8),
           let rec = try? JSONDecoder().decode(RideRecord.self, from: data) {
            var m = RideMetrics()
            m.totalS = rec.totalS ?? m.totalS
            m.distanceM = rec.distanceM ?? 0
            m.usedPct = rec.usedPct
            m.topSpeedKmh = (rec.topSpeedMps ?? 0) * 3.6
            original = m
        }
    }

    private func save() {
        guard let db = AppModel.shared.database else { return }
        do {
            try RideToolsService.trim(db, rideId: rideId, startS: startS, endS: endS)
            dismiss()
            onChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reset() {
        guard let db = AppModel.shared.database else { return }
        do {
            try RideToolsService.resetTrim(db, rideId: rideId)
            dismiss()
            onChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: ui-shot previews

enum RideToolsPreview {
    static func compare() -> (CompareRide, CompareRide) {
        let a = CompareRide(id: "a", title: "Mon 6 Oct, 08:10", startAt: 1_790_000_000_000, routeId: "r", variantId: "v", distanceM: 8_400, totalS: 1_500,
                            movingS: 1_380, avgMovingMps: 6.1, topSpeedMps: 10.8, usedPct: 12, elevGainM: 38, energyWhRaw: 214)
        let b = CompareRide(id: "b", title: "Sun 5 Oct, 08:05", startAt: 1_789_900_000_000, routeId: "r", variantId: "v", distanceM: 8_350, totalS: 1_420,
                            movingS: 1_350, avgMovingMps: 6.4, topSpeedMps: 10.2, usedPct: 10, elevGainM: 36, energyWhRaw: 190)
        return (a, b)
    }

    static let mergeOffer = MergeOffer(gapS: 660, gapM: 80)

    static func merge() -> (CompareRide, CompareRide) {
        let a = CompareRide(id: "a", title: "Mon 6 Oct, 08:10", startAt: 1_790_000_000_000, distanceM: 5_200, totalS: 900)
        let b = CompareRide(id: "b", title: "Mon 6 Oct, 08:36", startAt: 1_790_001_560_000, distanceM: 3_100, totalS: 600)
        return (a, b)
    }

    static func samples() -> [RideSample] {
        var out: [RideSample] = []
        for i in 0..<120 {
            let x = Double(i)
            let speed: Double = 14 + 12 * abs(sin(x / 9))
            let lat: Double = 40 + x * 0.000_18
            let lon: Double = -75 + x * 0.000_22
            let alt: Double = 30 + 8 * sin(x / 20)
            let odo: Double = 100 + x * 0.025
            out.append(RideSample(t: x * 5, speedKmh: speed, lat: lat, lon: lon, hAccM: 6, altBaroM: alt,
                                  voltage: 54, currentA: 4, batteryPct: 81 - i / 24, tempC: 30, odometerKm: odo))
        }
        return out
    }
}
