import Charts
import CorckieCore
import MapKit
import SwiftUI
import UIKit

/// Note 13: the ride graph, full screen (it replaces F-28's two separate charts). ONE chart; chips pick what it shows (Speed by default,
/// more one tap away), each line in its own colour and on its own scale (the highlighted chip's scale is on the axis). The small map
/// above is linked both ways: touch the map → the cursor jumps there (a touch on a hill selects the hill); touch the chart → the dot
/// moves on the map. Select marks a stretch on the chart; Scatter shows two lines against each other over it with a plain-words line on
/// how strong the link is. Note 13 scale fix (owner): an up-down pinch changes the VALUE SCALE of every shown line around its own
/// data (a speed-change line that looks flat on ±30 shows its detail on ±5). Hotfix 01 (H1): a sideways pinch zooms TIME (the window
/// narrows around the fingers; drag to pan while zoomed in, a tap moves the cursor); both coexist; double tap fits both.
/// The maths is Core `RideGraph` (unit tested).
struct RideGraphView: View {
    let data: RideLayerData

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [GraphSeries: GraphLine] = [:]
    @State private var available: [GraphSeries] = []
    @State private var chips: [GraphSeries] = GraphSeries.defaultChips
    @State private var highlighted: GraphSeries = .speed
    @State private var full: ClosedRange<Double> = 0...1
    @State private var domain: ClosedRange<Double> = 0...1
    /// Note 13 scale fix: 1 = auto-fit; above 1 the value ranges narrow around each line's data
    @State private var valueScale = 1.0
    @State private var scaleBase: Double?
    /// Hotfix 01 (H1): the pinch's axis and the window when it began; the drag's start when panning a zoomed-in window
    @State private var pinchAxis: RideGraph.PinchAxis?
    @State private var pinchStart: (domain: ClosedRange<Double>, anchor: CGFloat)?
    @State private var drag: (x: CGFloat, domain: ClosedRange<Double>, moved: Bool)?
    @State private var cursor: Double?
    @State private var selecting = false
    @State private var selectStart: Double?
    @State private var selection: GraphSelection?
    @State private var hills: [GraphSelection] = []
    @State private var showScatter = false
    @State private var ready = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            map.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            chipRow
            chart
            toolRow
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, 8)
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            setUp()
            OrientationLock.allow(landscape: true)
        }
        .onDisappear { OrientationLock.allow(landscape: false) }
        .sheet(isPresented: $showScatter) {
            ScatterSheet(lines: lines, chips: available, selection: selection, initialX: scatterX, initialY: scatterY)
                .glassPresentation(detents: [.medium, .large])
        }
        .screen("Ride graph")
    }

    private var scatterX: GraphSeries { chips.first { $0 != .speed } ?? (available.contains(.incline) ? .incline : available.first ?? .speed) }
    private var scatterY: GraphSeries { scatterX == .speed ? (available.first { $0 != .speed } ?? .speed) : .speed }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            GlassIconButton(symbol: "xmark", label: "Close") { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text(cursor.map { ChartCursor.clock($0) } ?? (selection?.name ?? "Ride graph")).font(.headline).monospacedDigit()
                Text(readout).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(2).minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    private var readout: String {
        guard let cursor else { return "Touch the chart or the map" }
        let parts = chips.compactMap { s in lines[s]?.value(at: cursor).map { s.text($0) } }
        return parts.isEmpty ? "No reading here" : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Map

    private var map: some View {
        let route = data.points.filter { $0.lat != nil && $0.lon != nil }.map { CLLocationCoordinate2D(latitude: $0.lat ?? 0, longitude: $0.lon ?? 0) }
        let selected = selection.map { RideGraph.path($0, points: data.points) } ?? []
        let dot = cursor.flatMap { RideGraph.position(at: $0, points: data.points) }
        return MapReader { proxy in
            Map(initialPosition: Self.fit(data.points), interactionModes: [.pan, .zoom]) {
                MapPolyline(coordinates: route).stroke(Color.gray.opacity(0.7), lineWidth: 4)
                if selected.count >= 2 {
                    MapPolyline(coordinates: selected.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(Theme.accent, lineWidth: 7)
                }
                if let dot {
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: dot.lat, longitude: dot.lon), anchor: .center) {
                        Circle().fill(Theme.accent).frame(width: 16, height: 16).overlay(Circle().stroke(Color.white, lineWidth: 3))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture { location in
                guard let c = proxy.convert(location, from: .local),
                      let t = RideGraph.time(near: GeoPoint(lat: c.latitude, lon: c.longitude), points: data.points) else { return }
                cursor = t
                if let hill = RideGraph.hill(at: t, hills: hills) { selection = hill }
                if !domain.contains(t) { domain = full }
                Haptics.tick()
            }
            .accessibilityLabel("Map of the ride; touch the route to move the cursor there")
        }
    }

    static func fit(_ points: [SeriesPoint]) -> MapCameraPosition {
        let pts = points.compactMap { p -> GeoPoint? in
            guard let lat = p.lat, let lon = p.lon else { return nil }
            return GeoPoint(lat: lat, lon: lon)
        }
        guard let r = MapFit.region(pts, padding: 0.12) else { return .automatic }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r.centerLat, longitude: r.centerLon),
                                          span: MKCoordinateSpan(latitudeDelta: r.latSpan, longitudeDelta: r.lonSpan)))
    }

    // MARK: Chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(available, id: \.self) { s in
                    let on = chips.contains(s)
                    Button { tap(s) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(colour(s)).frame(width: 8, height: 8)
                            Text(s.title).font(.subheadline.weight(on ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(on ? colour(s).opacity(0.18) : Theme.chip, in: Capsule())
                        .overlay(Capsule().strokeBorder(on && highlighted == s ? colour(s) : .clear, lineWidth: 2))
                        .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(s.title)
                    .accessibilityValue(on ? (highlighted == s ? "On, its scale is shown" : "On") : "Off")
                }
            }
        }
    }

    /// Off → on (and it gets the scale); on and highlighted → off; on → highlighted
    private func tap(_ s: GraphSeries) {
        if !chips.contains(s) {
            chips.append(s)
            highlighted = s
        } else if highlighted == s, chips.count > 1 {
            chips.removeAll { $0 == s }
            highlighted = chips.last ?? .speed
        } else {
            highlighted = s
        }
        Haptics.tick()
    }

    private func colour(_ s: GraphSeries) -> Color {
        guard let c = SpeedPalette.rgb(s.hex) else { return Theme.accent }
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: Chart

    private func scale(_ s: GraphSeries) -> ClosedRange<Double> {
        guard let line = lines[s] else { return 0...1 }
        return RideGraph.scaledRange(line, factor: valueScale, within: RideGraph.isZoomed(domain, full: full) ? domain : nil)
    }

    /// One drawn reading (flattened so the chart stays simple for the compiler)
    private struct Plot: Identifiable {
        let id: Int
        let name: String
        let minutes: Double
        let y: Double
        let colour: Color
        let width: CGFloat
    }

    private var plots: [Plot] {
        var out: [Plot] = []
        for s in chips {
            guard let line = lines[s] else { continue }
            let r = scale(s)
            let c = colour(s)
            let w: CGFloat = s == highlighted ? 2.5 : 1.6
            for p in RideGraph.visible(line, domain: domain) {
                out.append(Plot(id: out.count, name: s.title, minutes: p.t / 60, y: RideGraph.normalised(p.v, in: r), colour: c, width: w))
            }
        }
        return out
    }

    private var axisLabels: [String] {
        let hl = scale(highlighted)
        return [0.0, 0.5, 1.0].map { highlighted.text(hl.lowerBound + $0 * (hl.upperBound - hl.lowerBound)) }
    }

    private var xDomain: ClosedRange<Double> { (domain.lowerBound / 60)...(max(domain.upperBound, domain.lowerBound + 1) / 60) }

    @ChartContentBuilder private var lineMarks: some ChartContent {
        ForEach(plots) { p in
            LineMark(x: .value("Minutes", p.minutes), y: .value("Height", p.y), series: .value("Line", p.name))
                .foregroundStyle(p.colour)
                .lineStyle(StrokeStyle(lineWidth: p.width))
        }
    }

    @ChartContentBuilder private var marks: some ChartContent {
        if let sel = selection {
            RectangleMark(xStart: .value("From", sel.from / 60), xEnd: .value("To", sel.to / 60))
                .foregroundStyle(Theme.accent.opacity(0.12))
        }
        lineMarks
        if let cursor {
            RuleMark(x: .value("Cursor", cursor / 60)).foregroundStyle(Color.primary.opacity(0.6))
        }
    }

    private var chart: some View {
        let labels = axisLabels
        let tint = colour(highlighted)
        return Chart { marks }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...1)
        .chartPlotStyle { $0.clipped() }
        .chartXAxisLabel("min")
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { v in
                AxisGridLine()
                AxisValueLabel {
                    Text(labels[min(2, max(0, Int(((v.as(Double.self) ?? 0) * 2).rounded())))]).foregroundStyle(tint)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay {
            ChartGestures(
                onTouch: { x, width, phase in touched(x: x, width: width, phase: phase) },
                onPinch: { vertical, scale, anchor, phase in pinched(vertical: vertical, scale: scale, anchor: anchor, phase: phase) },
                onDoubleTap: reset)
        }
        .accessibilityLabel("Ride graph: " + chips.map(\.title).joined(separator: ", ") + " against minutes")
    }

    /// The plot sits right of the axis labels; the finger's x is mapped over the whole width (close enough at this size)
    private func touched(x: CGFloat, width: CGFloat, phase: ChartGestures.Phase) {
        let t = ChartCursor.time(atX: Double(x), width: Double(width), domain: domain)
        if selecting {
            switch phase {
            case .began: selectStart = t; selection = GraphSelection(from: t, to: t)
            case .changed: if let s = selectStart { selection = GraphSelection(from: s, to: t) }
            case .ended:
                selecting = false
                if let sel = selection, sel.to - sel.from < 5 { selection = nil }
                Haptics.tick()
            }
        } else if RideGraph.isZoomed(domain, full: full) {
            // H1: zoomed in, a drag pans the window; a touch without moving moves the cursor
            switch phase {
            case .began:
                if drag == nil { drag = (x, domain, false) }
            case .changed:
                guard let d = drag, width > 0 else { return }
                let dx = x - d.x
                if abs(dx) > 8 || d.moved {
                    drag?.moved = true
                    domain = RideGraph.timePanned(d.domain, full: full, fraction: Double(dx / width))
                }
            case .ended:
                guard let d = drag else { return }
                if !d.moved { cursor = ChartCursor.time(atX: Double(d.x), width: Double(width), domain: d.domain) }
                drag = nil
            }
        } else {
            cursor = t
        }
    }

    private func pinched(vertical: Bool, scale: CGFloat, anchor: CGFloat, phase: ChartGestures.Phase) {
        // H1: the axis is decided once, when the pinch begins: up-down = value scale (note 13 scale fix), sideways = time window
        if phase == .began || pinchAxis == nil {
            pinchAxis = vertical ? .value : .time
            scaleBase = valueScale
            pinchStart = (domain, anchor)
        }
        switch pinchAxis {
        case .value:
            valueScale = RideGraph.clampedScale((scaleBase ?? valueScale) * Double(scale))
        default:
            if let start = pinchStart {
                domain = RideGraph.timeZoomed(start.domain, full: full, scale: Double(scale), anchor: Double(start.anchor))
            }
        }
        if phase == .ended {
            scaleBase = nil
            pinchAxis = nil
            pinchStart = nil
        }
    }

    private func reset() {
        domain = full
        valueScale = 1   // back to auto-fit
        Haptics.tick()
    }

    // MARK: Tools

    private var toolRow: some View {
        HStack(spacing: 10) {
            Button { selecting.toggle(); if selecting { cursor = nil } } label: {
                Label(selecting ? "Drag over the chart" : "Select", systemImage: "selection.pin.in.out")
            }
            .buttonStyle(.bordered)
            if !hills.isEmpty {
                Menu {
                    ForEach(Array(hills.enumerated()), id: \.offset) { _, h in
                        Button(h.name ?? "Climb") { selection = h; domain = full; Haptics.tick() }
                    }
                } label: { Label("Hills", systemImage: "mountain.2") }
                .buttonStyle(.bordered)
            }
            if selection != nil {
                Button { showScatter = true } label: { Label("Scatter", systemImage: "chart.dots.scatter") }
                    .buttonStyle(.borderedProminent)
                Button { selection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Clear the selection")
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .overlay(alignment: .bottomTrailing) {
            Text("Pinch sideways: time \u{00B7} up-down: values \u{00B7} double tap fits").font(.caption2).foregroundStyle(.secondary).offset(y: 16)
        }
        .padding(.bottom, 14)
    }

    private func setUp() {
        guard !ready else { return }
        ready = true
        var all: [GraphSeries: GraphLine] = [:]
        for s in GraphSeries.allCases {
            let l = RideGraph.line(s, data)
            if !l.isEmpty { all[s] = l }
        }
        lines = all
        available = GraphSeries.allCases.filter { all[$0] != nil }
        chips = GraphSeries.defaultChips.filter { all[$0] != nil }
        if chips.isEmpty, let first = available.first { chips = [first] }
        highlighted = chips.first ?? .speed
        let end = data.points.map(\.t).max() ?? 1
        full = 0...max(1, end)
        domain = full
        hills = RideGraph.hills(data.points, energy: data.energy)
    }
}

/// Note 13: scatter of two lines over the selected stretch (or the whole ride) with the plain-words link
private struct ScatterSheet: View {
    let lines: [GraphSeries: GraphLine]
    let chips: [GraphSeries]
    let selection: GraphSelection?
    @State var x: GraphSeries
    @State var y: GraphSeries

    init(lines: [GraphSeries: GraphLine], chips: [GraphSeries], selection: GraphSelection?, initialX: GraphSeries, initialY: GraphSeries) {
        self.lines = lines
        self.chips = chips
        self.selection = selection
        _x = State(initialValue: initialX)
        _y = State(initialValue: initialY)
    }

    var body: some View {
        let pairs = lines[x].flatMap { lx in lines[y].map { RideGraph.pairs(x: lx, y: $0, in: selection) } } ?? []
        let r = RideGraph.correlation(pairs)
        VStack(alignment: .leading, spacing: 12) {
            Text(selection?.name ?? (selection == nil ? "Whole ride" : "Selected stretch")).font(.headline)
            HStack {
                Picker("Across", selection: $x) { ForEach(chips, id: \.self) { Text($0.title).tag($0) } }
                Text("against").foregroundStyle(.secondary)
                Picker("Up", selection: $y) { ForEach(chips, id: \.self) { Text($0.title).tag($0) } }
            }
            .pickerStyle(.menu)
            Chart {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, p in
                    PointMark(x: .value(x.title, p.x), y: .value(y.title, p.y)).symbolSize(18).foregroundStyle(Theme.accent.opacity(0.7))
                }
            }
            .chartXAxisLabel(x.unit)
            .chartYAxisLabel(y.unit)
            .chartXScale(domain: .automatic(includesZero: false))
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(minHeight: 200)
            Text(RideGraph.linkText(r, x: x, y: y)).font(.subheadline.weight(.semibold))
            Text("Each dot is one moment of the ride. A link is not always a cause.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// Note 13: the chart's touches in one UIKit view: one finger moves the cursor (or marks a stretch; hotfix 01: pans a zoomed-in window),
/// a pinch zooms time when the fingers are wider than tall and stretches the values when taller than wide (Core `RideGraph.pinchAxis`),
/// a double tap fits both.
struct ChartGestures: UIViewRepresentable {
    enum Phase { case began, changed, ended }
    var onTouch: (CGFloat, CGFloat, Phase) -> Void
    var onPinch: (Bool, CGFloat, CGFloat, Phase) -> Void
    var onDoubleTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0
        press.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        [pan, press, pinch, double].forEach { v.addGestureRecognizer($0) }
        pan.delegate = context.coordinator
        pinch.delegate = context.coordinator
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ChartGestures
        private var vertical = false

        init(_ parent: ChartGestures) { self.parent = parent }

        private func phase(_ s: UIGestureRecognizer.State) -> Phase? {
            switch s {
            case .began: return .began
            case .changed: return .changed
            case .ended, .cancelled, .failed: return .ended
            default: return nil
            }
        }

        @objc func press(_ g: UILongPressGestureRecognizer) {
            guard let view = g.view, g.numberOfTouches <= 1, let p = phase(g.state) else { return }
            parent.onTouch(g.location(in: view).x, view.bounds.width, p)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view, let p = phase(g.state) else { return }
            parent.onTouch(g.location(in: view).x, view.bounds.width, p)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view, let p = phase(g.state) else { return }
            if g.state == .began, g.numberOfTouches >= 2 {
                let a = g.location(ofTouch: 0, in: view), b = g.location(ofTouch: 1, in: view)
                vertical = RideGraph.pinchAxis(dx: Double(a.x - b.x), dy: Double(a.y - b.y)) == .value
            }
            let anchor = view.bounds.width > 0 ? g.location(in: view).x / view.bounds.width : 0.5
            parent.onPinch(vertical, g.scale, anchor, p)
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) { parent.onDoubleTap() }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
