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
    /// ui-shot only: a made-up route card
    var previewOffer: RouteOfferModel?
    /// ui-shot only: a made-up smart prompt (and the Loaded row)
    var previewPrompt: SmartPromptCard?
    /// ui-shot only: made-up insights (top card, N more, a progress line)
    var previewInsights: RankedInsights?
    /// ui-shot only: made-up layers, elevation and charts
    var previewSeries: RideSeries?
    /// ui-shot only: open the sheet at half with this map layer on
    var previewLayer: MapLayer?

    @State private var model: RideSummaryModel?
    /// F-39: the scooter-off stop between merged legs (nil = none)
    @State private var stopTrim: StopTrimState?
    @State private var offer: RouteOfferModel?
    @State private var missing = false
    @State private var prompt: SmartPromptCard?
    @State private var ranked: RankedInsights?
    @State private var moreOpen = false
    @State private var placeNames: (start: String, end: String)?
    @State private var loadLabel = "Not set"
    @State private var showKgField = false
    @State private var kgText = ""
    @State private var confirmDelete = false
    @State private var saveTap = 0
    @State private var errorText: String?
    // M5-01 / M5-02: compare, merge, trim
    @State private var switched: String?
    @State private var showCompare = false
    @State private var showMerge = false
    @State private var showTrim = false
    @State private var showReplay = false
    @State private var replayDownload = false
    /// F-28: the speed / battery charts full screen
    @State private var showCharts = false
    @State private var exportFile: ExportedFile?
    @State private var mergeInfo: MergeInfo?
    @State private var sameRideAnswered = false
    @State private var isTrimmed = false
    @State private var canUndoMerge = false
    @State private var toast: String?
    // M5-03: map layers, elevation, charts
    @State private var series: RideSeries?
    @State private var pins: [PlacePin] = []
    /// F-33: the layer row's view (Speed, or tap again for Steady …) and what it draws
    @State private var layerView: LayerView = .default
    @State private var drawn: [ValueStretch] = []
    @State private var drawnScale: LayerScale?
    @State private var stopDots: [StopDot] = []
    @State private var showHint = false
    /// Note 11: the card's height (full / default / one line / hidden with a lip)
    @State private var cardDetent: CardDetent = .standard
    /// A4: right after a ride the path draws itself (about 1 s) and the six tiles fade in one by one after it (60 ms apart).
    /// B53: 0 = drawing (a canvas over the map, `revealStart`), 1 = done (the real map line)
    @State private var pathReveal = 1.0
    @State private var revealStart: Date?
    /// B53, Reduce Motion: no draw, the map fades in
    @State private var mapShown = true
    @State private var tilesShown = 99
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// D9: "Home → Work" when both ends are saved places
    private var placesTitle: String? {
        if preview != nil {
            let pins = RideDetailPreview.pins
            return pins.count >= 2 ? "\(pins[0].name) \u{2192} \(pins[1].name)" : nil
        }
        return placeNames.map { "\($0.start) \u{2192} \($0.end)" }
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
            } else if let skeleton = RideDetailPreview.model("ride-nogps") {
                // A8: the final layout as grey shapes (made-up numbers, redacted), then it cross-fades into the ride; no spinner
                content(skeleton).redacted(reason: .placeholder).allowsHitTesting(false).accessibilityHidden(true).transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model == nil)
        .toolbar(.hidden, for: .navigationBar)
        .stiffBounce()
        .onAppear {
            if let l = previewLayer { layerView = LayerView(l) }
            if previewSeries != nil { paintLayer() }
            if previewSeries != nil { moreOpen = true }
            if onDone != nil, preview == nil, !reduceMotion, model == nil {
                pathReveal = 0
                tilesShown = 0
            }
            if onDone != nil, preview == nil, reduceMotion, model == nil { mapShown = false }
        }
        .onChange(of: model == nil) { _, isNil in
            if !isNil { playSummaryReveal() }
        }
        .onChange(of: layerView) { _, _ in paintLayer() }
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
            if let id = activeId { CompareSheet(rideId: id).glassPresentation() }
        }
        .sheet(isPresented: $showMerge) {
            if let id = activeId, let info = mergeInfo {
                MergeSheet(rideId: id, previousId: info.previousId, offer: info.offer, onMerged: { kept in
                    switched = kept
                    toast = "Rides merged into one."
                    load()
                })
                .glassPresentation()
            }
        }
        .sheet(isPresented: $showTrim) {
            if let id = activeId { TrimSheet(rideId: id, onChanged: { toast = "Trim saved."; load() }).glassPresentation() }
        }
        .fullScreenCover(isPresented: $showReplay) {
            if let id = activeId { ReplayView(rideId: id, startDownload: replayDownload) }
        }
        .fullScreenCover(isPresented: $showCharts) {
            if let s = previewSeries ?? series { RideChartsFullScreen(points: s.points) }
        }
        .sheet(item: $exportFile) { file in ShareSheet(url: file.url) }
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
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    /// Note 11: the map fills the screen, the card is dragged like Apple Maps (B52: the default height keeps ~55 % for the map)
    private func content(_ m: RideSummaryModel) -> some View {
        RideCardScreen(detent: $cardDetent) {
            mapLayer(m)
        } topBar: {
            topBar(m)
        } side: {
            if !m.noGps, let s = previewSeries ?? series {
                VStack(alignment: .trailing, spacing: 6) {
                    LayerRow(layers: LayerViews.available(s.layerData), view: $layerView)
                    if showHint {
                        Text(LayerViews.hintText).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .glassCard(radius: 8, padding: 0, thin: true)
                    }
                    if let scale = drawnScale {
                        LayerLegend(scale: scale, emptyText: drawn.isEmpty ? LayerViews.emptyText(layerView) : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } line: {
            Text(RideCardLayout.line(time: stat(m, "Time"), distance: stat(m, "Distance"), topSpeed: stat(m, "Top speed")))
                .font(.headline).fontDesign(.rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        } content: {
            sheetContent(m)
        }
    }

    private func topBar(_ m: RideSummaryModel) -> some View {
        // D9: the title is "from → to"; the date moves to the subtitle
        let places = placesTitle
        let title = places ?? m.title
        let subtitle = [places == nil ? nil : m.title, m.subtitle.isEmpty ? nil : m.subtitle].compactMap { $0 }.joined(separator: " \u{00B7} ")
        return GlassTopBar(title: title, subtitle: subtitle) {
            GlassIconButton(symbol: onDone != nil ? "xmark" : "chevron.left", label: onDone != nil ? "Done" : "Back") {
                if let onDone { onDone() } else { dismiss() }
            }
        } trailing: {
            Menu { moreItems } label: { GlassIcon(symbol: "ellipsis") }
                .accessibilityLabel("More")
        }
    }

    /// D10: one menu, short labels; the exports sit in a submenu
    @ViewBuilder private var moreItems: some View {
        let needsGps = (preview ?? model)?.noGps == true
        if preview == nil, activeId != nil {
            Button { showCompare = true } label: { Label("Compare", systemImage: "arrow.left.arrow.right") }
            if mergeInfo != nil {
                Button { showMerge = true } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
            }
            Button { showTrim = true } label: { Label(isTrimmed ? "Trim again" : "Trim", systemImage: "scissors") }
            if canUndoMerge {
                Button { undoMerge() } label: { Label("Undo merge", systemImage: "arrow.uturn.backward") }
            }
        }
        Button { replayDownload = false; showReplay = true } label: { Label("Replay", systemImage: "play.circle") }
            .disabled(needsGps)
        Menu {
            Button { replayDownload = true; showReplay = true } label: { Label("Replay file", systemImage: "square.and.arrow.down") }
                .disabled(needsGps)
            Button { exportRide(.csv) } label: { Label("CSV", systemImage: "tablecells") }
            Button { exportRide(.gpx) } label: { Label("GPX", systemImage: "map") }
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder private func mapLayer(_ m: RideSummaryModel) -> some View {
        if m.noGps {
            ZStack {
                MapBackdrop(map: true)
                VStack { noGpsCard.padding(.horizontal, 40).padding(.top, 96); Spacer() }
            }
        } else {
            mapView(m.path)
        }
    }

    private func stat(_ m: RideSummaryModel, _ label: String) -> String {
        (m.mainStats + m.scooterStats).first { $0.label == label }?.value ?? "\u{2013}"
    }

    /// D1: the climb tile shows only the way up ("+38 m") from "~+38 m / −35 m"
    private func climbText(_ m: RideSummaryModel) -> String {
        let v = stat(m, "Elevation")
        guard let first = v.components(separatedBy: " / ").first, first.contains("+") else { return "\u{2013}" }
        return first.replacingOccurrences(of: "~", with: "")
    }

    /// A4: the path draws itself, then a soft tap and the tiles fade in one by one.
    /// B53: the drawing runs on the display's timeline (RouteRevealView), not 30 steps of re-added map lines.
    private func playSummaryReveal() {
        if !mapShown { withAnimation(.easeIn(duration: 0.35)) { mapShown = true } }
        guard onDone != nil, preview == nil, !reduceMotion, pathReveal < 1 else { return }
        Task { @MainActor in
            if !drawn.isEmpty {
                revealStart = Date()
                try? await Task.sleep(nanoseconds: UInt64(RouteReveal.durationS * 1_000_000_000))
            }
            pathReveal = 1
            revealStart = nil
            Haptics.soft()
            for n in 1...6 {
                withAnimation(.easeOut(duration: 0.25)) { tilesShown = n }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            tilesShown = 99
        }
    }

    /// D1: six key tiles
    private func keyTiles(_ m: RideSummaryModel) -> some View {
        StatTileGrid {
            StatTile(value: stat(m, "Time"), label: "Time").opacity(tilesShown >= 1 ? 1 : 0)
            StatTile(value: stat(m, "Distance"), label: "Distance").opacity(tilesShown >= 2 ? 1 : 0)
            StatTile(value: stat(m, "Avg. speed"), label: "Avg").opacity(tilesShown >= 3 ? 1 : 0)
            StatTile(value: stat(m, "Battery"), label: "Battery").opacity(tilesShown >= 4 ? 1 : 0)
            StatTile(value: stat(m, "Top speed"), label: "Top").opacity(tilesShown >= 5 ? 1 : 0)
            StatTile(value: climbText(m), label: "Climb").opacity(tilesShown >= 6 ? 1 : 0)
        }
    }

    private func sheetContent(_ m: RideSummaryModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if onDone != nil, !sameRideAnswered, let info = mergeInfo { sameRideCard(info) }
            keyTiles(m)
            if let hot = m.hotPeakC { HStack { InfoChip("thermometer.high", "\(hot) \u{00B0}C", label: "Temperature"); Spacer(minLength: 0) } }
            if let r = previewInsights ?? ranked { insightCards(r) }
            ForEach(Array(m.notes.enumerated()), id: \.offset) { _, n in
                if n.kind != .heat { note(n) }
            }
            if let s = stopTrim { stopTrimRow(s) }
            if previewPrompt == nil, prompt == nil, let o = previewOffer ?? offer { offerCard(o) }
            if let p = previewPrompt ?? prompt { promptCard(p) }
            moreSection(m)
        }
        .padding(.top, 2)
    }

    /// F-39 flaw 7: a merged trip with a scooter-off stop between its legs: one line, tap = trim the stop out of Time, undoable
    private func stopTrimRow(_ s: StopTrimState) -> some View {
        HStack(spacing: 10) {
            if s.trimmed {
                Text("Stop trimmed from Time").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Undo") { setStopTrim(false) }.font(.footnote.weight(.semibold))
            } else if let line = TripRules.stopTrimLine(stopS: s.stopS) {
                Button(line) { setStopTrim(true) }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accentInk)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setStopTrim(_ on: Bool) {
        guard preview == nil, let id = activeId, let db = AppModel.shared.database else { return }
        do {
            try RideToolsService.trimStops(db, rideId: id, on: on)
            Haptics.tick()
            load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// P-4: "Same ride?" is asked here, on the summary, and never during the ride. Yes opens the Merge sheet (it can be undone).
    private func sameRideCard(_ info: MergeInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Same ride as the one before?").font(.headline)
            Text(info.offer.text).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Yes, join them") { showMerge = true }.buttonStyle(.borderedProminent)
                Button("No") { sameRideAnswered = true }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func detailRows(_ m: RideSummaryModel) -> [(String, String)] {
        var rows = [("Moving time", stat(m, "Moving time")), ("Energy", stat(m, "Energy")), ("Stops", stat(m, "Stops")),
                    ("Battery per km", stat(m, "Battery per km"))]
        if m.hotPeakC == nil, stat(m, "Temperature") != "\u{2013}" { rows.append(("Temperature", stat(m, "Temperature"))) }
        if let full = m.scooterStats.first(where: { $0.label == "To full" }) { rows.append(("To full", full.value)) }
        return rows
    }

    private func rowsCard(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Divider() }
                HStack {
                    Text(r.0)
                    Spacer()
                    Text(r.1).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 16)
        .glassCard(padding: 0)
    }

    private var fieldKitRows: some View {
        VStack(spacing: 12) {
            if let id = activeId, preview == nil {
                VStack(spacing: 0) {
                    ThumbsRow(kind: "start", subjectId: id, label: "Right? Start")
                    ThumbsRow(kind: "end", subjectId: id, label: "Right? End")
                    ThumbsRow(kind: "distance", subjectId: id, label: "Right? Distance")
                }
                .padding(.horizontal, 16)
                .glassCard(padding: 0)
            }
            if (activeId != nil && preview == nil) || previewPrompt != nil { loadedRow }
            if let id = activeId, preview == nil { RideNoteCard(rideId: id) }
        }
    }

    /// D1-D3: everything that is not a key tile sits under one "More"
    private func moreSection(_ m: RideSummaryModel) -> some View {
        DisclosureGroup("More", isExpanded: $moreOpen) {
            VStack(alignment: .leading, spacing: 12) {
                rowsCard(detailRows(m))
                if let s = previewSeries ?? series { RideSeriesPanels(series: s, onExpand: { showCharts = true }) }
                fieldKitRows
                ForEach(m.infoLines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .padding(.horizontal, 4)
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

    /// D7: "Save as route?" and two buttons, no explanation
    private func offerCard(_ o: RouteOfferModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.tint).frame(width: 24)
                Text(o.saved ? o.headline : "Save as route?").font(.headline)
            }
            if !o.saved {
                HStack(spacing: 12) {
                    Button("Save route") { saveTap += 1; routeAction(o.routeId, save: true) }.buttonStyle(.borderedProminent)
                        .sensoryFeedback(.success, trigger: saveTap)
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
            Text("No GPS").font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(padding: 0)
    }

    private func mapView(_ path: RidePathModel) -> some View {
        let fullGradient = drawn   // F-04 / F-33: continuous gradient of the chosen view when the readings are there
        let gradient = pathReveal >= 1 ? fullGradient : []   // B53: while drawing, the canvas shows the route
        let ramp = drawnScale?.ramp ?? LayerRamps.speed(colourBlind: DisplaySettings.colourBlind)
        return MapReader { proxy in
        Map(initialPosition: Self.fitted(path), interactionModes: [.pan, .zoom]) {
            GradientPath.lines(gradient, ramp: ramp)
            PlacePinMarks(pins: preview != nil ? RideDetailPreview.pins : pins)
            ForEach(Array((layerView.showsStops && pathReveal >= 1 ? stopDots : []).enumerated()), id: \.offset) { _, stop in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: stop.point.lat, longitude: stop.point.lon), anchor: .center) {
                    StopDotMark(stop: stop)
                }
            }
            // no series (or no fixes for it): the stored speed path, on the Speed view only
            ForEach(Array((layerView == .default && fullGradient.isEmpty ? path.segments : []).enumerated()), id: \.offset) { _, seg in
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
        .overlay {
            if pathReveal < 1, let start = revealStart {
                RouteRevealView(stretches: fullGradient, ramp: ramp, start: start, proxy: proxy)
            }
        }
        .opacity(mapShown ? 1 : 0)
        .accessibilityLabel("Map of the ride. \(layerLegend(path))")
        }
    }

    private func layerLegend(_ path: RidePathModel) -> String {
        if layerView == .default { return Self.legend(path) }
        if drawn.isEmpty { return LayerViews.emptyText(layerView) }
        return drawnScale.map { "\($0.title), \($0.low) to \($0.high)" } ?? layerView.title
    }

    /// F-33: the chosen view's stretches and legend (made once per tap, not per frame)
    private func paintLayer() {
        guard let s = previewSeries ?? series else { drawn = []; drawnScale = nil; return }
        let data = s.layerData
        if !LayerViews.available(data).contains(layerView.layer) { layerView = .default }
        drawn = LayerViews.stretches(layerView, data)
        drawnScale = LayerViews.scale(layerView, stretches: drawn, energy: s.energy, colourBlind: DisplaySettings.colourBlind)
        if stopDots.isEmpty { stopDots = LayerViews.stops(s.points) }
    }

    /// F-33: "Tap layer for deeper view" the first few times a ride with layers is opened
    private func countHint() {
        let key = "corckie.f33.hintShown"
        let shown = UserDefaults.standard.integer(forKey: key)
        showHint = LayerViews.showsHint(timesShown: shown)
        if showHint { UserDefaults.standard.set(shown + 1, forKey: key) }
    }

    /// B39: framed on the path itself (a stray GPS fix far away is ignored), padded, with room for the floating top bar
    static func fitted(_ path: RidePathModel) -> MapCameraPosition {
        var points: [GeoPoint] = []
        for seg in path.segments { for c in seg.coords { points.append(GeoPoint(lat: c.lat, lon: c.lon)) } }
        for run in path.walks { for c in run { points.append(GeoPoint(lat: c.lat, lon: c.lon)) } }
        // Note 11: the map fills the screen: the top bar, layer row and legend cover its top, the card (default height) its lower ~45 %
        guard let r = MapFit.region(points, padding: 0.12, topCover: 0.24, sideCover: 0.05, bottomCover: 0.42) else { return position(path) }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r.centerLat, longitude: r.centerLon),
                                          span: MKCoordinateSpan(latitudeDelta: r.latSpan, longitudeDelta: r.lonSpan)))
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
        stopDots = []
        paintLayer()
        if series != nil, !showHint { countHint() }
        pins = PlaceMapLoader.pins(rideId: id, database: db)
        placeNames = Self.names(db, rideId: id)
        refreshTools(id, db)
        stopTrim = RideToolsService.stopTrimState(db, rideId: id)        // F-39
        offer = RouteService.offer(rideId: id, database: db)
        refreshSmart(id, db)
        refreshInsights(id, db)
    }

    private func delete() {
        guard preview == nil, let id = activeId, let db = AppModel.shared.database else { return }
        do {
            try RideQueries(db).delete(rideId: id)
            Haptics.warning()
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
        var input = RideDetailInput(
            startAt: r.startAt, utcOffsetMin: r.utcOffsetMin, kind: r.kind, status: r.status, endReason: r.endReason,
            distanceM: r.distanceM, totalS: r.totalS, movingS: r.movingS, avgMovingMps: r.avgMovingMps,
            topSpeedMps: r.topSpeedMps, stops: r.stops, energyWhRaw: r.energyWhRaw,
            usedPct: CalibrationUpdater.shownUsed(db, rideId: id, usedPct: r.usedPct),
            startRestPct: r.startRestPct, endRestPct: r.endRestPct, odoStartKm: r.odoStartKm, odoEndKm: r.odoEndKm,
            elevGainM: r.elevGainM, elevLossM: r.elevLossM, tempPeakC: r.tempPeakC, tempRiseC: r.tempRiseC,
            ignoredReadings: r.ignoredReadings, hasGps: r.hasGps, isSimulated: r.isSimulated)
        // B57: "Recorded by phone" and the format watch's reason are kept beside the row
        let extras = RideExtras.parse(try? q.setting(key: RideExtras.key(rideId: id)))
        input.recordedByPhone = extras.recordedByPhone
        input.formatReason = extras.formatReason
        // Note 10: rides closed since note 10 carry their lines (an empty list = nothing visible changed: no note)
        if extras.ignored != nil { input.ignoredNotes = extras.ignoredNotes ?? [] }
        input.ignoredInfo = extras.ignored?.infoLine
        let gaps = ((try? q.gaps(rideId: id)) ?? []).map { RideGapSpan(kind: $0.kind, startT: $0.startT, endT: $0.endT) }
        let points = ((try? q.samples(rideId: id)) ?? []).map { (s: RideSampleRecord) -> RidePoint in
            RidePoint(t: s.t, lat: s.lat, lon: s.lon, hAccM: s.hAccM, speedKmh: s.speedMps.map { v in v * 3.6 },
                      gpsSpeedKmh: s.gpsSpeedMps.map { v in v * 3.6 }, batteryPct: s.batteryPct, mode: s.mode)
        }
        var model = RideSummaryBuilder.build(input, gaps: gaps, points: points)
        // M4-02 (check mf1): the ride's factor columns as one line under More
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
        for i in 0..<60 {
            let x = Double(i)
            let lat: Double = 40.0 + x * 0.000_18
            let lon: Double = -75.0 + x * 0.000_22 + 0.0006 * sin(x / 6)
            let speed: Double = 12 + 22 * abs(sin(x / 9))
            let alt: Double = i < 20 ? 20 : (i < 40 ? 20 + Double(i - 20) * 1.6 : 52 - Double(i - 40) * 1.2)
            points.append(SeriesPoint(t: x * 5, lat: lat, lon: lon, hAccM: 6, speedKmh: speed, batteryPct: 81 - i / 10, altM: alt))
        }
        var series = RideSeries()
        series.points = points
        series.hasAltitude = true
        series.hills = RideLayers.hills(points)
        series.speedValues = RideLayers.smoothedStretches(RideLayers.speedStretches(points))
        series.hillValues = RideLayers.smoothedStretches(RideLayers.hillStretches(points))
        let elevation = RideLayers.elevation(points)
        series.profile = elevation.profile
        series.climbs = elevation.climbs
        series.chart = RideLayers.chartSeries(points)
        let start: Int64 = 1_790_000_000_000
        let hour = (start / 3_600_000) * 3_600_000
        let rows = [WeatherRow(cellKey: "preview", hourAt: hour, source: "preview", kind: .history, windKmh: 22, windFromDeg: 250, fetchedAt: 0),
                    WeatherRow(cellKey: "preview", hourAt: hour + 3_600_000, source: "preview", kind: .history, windKmh: 22, windFromDeg: 250, fetchedAt: 0)]
        series.wind = RideLayers.wind(points, rideStartMs: start, rows: rows)
        series.windValues = RideLayers.windStretches(points, rideStartMs: start, rows: rows).map { RideLayers.smoothedStretches($0) }
        series.weather = rows
        series.rideStartMs = start
        series.energy = EnergyTrack.build(points)
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

    /// D6: "+4% battery. Why?" and four chips (Load, Tyres, Riding, Skip)
    fileprivate func promptCard(_ p: SmartPromptCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble").foregroundStyle(.secondary).frame(width: 24)
                Text("+\(Int(p.extraPct.rounded()))% battery. Why?").font(.headline)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Light") { answer(.light) }
                    Button("Heavy") { answer(.heavy) }
                } label: { promptChip("Load") }
                Button { answer(.tyresSoft) } label: { promptChip("Tyres") }
                Button { answer(.rodeDifferently) } label: { promptChip("Riding") }
                Button { dismissPrompt() } label: { promptChip("Skip") }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(padding: 0)
    }

    private func promptChip(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Theme.chip, in: Capsule())
            .contentShape(Capsule())
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

    /// D5: one short line with an icon and the thumbs; no "more", no progress lines
    @ViewBuilder fileprivate func insightCards(_ r: RankedInsights) -> some View {
        if let top = r.top {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lightbulb").foregroundStyle(.secondary).frame(width: 24)
                Text(top.text).font(.subheadline).lineLimit(2)
                Spacer(minLength: 0)
                ThumbsRow(kind: "insight", subjectId: top.id, subjectText: top.text).fixedSize()
            }
            .padding(16)
            .glassCard(padding: 0)
        }
    }
}

extension RideDetailPreview {
    /// F-06: made-up start / end places on the preview path (first and last point of `model`)
    static let pins: [PlacePin] = [
        PlacePin(id: "p1", name: "Home", lat: 40.0, lon: -75.0, colourId: "green"),
        PlacePin(id: "p2", name: "Work", lat: 40.0106, lon: -74.9870, colourId: "blue")
    ]
}

extension RideDetailView {
    /// D9: the names of the saved places the ride started and ended at (both needed)
    fileprivate static func names(_ db: AppDatabase, rideId: String) -> (start: String, end: String)? {
        let q = RouteQueries(db)
        guard let link = try? q.link(rideId: rideId), let s = link.startPlaceId, let e = link.endPlaceId,
              let a = (try? q.place(id: s))?.name, let b = (try? q.place(id: e))?.name, !a.isEmpty, !b.isEmpty else { return nil }
        return (a, b)
    }
}
