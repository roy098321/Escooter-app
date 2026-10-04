import CorckieCore
import MapKit
import SwiftUI

/// M1-13: the ride summary (opens when a ride ends) and the ride detail (a row in the Rides list): ONE layout.
/// All numbers, labels and notes are made in CorckieCore (`RideSummaryBuilder`, unit tested); this view draws them.
/// No records, badges or comparisons (CONCEPT P-3): only this ride's own numbers.
struct RideDetailView: View {
    var rideId: String?
    var preview: RideSummaryModel?
    /// Summary after a ride: a Done button closes it. Nil = pushed from the Rides list (back button).
    var onDone: (() -> Void)?

    @State private var model: RideSummaryModel?
    @State private var missing = false
    @State private var confirmDelete = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let m = preview ?? model {
                content(m)
            } else if missing {
                ContentUnavailableView("Ride not found", systemImage: "questionmark.circle",
                                       description: Text("This ride is no longer stored."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle((preview ?? model)?.title ?? "Ride")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onDone).fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete ride", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete this ride?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete ride", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The ride and all its stored readings are removed. This cannot be undone.")
        }
        .alert("Could not delete", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: load)
        .screen(onDone != nil ? "Ride summary" : "Ride detail")
    }

    // MARK: Layout

    private func content(_ m: RideSummaryModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !m.subtitle.isEmpty {
                    Text(m.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if m.noGps {
                    noGpsCard
                } else {
                    mapCard(m.path)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(m.mainStats.enumerated()), id: \.offset) { _, s in tile(s) }
                }
                VStack(spacing: 0) {
                    ForEach(Array(m.scooterStats.enumerated()), id: \.offset) { i, s in
                        if i > 0 { Divider() }
                        HStack {
                            Text(s.label)
                            Spacer()
                            Text(s.value).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                ForEach(Array(m.notes.enumerated()), id: \.offset) { _, n in note(n) }
                if !m.infoLines.isEmpty {
                    DisclosureGroup("More info") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(m.infoLines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
    }

    private func tile(_ s: SummaryStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label).font(.footnote).foregroundStyle(.secondary)
            Text(s.value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func note(_ n: SummaryNote) -> some View {
        let symbol: String
        var tint: Color = .secondary
        switch n.kind {
        case .recovered: symbol = "arrow.counterclockwise"
        case .gap: symbol = "location.slash"
        case .phone: symbol = "iphone"
        case .walk: symbol = "figure.walk"
        case .heat: symbol = "thermometer.high"; tint = .red
        case .ignored: symbol = "exclamationmark.circle"
        case .simulated: symbol = "testtube.2"; tint = .purple
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 24)
            Text(n.text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// S7: no path to draw
    private var noGpsCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "location.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("No GPS on this ride").font(.headline)
            Text("The numbers below come from the scooter, so they are complete. There is no path to show.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func mapCard(_ path: RidePathModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: Self.position(path), interactionModes: [.pan, .zoom]) {
                ForEach(Array(path.segments.enumerated()), id: \.offset) { _, seg in
                    MapPolyline(coordinates: seg.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(LiveRideView.color(seg.bucket),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: seg.dashed ? [2, 9] : []))
                }
                ForEach(Array(path.walks.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(Color.gray, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    if let mid = run.dropFirst(run.count / 2).first {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: mid.lat, longitude: mid.lon)) {
                            Image(systemName: "figure.walk")
                                .font(.caption.weight(.bold))
                                .padding(6)
                                .background(Circle().fill(.thinMaterial))
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(Self.legend(path)).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func position(_ path: RidePathModel) -> MapCameraPosition {
        guard let b = path.bounds else { return .automatic }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: b.centerLat, longitude: b.centerLon),
                                          span: MKCoordinateSpan(latitudeDelta: b.latSpan, longitudeDelta: b.lonSpan)))
    }

    static func legend(_ path: RidePathModel) -> String {
        var parts = ["Colour = speed (light green slow, red fast)"]
        if path.segments.contains(where: { $0.dashed }) { parts.append("dashed = phone only") }
        if !path.walks.isEmpty { parts.append("grey = on foot") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Data

    private func load() {
        guard preview == nil else { return }
        guard let id = rideId, let db = AppModel.shared.database,
              let loaded = RideDetailLoader.load(id: id, db: db) else {
            missing = true
            // a summary that cannot load (a discarded piece) closes itself
            onDone?()
            return
        }
        model = loaded
    }

    private func delete() {
        guard preview == nil, let id = rideId, let db = AppModel.shared.database else { return }
        do {
            try RideQueries(db).delete(rideId: id)
            if let onDone { onDone() } else { dismiss() }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Reads one stored ride and builds its summary (nil: no such ride, or a discarded piece).
enum RideDetailLoader {
    static func load(id: String, db: AppDatabase) -> RideSummaryModel? {
        let q = RideQueries(db)
        guard let r = try? q.ride(id: id), r.kind != "discarded" else { return nil }
        let input = RideDetailInput(
            startAt: r.startAt, utcOffsetMin: r.utcOffsetMin, kind: r.kind, status: r.status, endReason: r.endReason,
            distanceM: r.distanceM, totalS: r.totalS, movingS: r.movingS, avgMovingMps: r.avgMovingMps,
            topSpeedMps: r.topSpeedMps, stops: r.stops, energyWhRaw: r.energyWhRaw, usedPct: r.usedPct,
            startRestPct: r.startRestPct, endRestPct: r.endRestPct, odoStartKm: r.odoStartKm, odoEndKm: r.odoEndKm,
            elevGainM: r.elevGainM, elevLossM: r.elevLossM, tempPeakC: r.tempPeakC, tempRiseC: r.tempRiseC,
            ignoredReadings: r.ignoredReadings, hasGps: r.hasGps, isSimulated: r.isSimulated)
        let gaps = ((try? q.gaps(rideId: id)) ?? []).map { RideGapSpan(kind: $0.kind, startT: $0.startT, endT: $0.endT) }
        let points = ((try? q.samples(rideId: id)) ?? []).map { (s: RideSampleRecord) -> RidePoint in
            RidePoint(t: s.t, lat: s.lat, lon: s.lon, hAccM: s.hAccM, speedKmh: s.speedMps.map { v in v * 3.6 },
                      gpsSpeedKmh: s.gpsSpeedMps.map { v in v * 3.6 }, batteryPct: s.batteryPct, mode: s.mode)
        }
        return RideSummaryBuilder.build(input, gaps: gaps, points: points)
    }
}

/// Made-up rides for the CI ui-shots (`-uiShot ride-detail`, `ride-nogps`, `ride-gap`, `ride-walk`). Not real places.
enum RideDetailPreview {
    static func model(_ name: String) -> RideSummaryModel? {
        guard name.hasPrefix("ride-") else { return nil }
        var input = RideDetailInput(
            startAt: 1_790_000_000_000, utcOffsetMin: 180, kind: "ride", status: "ended", endReason: "held",
            distanceM: 8_400, totalS: 1_500, movingS: 1_380, avgMovingMps: 6.1, topSpeedMps: 10.8, stops: 2,
            energyWhRaw: 214, usedPct: 12, startRestPct: 81, endRestPct: 69, odoStartKm: 412.3, odoEndKm: 420.7,
            elevGainM: 38, elevLossM: 35, tempPeakC: 47, tempRiseC: 11, hasGps: true)
        var gaps: [RideGapSpan] = []
        var points: [RidePoint] = []
        for i in 0..<60 {
            let x = Double(i)
            let lat: Double = 40.0 + x * 0.00018
            let wobble: Double = 0.0006 * sin(x / 6)
            let lon: Double = -75.0 + x * 0.00022 + wobble
            let kmh: Double = 12 + 22 * abs(sin(x / 9))
            let pct: Int = 81 - i / 5
            points.append(RidePoint(t: Int64(i) * 5000, lat: lat, lon: lon, hAccM: 6, speedKmh: kmh, batteryPct: pct, mode: "scooter"))
        }
        switch name {
        case "ride-nogps":
            input.hasGps = false
            points = []
        case "ride-gap":
            input.status = "recovered"
            input.tempPeakC = 93
            input.ignoredReadings = 3
            gaps = [RideGapSpan(kind: "scooter", startT: 150_000, endT: 215_000),
                    RideGapSpan(kind: "gps", startT: 240_000, endT: 252_000)]
            for i in 30..<43 { points[i].mode = "phone"; points[i].speedKmh = nil }
        case "ride-walk":
            for i in 44..<52 { points[i].mode = "walk" }
        default:
            break
        }
        return RideSummaryBuilder.build(input, gaps: gaps, points: points)
    }
}
