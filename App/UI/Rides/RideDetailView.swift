import CorckieCore
import MapKit
import SwiftUI

/// M1-13: the ride summary (opens when a ride ends) and the ride detail (a row in the Rides list): ONE layout.
/// All numbers, labels and notes are made in CorckieCore (`RideSummaryBuilder`, unit tested); this view draws them.
/// No records, badges or comparisons (CONCEPT P-3): only this ride's own numbers.
struct RideDetailView: View {
    @ScaledMetric(relativeTo: .body) private var tileMin: CGFloat = 100
    var rideId: String?
    var preview: RideSummaryModel?
    /// Summary after a ride: a Done button closes it. Nil = pushed from the Rides list (back button).
    var onDone: (() -> Void)?
    /// ui-shot only: a made-up route card
    var previewOffer: RouteOfferModel?
    /// ui-shot only: a made-up smart prompt (and the Loaded row)
    var previewPrompt: SmartPromptCard?
    /// ui-shot only: made-up insights (top card, N more, a progress line)
    var previewInsights: RankedInsights?
    /// ui-shot only: made-up layers, elevation and charts
    var previewSeries: RideSeries?

    @State private var model: RideSummaryModel?
    @State private var offer: RouteOfferModel?
    @State private var missing = false
    @State private var prompt: SmartPromptCard?
    @State private var ranked: RankedInsights?
    @State private var showMore = false
    @State private var loadLabel = "Not set"
    @State private var showKgField = false
    @State private var kgText = ""
    @State private var confirmDelete = false
    @State private var errorText: String?
    // M5-01 / M5-02: compare, merge, trim
    @State private var switched: String?
    @State private var showCompare = false
    @State private var showMerge = false
    @State private var showTrim = false
    @State private var showReplay = false
    @State private var replayDownload = false
    @State private var exportFile: ExportedFile?
    @State private var mergeInfo: MergeInfo?
    @State private var isTrimmed = false
    @State private var canUndoMerge = false
    @State private var toast: String?
    // M5-03: map layers, elevation, charts
    @State private var series: RideSeries?
    @State private var layer: MapLayer = .speed
    @Environment(\.dismiss) private var dismiss

    struct ExportedFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    struct MergeInfo {
        var previousId: String
        var previousTitle: String
        var offer: MergeOffer
    }

    /// The ride shown: after a merge this ride is the earlier one
    private var activeId: String? { switched ?? rideId }

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
        .toolbar(.hidden, for: .navigationBar)
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
        .sheet(isPresented: $showCompare) {
            if let id = activeId { CompareSheet(rideId: id).v1Label().glassPresentation() }
        }
        .sheet(isPresented: $showMerge) {
            if let id = activeId, let info = mergeInfo {
                MergeSheet(rideId: id, previousId: info.previousId, offer: info.offer, onMerged: { kept in
                    switched = kept
                    toast = "Rides merged into one."
                    load()
                })
                .v1Label()
                .glassPresentation()
            }
        }
        .sheet(isPresented: $showTrim) {
            if let id = activeId { TrimSheet(rideId: id, onChanged: { toast = "Trim saved."; load() }).v1Label().glassPresentation() }
        }
        .sheet(isPresented: $showReplay) {
            if let id = activeId { NavigationStack { ReplayView(rideId: id, startDownload: replayDownload) }.v1Label().glassPresentation(detents: [.large]) }
        }
        .sheet(item: $exportFile) { file in ShareSheet(url: file.url).v1Label() }
        .overlay(alignment: .bottom) { toastBar }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            toast = nil
        }
        .screen(onDone != nil ? "Ride summary" : "Ride detail")
    }

    @ViewBuilder private var toastBar: some View {
        if let toast {
            HStack {
                Text(toast).font(.subheadline)
                Spacer()
                if canUndoMerge && toast.hasPrefix("Rides merged") {
                    Button("Undo") { undoMerge() }.fontWeight(.semibold)
                }
            }
            .padding(16)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(16)
        }
    }

    private func exportRide(_ format: RideExportService.Format) {
        guard let id = activeId, let db = AppModel.shared.displayDatabase else { return }
        do {
            exportFile = ExportedFile(url: try RideExportService.write(db, rideId: id, format: format))
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func undoMerge() {
        guard let db = AppModel.shared.database else { return }
        do {
            try RideToolsService.undoMerge(db)
            switched = nil
            toast = "Merge undone. Both rides are back."
            load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshTools(_ id: String, _ db: AppDatabase) {
        guard !db.isReadOnly else { return }
        if let m = RideToolsService.mergeOffer(db, rideId: id) {
            mergeInfo = MergeInfo(previousId: m.previousId, previousTitle: m.previousTitle, offer: m.offer)
        } else {
            mergeInfo = nil
        }
        isTrimmed = ((try? RideQueries(db).ride(id: id))?.trimStartAt) != nil
        canUndoMerge = RideToolsService.canUndoMerge(db)
    }

    // MARK: Layout

    /// Sheet opens at half; the made-up shots that show more of the sheet open it full
    private var startDetent: SheetDetent {
        previewSeries != nil || previewPrompt != nil || previewInsights != nil || previewOffer != nil ? .full : .half
    }

    private func content(_ m: RideSummaryModel) -> some View {
        MapSheet(initial: startDetent) {
            mapLayer(m)
        } topBar: {
            topBar(m)
        } side: {
            if !m.noGps, previewSeries != nil || series != nil {
                GlassLayerControl(options: MapLayer.allCases.map { ($0, $0.rawValue) }, selection: $layer)
            }
        } sheet: {
            sheetContent(m)
        }
    }

    private func topBar(_ m: RideSummaryModel) -> some View {
        GlassTopBar(title: m.title, subtitle: m.subtitle) {
            GlassIconButton(symbol: onDone != nil ? "xmark" : "chevron.left", label: onDone != nil ? "Done" : "Back") {
                if let onDone { onDone() } else { dismiss() }
            }
        } trailing: {
            if preview != nil || activeId != nil {
                Menu { shareItems } label: { GlassIcon(symbol: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
            }
            Menu { moreItems } label: { GlassIcon(symbol: "ellipsis") }
                .accessibilityLabel("More")
        }
    }

    /// Share = the existing export and replay actions only
    @ViewBuilder private var shareItems: some View {
        let needsGps = (preview ?? model)?.noGps == true
        Button { replayDownload = false; showReplay = true } label: { Label(needsGps ? "Ride Replay \u{00B7} needs GPS" : "Ride Replay", systemImage: "play.circle") }
            .disabled(needsGps)
        Button { replayDownload = true; showReplay = true } label: { Label("Download Ride Replay", systemImage: "square.and.arrow.down") }
            .disabled(needsGps)
        Button { exportRide(.csv) } label: { Label("Export CSV (one line per reading)", systemImage: "tablecells") }
        Button { exportRide(.gpx) } label: { Label("Export GPX (Strava, Komoot)", systemImage: "map") }
    }

    @ViewBuilder private var moreItems: some View {
        if preview == nil, activeId != nil {
            Button { showCompare = true } label: { Label("Compare with another ride", systemImage: "arrow.left.arrow.right") }
            if mergeInfo != nil {
                Button { showMerge = true } label: { Label("Merge with previous ride", systemImage: "arrow.triangle.merge") }
            }
            Button { showTrim = true } label: { Label(isTrimmed ? "Trim again or reset" : "Trim start / end", systemImage: "scissors") }
            if canUndoMerge {
                Button { undoMerge() } label: { Label("Undo last merge", systemImage: "arrow.uturn.backward") }
            }
            Divider()
        }
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete ride", systemImage: "trash") }
    }

    @ViewBuilder private func mapLayer(_ m: RideSummaryModel) -> some View {
        if m.noGps {
            ZStack {
                MapBackdrop()
                VStack { noGpsCard.padding(.horizontal, 40).padding(.top, 120); Spacer() }
            }
        } else {
            mapView(m.path)
        }
    }

    private func sheetContent(_ m: RideSummaryModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMin), spacing: DS.Space.row)], spacing: DS.Space.row) {
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
            .glassCard(padding: 0)
            if let s = previewSeries ?? series { RideSeriesPanels(series: s) }
            if let r = previewInsights ?? ranked { insightCards(r) }
            if preview == nil, activeId != nil {
                Button { showCompare = true } label: {
                    HStack {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tint)
                        Text("Compare with another ride")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .glassCard(padding: 0)
                }
                .buttonStyle(.plain)
            }
            if let id = activeId, preview == nil {
                VStack(spacing: 0) {
                    ThumbsRow(kind: "start", subjectId: id, label: "Right? Start")
                    ThumbsRow(kind: "end", subjectId: id, label: "Right? End")
                    ThumbsRow(kind: "distance", subjectId: id, label: "Right? Distance")
                }
                .padding(.horizontal, 16)
                .glassCard(padding: 0)
            }
            ForEach(Array(m.notes.enumerated()), id: \.offset) { _, n in note(n) }
            if previewPrompt == nil, prompt == nil, let o = previewOffer ?? offer { offerCard(o) }
            if let p = previewPrompt ?? prompt { promptCard(p) }
            if (activeId != nil && preview == nil) || previewPrompt != nil { loadedRow }
            if let id = activeId, preview == nil { RideNoteCard(rideId: id) }
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
        .padding(.top, 2)
    }

    private func tile(_ s: SummaryStat) -> some View {
        StatTile(value: s.value, label: s.label)
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
        .padding(16)
        .glassCard(padding: 0)
    }

    /// M2-01: "Save as route?" after the same trip twice, or the ride's route once saved
    private func offerCard(_ o: RouteOfferModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.tint).frame(width: 24)
                Text(o.headline).font(.headline)
            }
            Text(o.detail).font(.subheadline).foregroundStyle(.secondary)
            if !o.saved {
                HStack(spacing: 12) {
                    Button("Save route") { routeAction(o.routeId, save: true) }.buttonStyle(.borderedProminent)
                    Button("Not a route") { routeAction(o.routeId, save: false) }.buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
    }

    private func routeAction(_ routeId: String, save: Bool) {
        guard preview == nil, let id = activeId, let db = AppModel.shared.displayDatabase else { return }
        do {
            if save {
                try RouteService.save(routeId: routeId, database: db)
            } else {
                try RouteService.dismiss(routeId: routeId, database: db)
            }
            offer = RouteService.offer(rideId: id, database: db)
        } catch {
            errorText = error.localizedDescription
        }
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
        .glassCard(padding: 0)
    }

    private func mapView(_ path: RidePathModel) -> some View {
        Map(initialPosition: Self.position(path, sheet: true), interactionModes: [.pan, .zoom]) {
            ForEach(Array(layerSegments.enumerated()), id: \.offset) { _, seg in
                MapPolyline(coordinates: seg.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .stroke(MapLayer.color(level: seg.level), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array((layer == .speed ? path.segments : []).enumerated()), id: \.offset) { _, seg in
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
        .accessibilityLabel("Map of the ride. \(layerLegend(path))")
    }

    /// Hills / Wind stretches for the chosen layer (empty for Speed)
    private var layerSegments: [LayerSegment] { (previewSeries ?? series)?.segments(layer) ?? [] }

    private func layerLegend(_ path: RidePathModel) -> String {
        if layer == .speed { return Self.legend(path) }
        if layer == .wind, (previewSeries ?? series)?.wind == nil { return "No wind data yet. It arrives with the weather, a little after the ride." }
        return layer.legend
    }

    /// `sheet`: the bottom half is under the sheet, so the path is framed in the upper part (centre moved south, wider span)
    static func position(_ path: RidePathModel, sheet: Bool = false) -> MapCameraPosition {
        guard let b = path.bounds else { return .automatic }
        let lat = sheet ? max(b.latSpan * 2.2, 0.004) : b.latSpan
        let lon = sheet ? max(b.lonSpan * 1.5, 0.004) : b.lonSpan
        let centerLat = sheet ? b.centerLat - lat * 0.2 : b.centerLat
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: centerLat, longitude: b.centerLon),
                                          span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lon)))
    }

    static func legend(_ path: RidePathModel) -> String {
        var parts = [SpeedPalette.legendText(colourBlind: DisplaySettings.colourBlind)]
        if path.segments.contains(where: { $0.dashed }) { parts.append("dashed = phone only") }
        if !path.walks.isEmpty { parts.append("grey = on foot") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Data

    private func load() {
        guard preview == nil else { return }
        guard let id = activeId, let db = AppModel.shared.displayDatabase,
              let loaded = RideDetailLoader.load(id: id, db: db) else {
            missing = true
            // a summary that cannot load (a discarded piece) closes itself
            onDone?()
            return
        }
        var withExtras = loaded
        if let full = RideSeriesLoader.toFull(db, rideId: id) { withExtras.scooterStats.append(SummaryStat("To full", full)) }
        model = withExtras
        series = RideSeriesLoader.load(db, rideId: id)
        refreshTools(id, db)
        offer = RouteService.offer(rideId: id, database: db)
        refreshSmart(id, db)
        refreshInsights(id, db)
    }

    private func delete() {
        guard preview == nil, let id = activeId, let db = AppModel.shared.database else { return }
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
        var model = RideSummaryBuilder.build(input, gaps: gaps, points: points)
        // M4-02 (check mf1): the ride's factor columns as one line under More info
        if let line = FactorEffects.developerLine(db, rideId: id) { model.infoLines.append(line) }
        return model
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

extension RideDetailPreview {
    /// Made-up layers, a climb and charts for `-uiShot ride-detail-full` (not a real place)
    static func series() -> RideSeries {
        var points: [SeriesPoint] = []
        for i in 0..<120 {
            let x = Double(i)
            let lat: Double = 40.0 + x * 0.000_18
            let lon: Double = -75.0 + x * 0.000_22 + 0.0006 * sin(x / 6)
            let speed: Double = 12 + 22 * abs(sin(x / 9))
            let alt: Double = i < 40 ? 20 : (i < 80 ? 20 + Double(i - 40) * 0.8 : 52 - Double(i - 80) * 0.6)
            points.append(SeriesPoint(t: x * 5, lat: lat, lon: lon, hAccM: 6, speedKmh: speed, batteryPct: 81 - i / 10, altM: alt))
        }
        var series = RideSeries()
        series.points = points
        series.hasAltitude = true
        series.hills = RideLayers.hills(points)
        let elevation = RideLayers.elevation(points)
        series.profile = elevation.profile
        series.climbs = elevation.climbs
        series.chart = RideLayers.chartSeries(points)
        let start: Int64 = 1_790_000_000_000
        let hour = (start / 3_600_000) * 3_600_000
        let rows = [WeatherRow(cellKey: "preview", hourAt: hour, source: "preview", kind: .history, windKmh: 22, windFromDeg: 250, fetchedAt: 0),
                    WeatherRow(cellKey: "preview", hourAt: hour + 3_600_000, source: "preview", kind: .history, windKmh: 22, windFromDeg: 250, fetchedAt: 0)]
        series.wind = RideLayers.wind(points, rideStartMs: start, rows: rows)
        return series
    }
}

// MARK: M4-05: smart prompt + Loaded tag

extension RideDetailView {
    fileprivate func refreshSmart(_ id: String, _ db: AppDatabase) {
        let ride = try? SmartPromptQueries(db).rideAnswer(id)
        loadLabel = LoadLevel.label(level: ride?.loadLevel, kg: ride?.loadKg)
        guard !db.isReadOnly, let card = SmartPromptService.card(db, rideId: id) else { prompt = nil; return }
        prompt = card
        SmartPromptService.shown(db, rideId: id)
    }

    fileprivate func answer(_ a: SmartAnswer) {
        guard let id = activeId, let db = AppModel.shared.database else { return }
        try? SmartPromptService.answer(db, rideId: id, a)
        prompt = nil
        refreshSmart(id, db)
        refreshInsights(id, db)
    }

    fileprivate func dismissPrompt() {
        guard let id = activeId, let db = AppModel.shared.database else { return }
        SmartPromptService.dismiss(db, rideId: id)
        prompt = nil
    }

    fileprivate func setLoad(_ level: LoadLevel, kg: Double? = nil) {
        guard let id = activeId, let db = AppModel.shared.database else { return }
        try? SmartPromptService.setLoad(db, rideId: id, level: level, kg: kg)
        refreshSmart(id, db)
        refreshInsights(id, db)
    }

    fileprivate func promptCard(_ p: SmartPromptCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble").foregroundStyle(.secondary).frame(width: 24)
                Text(p.text).font(.subheadline)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(p.answers, id: \.self) { a in
                    Button(a.title) { answer(a) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            Button("Not now") { dismissPrompt() }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(padding: 0)
    }

    fileprivate var loadedRow: some View {
        HStack {
            Text("Loaded")
            Spacer()
            Menu {
                Button("None") { setLoad(.none) }
                Button("Light (\(Int((RiderSettings.kg(AppModel.shared.database, .light) ?? 5).rounded())) kg)") { setLoad(.light) }
                Button("Heavy (\(Int((RiderSettings.kg(AppModel.shared.database, .heavy) ?? 15).rounded())) kg)") { setLoad(.heavy) }
                Button("Exact kg…") { kgText = ""; showKgField = true }
            } label: {
                HStack(spacing: 4) {
                    Text(loadLabel).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(padding: 0)
        .alert("Exact load (kg)", isPresented: $showKgField) {
            TextField("kg", text: $kgText).keyboardType(.decimalPad)
            Button("Save") {
                if let kg = Double(kgText.replacingOccurrences(of: ",", with: ".")) { setLoad(.custom, kg: kg) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What you carried, in kg. It helps explain battery use.")
        }
    }
}

// MARK: M4-10: insights on the summary / ride detail

extension RideDetailView {
    fileprivate func refreshInsights(_ id: String, _ db: AppDatabase) {
        let now = InsightRunner.nowMs()
        ranked = try? InsightQueries(db).ranked(forRide: id, nowMs: now)
        // the summary was seen: cards that come later (weather arrives) go to Recent insights only
        if !db.isReadOnly { try? InsightQueries(db).markShown(rideId: id, at: now) }
    }

    fileprivate func dismissInsight(_ i: Insight) {
        guard let id = activeId, let db = AppModel.shared.database else { return }
        try? InsightQueries(db).dismiss(id: i.id, at: InsightRunner.nowMs())
        refreshInsights(id, db)
    }

    @ViewBuilder fileprivate func insightCards(_ r: RankedInsights) -> some View {
        if let top = r.top {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb").foregroundStyle(.secondary).frame(width: 24)
                    Text(top.text).font(.subheadline)
                    Spacer(minLength: 0)
                    ThumbsRow(kind: "insight", subjectId: top.id, subjectText: top.text).fixedSize()
                    Button { dismissInsight(top) } label: { Image(systemName: "xmark").font(.caption).frame(minWidth: 44, minHeight: 44) }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
                if let more = r.moreText {
                    Button(showMore ? "Show less" : more) { showMore.toggle() }
                        .font(.footnote)
                    if showMore {
                        ForEach(Array(r.more.enumerated()), id: \.offset) { item in
                            Divider()
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "lightbulb").foregroundStyle(.secondary).frame(width: 24)
                                Text(item.element.text).font(.subheadline)
                                Spacer(minLength: 0)
                                ThumbsRow(kind: "insight", subjectId: item.element.id, subjectText: item.element.text).fixedSize()
                            }
                        }
                    }
                }
            }
            .padding(16)
            .glassCard(padding: 0)
        }
        ForEach(Array(r.progress.enumerated()), id: \.offset) { item in
            HStack(spacing: 6) {
                Image(systemName: "hourglass").font(.footnote)
                Text(item.element.text).font(.footnote)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }
}
