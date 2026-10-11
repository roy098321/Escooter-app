import CorckieCore
import Foundation

/// M5-05: one ride as a CSV or GPX file in the temporary folder, ready for the share sheet (Files, AirDrop, mail, Strava / Komoot).
enum RideExportService {
    enum Format: String {
        case csv, gpx
    }

    enum ExportError: Error, LocalizedError {
        case noData

        var errorDescription: String? { "This ride has too few readings to export." }
    }

    static func fileName(_ ride: RideRecord, format: Format) -> String {
        let offset = ride.utcOffsetMin ?? 0
        let title = RideSummaryBuilder.title(startAt: ride.startAt, utcOffsetMin: offset)
        let day = RideQueries.dayKey(startAt: ride.startAt, utcOffsetMin: offset)
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        return "Ride \(clean) \(day).\(format.rawValue)"
    }

    static func content(_ ride: RideRecord, rows: [ReplayRow], format: Format) -> String {
        let offset = ride.utcOffsetMin ?? 0
        switch format {
        case .csv:
            return RideExport.csv(rows: rows, startAtMs: ride.startAt, utcOffsetMin: offset)
        case .gpx:
            return RideExport.gpx(name: RideSummaryBuilder.title(startAt: ride.startAt, utcOffsetMin: offset), rows: rows,
                                  startAtMs: ride.startAt, utcOffsetMin: offset)
        }
    }

    static func write(_ db: AppDatabase, rideId: String, format: Format) throws -> URL {
        guard let (ride, rows) = ReplayDataLoader.readings(db, rideId: rideId) else { throw ExportError.noData }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayShare", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(ride, format: format))
        try content(ride, rows: rows, format: format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
