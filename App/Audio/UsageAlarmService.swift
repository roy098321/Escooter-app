import CorckieCore
import Foundation

/// V-U1 Level 2 (batch 3): after the ride, the first extreme-use line the voice said becomes one note on the ride page
/// ("Unusual drag from km 6. Check brakes and tyres.") with the usual thumbs. The thumbs feed back like every insight.
enum UsageAlarmService {
    static func rideClosed(rideId: String, database: AppDatabase?) {
        guard let db = database, !db.isReadOnly, let ride = try? RideQueries(db).ride(id: rideId) else { return }
        let fromS = Double(ride.startAt) / 1000 - 60
        let toS = Double(ride.endAt ?? Int64(Date().timeIntervalSince1970 * 1000)) / 1000 + 60
        let said = V09LineLog.lines(db, fromS: fromS, toS: toS)
        let notes = UsageAlarmNote.insights(rideId: rideId, routeId: nil, said: said, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        guard !notes.isEmpty else { return }
        try? InsightQueries(db).save(InsightMerge(insert: notes), rideId: nil)
        Log.info(source: "voice", "V-U1: ride page note \"\(notes[0].text)\"")
    }
}
