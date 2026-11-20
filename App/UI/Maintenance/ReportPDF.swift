import CorckieCore
import UIKit

/// N10-14 / N10-15 (batch 10): a small PDF writer made on the phone. One font (Arial 400 / 700), A4, print-safe greys, labelled
/// key–value rows and numbered sections. Hebrew pages run right-to-left; numbers and units stay left-to-right.
final class PDFWriter {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 in points
    static let margin: CGFloat = 44

    let lang: ReportLanguage
    private let ctx: UIGraphicsPDFRendererContext
    private(set) var y: CGFloat = margin
    private var pageNo = 1
    private let footer: String

    init(lang: ReportLanguage, ctx: UIGraphicsPDFRendererContext, footer: String) {
        self.lang = lang
        self.ctx = ctx
        self.footer = footer
        ctx.beginPage()
        drawFooter()
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "Arial-BoldMT" : "ArialMT", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private var width: CGFloat { Self.page.width - 2 * Self.margin }

    private func attrs(_ size: CGFloat, bold: Bool, grey: CGFloat = 0, align: NSTextAlignment? = nil) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = align ?? (lang.rightToLeft ? .right : .left)
        p.baseWritingDirection = lang.rightToLeft ? .rightToLeft : .leftToRight
        p.lineBreakMode = .byWordWrapping
        return [.font: Self.font(size, bold: bold), .foregroundColor: UIColor(white: grey, alpha: 1), .paragraphStyle: p]
    }

    private func ensure(_ h: CGFloat) {
        if y + h > Self.page.height - Self.margin - 24 {
            ctx.beginPage()
            pageNo += 1
            y = Self.margin
            drawFooter()
        }
    }

    private func drawFooter() {
        let s = NSAttributedString(string: "\(footer) \u{00B7} \(ReportText.t(.page, lang)) \(pageNo)", attributes: attrs(8, bold: false, grey: 0.4, align: .center))
        s.draw(in: CGRect(x: Self.margin, y: Self.page.height - Self.margin + 8, width: width, height: 14))
    }

    /// A block of text; returns nothing, moves down
    func text(_ s: String, size: CGFloat = 10, bold: Bool = false, grey: CGFloat = 0, gap: CGFloat = 6) {
        let a = NSAttributedString(string: s, attributes: attrs(size, bold: bold, grey: grey))
        let h = ceil(a.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height)
        ensure(h)
        a.draw(with: CGRect(x: Self.margin, y: y, width: width, height: h), options: [.usesLineFragmentOrigin], context: nil)
        y += h + gap
    }

    /// A numbered section heading with a thin rule
    func section(_ n: Int, _ title: String) {
        ensure(40)
        y += 6
        text("\(n)  \(title)", size: 12, bold: true, gap: 3)
        let line = UIBezierPath()
        line.move(to: CGPoint(x: Self.margin, y: y))
        line.addLine(to: CGPoint(x: Self.margin + width, y: y))
        UIColor(white: 0.6, alpha: 1).setStroke()
        line.lineWidth = 0.5
        line.stroke()
        y += 8
    }

    /// Labelled key–value rows (label column 38 %)
    func rows(_ pairs: [(String, String)]) {
        for (k, v) in pairs {
            let ka = NSAttributedString(string: k, attributes: attrs(9.5, bold: true, grey: 0.25))
            let va = NSAttributedString(string: v, attributes: attrs(9.5, bold: false))
            let kw = width * 0.38, vw = width - kw - 8
            let h = max(ceil(ka.boundingRect(with: CGSize(width: kw, height: 999), options: .usesLineFragmentOrigin, context: nil).height),
                        ceil(va.boundingRect(with: CGSize(width: vw, height: 999), options: .usesLineFragmentOrigin, context: nil).height))
            ensure(h + 4)
            let kx = lang.rightToLeft ? Self.margin + width - kw : Self.margin
            let vx = lang.rightToLeft ? Self.margin : Self.margin + kw + 8
            ka.draw(with: CGRect(x: kx, y: y, width: kw, height: h), options: .usesLineFragmentOrigin, context: nil)
            va.draw(with: CGRect(x: vx, y: y, width: vw, height: h), options: .usesLineFragmentOrigin, context: nil)
            y += h + 4
        }
        y += 4
    }

    /// A table: header row in bold on a light grey band, then rows; columns as fractions of the width
    func table(_ header: [String], _ rows: [[String]], widths: [CGFloat]) {
        func drawRow(_ cells: [String], bold: Bool, band: Bool) {
            let atts = cells.map { NSAttributedString(string: $0, attributes: attrs(9, bold: bold)) }
            var h: CGFloat = 0
            for (i, a) in atts.enumerated() {
                h = max(h, ceil(a.boundingRect(with: CGSize(width: width * widths[i] - 6, height: 999), options: .usesLineFragmentOrigin, context: nil).height))
            }
            ensure(h + 6)
            if band {
                UIColor(white: 0.92, alpha: 1).setFill()
                UIRectFill(CGRect(x: Self.margin, y: y - 2, width: width, height: h + 4))
            }
            var x: CGFloat = lang.rightToLeft ? Self.margin + width : Self.margin
            for (i, a) in atts.enumerated() {
                let w = width * widths[i]
                if lang.rightToLeft { x -= w }
                a.draw(with: CGRect(x: x + 3, y: y, width: w - 6, height: h), options: .usesLineFragmentOrigin, context: nil)
                if !lang.rightToLeft { x += w }
            }
            y += h + 6
        }
        drawRow(header, bold: true, band: true)
        for r in rows { drawRow(r, bold: false, band: false) }
        y += 4
    }

    /// Writes a PDF to a temporary file named `name`
    static func make(name: String, lang: ReportLanguage, footer: String, draw: (PDFWriter) -> Void) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let meta: [String: Any] = [kCGPDFContextCreator as String: "CorckieApp", kCGPDFContextTitle as String: name]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = meta
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        do {
            try renderer.writePDF(to: url) { ctx in draw(PDFWriter(lang: lang, ctx: ctx, footer: footer)) }
            return url
        } catch {
            Log.info(source: "maintenance", "PDF failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// N10-14: the maintenance history as a PDF service book (for the rider and a buyer)
enum HistoryPDF {
    static func make(_ db: AppDatabase, language lang: ReportLanguage) -> URL? {
        let id = MaintenanceService.scooterId(db)
        let logged = MaintenanceService.logged(db)
        let faults = FaultStore.records(db)
        let since = HistoryDates.trackedSince(db)
        let entries = MaintHistory.entries(logged: logged, faults: faults, scooterId: id, trackedSince: since)
        let c = MaintHistory.counts(entries)
        let decay = BatteryDecayService.report(db)
        let name = ScooterRecord.latest(in: db)?.name ?? "Scooter"
        let odo = (try? MaintenanceQueries(db).odometerKm()) ?? nil
        let today = FaultGate.day(epochMs: Int64(Date().timeIntervalSince1970 * 1000))
        func d(_ day: Int) -> String { HistoryDates.date(day).formatted(.dateTime.day().month(.abbreviated).year()) }
        let t = { (k: ReportText.Key) in ReportText.t(k, lang) }
        return PDFWriter.make(name: lang == .hebrew ? "CorckieApp_Maintenance_History_HE.pdf" : "CorckieApp_Maintenance_History.pdf",
                              lang: lang, footer: "CorckieApp \u{00B7} " + t(.historyTitle)) { w in
            w.text(t(.historyTitle), size: 20, bold: true, gap: 4)
            if let h = decay.healthPct {
                let km = decay.nowKm.map { " \u{00B7} \(Int($0.rounded())) km " + t(.onFullCharge) } ?? ""
                w.text(t(.batteryHealth) + " \(Int(h.rounded()))%" + km, size: 12, bold: true, gap: 10)
            }
            w.section(1, t(.scooter))
            w.rows([(t(.scooter), name),
                    (t(.odometer), odo.map { "\(Int($0.rounded())) km" } ?? "-"),
                    (t(.trackedSince), since.map { d($0.day) } ?? "-"),
                    (t(.reportDate), d(today))])
            w.section(2, "\(c.logged) \(t(.logged)) \u{00B7} \(c.found) \(t(.found)) \u{00B7} \(c.dealtWith) \(t(.dealtWith)) \u{00B7} \(c.open) \(t(.open))")
            let rows = entries.map { e -> [String] in
                [d(e.day), e.odoKm.map { "\(Int($0.rounded()))" } ?? "-",
                 ReportText.entryTitle(e, logged: logged, faults: faults, lang),
                 e.source == .measured ? t(.measured) : t(.entered),
                 e.outcome.map { ReportText.outcome($0, lang) } ?? ""]
            }
            w.table([t(.date), t(.km), t(.what), t(.source), t(.outcome)], rows, widths: [0.16, 0.10, 0.44, 0.13, 0.17])
            w.text(t(.transparency), size: 8.5, grey: 0.35, gap: 4)
        }
    }
}

/// N10-15 (batch 10): the report for a mechanic, ONE issue (spec reports/maintenance/mechanic-report.md, samples _SAMPLE*.pdf).
/// Page 1 at a glance: the scooter, the issue as facts, what to do first; then occurrences, your normal vs now, history, what the
/// app can't see, raw data, and a workshop result line. Leads / first checks for the workshop are left out until a mechanic has
/// checked the per-fault table (owner 20 Nov). A CSV of every reading around each occurrence goes with it. No map, places,
/// routes, clock times or name.
enum MechanicReport {
    /// The PDF and the CSV, ready to share
    static func make(_ db: AppDatabase, record r: FaultRecord, language lang: ReportLanguage) -> [URL] {
        let occ = (FaultStore.load(db, FaultStore.occurrencesKey, as: [FaultOccurrence].self) ?? [])
            .filter { $0.kind == r.kind && $0.scooterId == r.scooterId }
        let scooter = ScooterRecord.latest(in: db)
        let odo = (try? MaintenanceQueries(db).odometerKm()) ?? nil
        let book = FaultStore.load(db, FaultStore.bookKey, as: FaultBook.self) ?? FaultBook()
        let others = FaultRecord.open(FaultStore.records(db), scooterId: r.scooterId).filter { $0.id != r.id }
        let logged = MaintenanceService.logged(db).filter { $0.scooterId == r.scooterId }.suffix(8)
        let today = FaultGate.day(epochMs: Int64(Date().timeIntervalSince1970 * 1000))
        let m = { (k: MechanicText.Key) in MechanicText.t(k, lang) }
        func d(_ day: Int) -> String { HistoryDates.date(day).formatted(.dateTime.day().month(.abbreviated).year()) }
        func n(_ x: Double?, _ digits: Int = 0) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "-" }
        let unit = MechanicText.unit(r.kind)
        let values = occ.map(\.value)
        let trend = MechanicText.trend(values, higherIsWorse: r.kind.higherIsWorse)
        let base = book.baselines.filter { $0.key.hasPrefix(FaultBook.key(r.scooterId, r.kind)) }.values.max { $0.samples.count < $1.samples.count }
        let suffix = lang == .hebrew ? "_HE" : ""
        let title = ReportText.faultTitle(r.kind, lang)

        let pdf = PDFWriter.make(name: "CorckieApp_Mechanic_Report\(suffix).pdf", lang: lang,
                                 footer: "CorckieApp \u{00B7} " + ReportText.t(.mechanicTitle, lang)) { w in
            w.text(ReportText.t(.mechanicTitle, lang), size: 11, grey: 0.35, gap: 2)
            w.text(title, size: 20, bold: true, gap: 4)
            w.text(ReportText.t(.notADiagnosis, lang), size: 9, grey: 0.35, gap: 10)
            w.section(1, m(.theScooter))
            w.rows([(m(.model), scooter?.name ?? "-"), (m(.firmware), scooter?.firmware ?? "-"),
                    (ReportText.t(.odometer, lang), odo.map { "\(Int($0.rounded())) km" } ?? "-"),
                    (m(.reportDate), d(today)), (m(.appVersion), AppInfo.build)])
            w.section(2, m(.theIssue))
            let trendText = trend > 0 ? m(.worse) : trend < 0 ? m(.better) : m(.steady)
            w.rows([(m(.found), MechanicText.found(r.kind, lang)),
                    (m(.confirmedOn), "\(max(occ.count, 1)) \(m(.times))"),
                    (m(.firstSeen), d(occ.map(\.day).min() ?? r.day)),
                    (m(.lastSeen), d(occ.map(\.day).max() ?? r.day)),
                    (m(.trend), values.count >= 3 ? trendText : "-"),
                    (m(.whatToDo), MechanicText.what(r.kind, lang))])
            w.text(m(.leadsLater), size: 9, grey: 0.35, gap: 8)
            w.section(3, m(.occurrences))
            let rows = occ.suffix(15).map { o -> [String] in
                [d(o.day), n(o.odoKm), n(o.minutesIn, 1), n(o.speedKmh), n(o.currentA, 1), n(o.voltage, 2), n(o.tempC), n(o.airC),
                 o.brake.map { $0 ? m(.yes) : m(.no) } ?? "-"]
            }
            w.table([ReportText.t(.date, lang), "km", m(.minutesIn), m(.speed), m(.current), m(.voltage), m(.motorTemp), m(.air), m(.braking)],
                    rows.isEmpty ? [[d(r.day), n(r.odoKm), "-", "-", "-", "-", "-", "-", "-"]] : rows,
                    widths: [0.15, 0.09, 0.11, 0.11, 0.10, 0.11, 0.11, 0.10, 0.12])
            if !unit.isEmpty, let b = base, !b.samples.isEmpty {
                w.section(4, m(.normalVsNow))
                let lo = b.samples.min() ?? 0, hi = b.samples.max() ?? 0
                w.rows([(m(.normalLine), "\(n(lo, 2)) – \(n(hi, 2)) \(unit)"), (m(.now), "\(n(r.value, 2)) \(unit)")])
            }
            w.section(5, m(.history))
            w.rows([(m(.otherFaults), others.isEmpty ? m(.none) : others.map { ReportText.faultTitle($0.kind, lang) }.joined(separator: ", ")),
                    (m(.loggedWork), logged.isEmpty ? m(.none) : logged.reversed().map { "\(d($0.day)) \u{00B7} \(n($0.odoKm)) km \u{00B7} " + ReportText.logTitle($0.what, lang) }.joined(separator: "\n"))])
            w.section(6, m(.cantSee))
            w.text(m(.cantSeeText), size: 9.5)
            w.section(7, m(.rawData))
            w.text(m(.rawDataText), size: 9.5)
            w.section(8, m(.workshop))
            w.text(m(.workshopLine), size: 10, gap: 4)
        }
        var out: [URL] = []
        if let pdf { out.append(pdf) }
        if let csv = csv(db, occ, name: "CorckieApp_Mechanic_Report\(suffix).csv") { out.append(csv) }
        return out
    }

    /// Every reading ±2 min around each event occurrence (whole ride for slow faults, at most 3 rides). Times are seconds into
    /// the ride, never clock times.
    static func csv(_ db: AppDatabase, _ occ: [FaultOccurrence], name: String) -> URL? {
        var lines = ["occurrence,ride_s,speed_kmh,current_a,voltage_v,temp_c,brake,shut_off,odometer_km"]
        let rides = Array(Set(occ.compactMap(\.rideId))).prefix(3)
        for (i, rideId) in rides.enumerated() {
            let chunks = ((try? RideQueries(db).chunks(rideId: rideId)) ?? []).filter { $0.kind == "scooter" }.sorted { $0.seq < $1.seq }
            let frames = FaultService.frames(chunks)
            guard let t0 = frames.first?.t else { continue }
            let events = occ.filter { $0.rideId == rideId }.compactMap(\.rideT)
            for f in frames {
                let s = f.t - t0
                guard events.isEmpty || events.contains(where: { abs($0 - s) <= 120 }) else { continue }
                func v(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "" }
                lines.append("\(i + 1),\(String(format: "%.2f", s)),\(v(f.speedKmh)),\(v(f.currentA)),\(v(f.voltage)),\(v(f.temperatureC)),\(f.brake ? 1 : 0),\(f.shuttingDown ? 1 : 0),\(v(f.odometerKm))")
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}
