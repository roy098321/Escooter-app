import CoreLocation
import CorckieCore
import Foundation
import UIKit

/// c8 full-ride recording: while Sensors is recording, EVERY scooter packet, GPS fix and
/// barometer reading of the ride goes to its own file (not the 2,000-packet ring), so Claude can
/// rebuild the ride and a Ride Replay on the PC. Files are streamed to disk (low memory on long
/// rides) and go into the export; the last recording is kept until the next one starts.
final class C8Recorder {
    static let shared = C8Recorder()

    static let files = ["c8-scooter-packets.csv", "c8-location.csv", "c8-barometer.csv"]

    private(set) var active = false
    private var startedAt: Date?
    private var endedAt: Date?
    private var batteryStart: Float = -1
    private var batteryEnd: Float = -1
    private var secondsWithData = Set<Int>()
    private var lastPacketAt: Date?
    private var gapsOver2s = 0
    private var longestGap = 0.0
    private var packets = 0
    private var drops: [(down: Date, up: Date?)] = []
    private var accuracies: [Double] = []
    private var baroReadings = 0
    private var writers: [String: Writer] = [:]
    private let queue = DispatchQueue(label: "corckie.c8")
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var folder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("c8", isDirectory: true)
    }

    // MARK: Session

    func start() {
        guard !active, let folder = Self.folder else { return }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writers = [
            "packets": Writer(url: folder.appendingPathComponent(Self.files[0]), header: "time,step,app_state,bytes"),
            "location": Writer(url: folder.appendingPathComponent(Self.files[1]),
                               header: "time,lat,lon,speed_mps,h_accuracy_m,altitude_m,course_deg"),
            "barometer": Writer(url: folder.appendingPathComponent(Self.files[2]), header: "time,relative_altitude_m,pressure_kpa")
        ]
        UIDevice.current.isBatteryMonitoringEnabled = true
        startedAt = Date()
        endedAt = nil
        batteryStart = UIDevice.current.batteryLevel
        batteryEnd = -1
        secondsWithData = []
        lastPacketAt = nil
        gapsOver2s = 0
        longestGap = 0
        packets = 0
        drops = []
        accuracies = []
        baroReadings = 0
        active = true
    }

    func stop() {
        guard active else { return }
        active = false
        endedAt = Date()
        batteryEnd = UIDevice.current.batteryLevel
        queue.sync { writers.values.forEach { $0.close() } }
        writers = [:]
    }

    // MARK: Streams

    func packet(_ bytes: [UInt8], at time: Date, background: Bool) {
        guard active, let start = startedAt else { return }
        packets += 1
        secondsWithData.insert(Int(time.timeIntervalSince(start)))
        if let last = lastPacketAt {
            let gap = time.timeIntervalSince(last)
            if gap > 2 {
                gapsOver2s += 1
                longestGap = max(longestGap, gap)
            }
        }
        lastPacketAt = time
        write("packets", "\(iso.string(from: time)),c8,\(background ? "background" : "open"),\(Hex.string(bytes))")
    }

    func location(_ l: CLLocation) {
        guard active else { return }
        if l.horizontalAccuracy >= 0 { accuracies.append(l.horizontalAccuracy) }
        let line = String(format: "%@,%.7f,%.7f,%.2f,%.1f,%.1f,%.1f", iso.string(from: l.timestamp),
                          l.coordinate.latitude, l.coordinate.longitude, l.speed, l.horizontalAccuracy, l.altitude, l.course)
        write("location", line)
    }

    func barometer(relativeAltitudeM: Double, pressureKPa: Double, at time: Date) {
        guard active else { return }
        baroReadings += 1
        write("barometer", String(format: "%@,%.3f,%.4f", iso.string(from: time), relativeAltitudeM, pressureKPa))
    }

    func linkDown(at time: Date) {
        guard active else { return }
        drops.append((down: time, up: nil))
    }

    func linkUp(at time: Date) {
        guard active, let last = drops.last, last.up == nil else { return }
        drops[drops.count - 1].up = time
    }

    private func write(_ key: String, _ line: String) {
        guard let writer = writers[key] else { return }
        queue.async { writer.append(line) }
    }

    // MARK: Summary (the c8 ℹ️ note)

    func summary() -> String? {
        guard let start = startedAt else { return nil }
        let end = endedAt ?? Date()
        let total = max(1, Int(end.timeIntervalSince(start)))
        let level = endedAt == nil ? UIDevice.current.batteryLevel : batteryEnd
        let battery = batteryStart >= 0 && level >= 0
            ? String(format: "phone battery %.0f%% → %.0f%%", batteryStart * 100, level * 100)
            : "phone battery not readable"
        let sorted = accuracies.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let dropText = dropsText(start: start)
        let covered = min(secondsWithData.count, total)
        let share = Double(covered) / Double(total) * 100
        let part1 = "\(total / 60) min · scooter data \(covered) of \(total) s (\(String(format: "%.0f", share))%) · \(packets) packets"
        let part2 = "\(gapsOver2s) gaps > 2 s (longest \(Int(longestGap)) s) · \(dropText)"
        let part3 = "\(accuracies.count) fixes, median accuracy \(String(format: "%.0f", median)) m · \(baroReadings) barometer readings"
        return "\(part1) · \(part2) · \(part3) · \(battery) · files: " + Self.files.joined(separator: ", ")
    }

    private func dropsText(start: Date) -> String {
        if drops.isEmpty { return "0 link drops" }
        var parts: [String] = []
        for d in drops {
            let at = Int(d.down.timeIntervalSince(start))
            let clock = "\(at / 60):" + String(format: "%02ld", at % 60)
            if let up = d.up {
                parts.append("at \(clock) back after \(Int(up.timeIntervalSince(d.down))) s")
            } else {
                parts.append("at \(clock) not back")
            }
        }
        return "\(drops.count) link drops (" + parts.joined(separator: "; ") + ")"
    }

    /// The last recording's files, for the export (flushed first).
    func exportFiles() -> [URL] {
        queue.sync { writers.values.forEach { $0.flush() } }
        guard let folder = Self.folder else { return [] }
        return Self.files.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Appends lines to one file, buffered.
    final class Writer {
        private let handle: FileHandle?
        private var buffer = ""
        private var lines = 0

        init(url: URL, header: String) {
            FileManager.default.createFile(atPath: url.path, contents: Data((header + "\n").utf8))
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }

        func append(_ line: String) {
            buffer += line + "\n"
            lines += 1
            if lines >= 200 { flush() }
        }

        func flush() {
            guard !buffer.isEmpty else { return }
            try? handle?.write(contentsOf: Data(buffer.utf8))
            buffer = ""
            lines = 0
        }

        func close() {
            flush()
            try? handle?.close()
        }
    }
}
