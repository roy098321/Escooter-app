import Foundation

/// D2 section 7: the one list that says which data is the RIDER's and which is the SCOOTER's.
/// Start fresh, backup, "bring rider info back", the battery-math door and the P-9 leak check all read this map
/// instead of keeping their own lists. A guard test (AppTests/DataMapGuardTests) reads the real database schema and
/// fails the build when a table or column is missing here, so nobody can add data without deciding where it belongs.
public enum DataCategory: String, CaseIterable, Sendable {
    /// Places, routes, ride times and paths, rider settings: carried over when the rider keeps rider info
    case rider
    /// Calibration, charges, battery numbers, maintenance counters: always start over for a new scooter
    case scooter
    /// Predictions and their outcomes: always start over, so the learning curve measures the new start
    case accuracy
    /// Logs and raw chunks: stay in the backup
    case diagnostics
    /// Weather, holidays, fuel prices: not about the rider or the scooter
    case outside
    /// Database bookkeeping
    case system
}

public enum DataMap {
    /// Whole-table categories. A table in `mixedColumns` is listed here as `.rider` (its default) and refined by column.
    public static let tables: [String: DataCategory] = [
        // rider
        "place": .rider, "route": .rider, "variant": .rider, "choice_point": .rider, "choice_option": .rider,
        "stop": .rider, "climb": .rider, "elevation_point": .rider, "insight": .rider, "week_summary": .rider,
        "price_history": .rider, "ride_note": .rider, "setting": .rider,
        // mixed (see mixedColumns)
        "ride": .rider, "ride_sample": .rider, "ride_option": .rider, "ride_climb": .rider,
        // scooter
        "scooter": .scooter, "charge": .scooter, "calibration": .scooter, "wheel_calibration": .scooter,
        "maintenance_item": .scooter, "factor_effect": .scooter, "untracked_distance": .scooter,
        // accuracy
        "prediction": .accuracy, "shadow_result": .accuracy,
        // diagnostics
        "raw_chunk": .diagnostics, "gap": .diagnostics, "error_log": .diagnostics, "message_log": .diagnostics,
        "feedback": .diagnostics,
        // outside
        "weather_hour": .outside, "holiday": .outside, "fuel_price": .outside,
        // system
        "app_meta": .system
    ]

    private static func cols(_ category: DataCategory, _ names: String) -> [String: DataCategory] {
        var map: [String: DataCategory] = [:]
        for name in names.split(whereSeparator: { $0 == " " || $0 == "\n" }) { map[String(name)] = category }
        return map
    }

    private static func merged(_ parts: [[String: DataCategory]]) -> [String: DataCategory] {
        var all: [String: DataCategory] = [:]
        for part in parts { all.merge(part) { a, _ in a } }
        return all
    }

    /// Every column of the mixed tables. A ride holds both kinds: its time is the rider's, its battery use is the scooter's.
    public static let mixedColumns: [String: [String: DataCategory]] = [
        "ride": merged([
            cols(.rider, "id kind status startAt endAt firstMoveAt lastMoveAt utcOffsetMin endReason trimStartAt trimEndAt mergeGroupId loadLevel loadKg routeId variantId startPlaceId endPlaceId assignedByHand distanceM totalS movingS avgMovingMps topSpeedMps stops elevGainM elevLossM elevProvisional gearShare downhillTopMps hasGps headwindKmh windLevel wet wetOverride rushHour dayType airTempC holidayWeek excludedFromUsual promptAnswer"),
            cols(.scooter, "scooterId energyWhRaw energyWhCal usedPct usedPctMethod usedPctShown startRestPct startRestV endRestPct endRestV odoStartKm odoEndKm tempStartC tempPeakC tempRiseC timeAtMaxPct fullThrottleAccelPct fullThrottleMaxPct"),
            cols(.diagnostics, "gapScooterS gapGpsS ignoredReadings isSimulated calcVersion decoderVersion createdBuild")
        ]),
        "ride_sample": merged([
            cols(.rider, "rideId t speedMps gpsSpeedMps lat lon hAccM courseDeg altBaroM altFixedM gear capKmh brake light mode moving stopId distanceM"),
            cols(.scooter, "voltage currentA powerW batteryPct tempC odometerKm")
        ]),
        "ride_option": merged([cols(.rider, "rideId optionId timeS"), cols(.scooter, "energyWh usedPct")]),
        "ride_climb": merged([cols(.rider, "rideId climbId timeS"), cols(.scooter, "usedPct")])
    ]

    /// `setting` rows are keyed: these keys belong to the scooter (pack size, charger, recalibration, its app-only name, what the app learned about it).
    public static let scooterSettingKeys: [String] = [
        "battery.packAh", "battery.chargerA", "battery.recalibrateFromMs", "scooter.customName",
        "scooter.voltageClass", "scooter.learnedAh", "scooter.modelTag"
    ]

    public static func isScooterSetting(_ key: String) -> Bool { scooterSettingKeys.contains(key) }

    public static func category(table: String) -> DataCategory? { tables[table] }

    public static func isMixed(_ table: String) -> Bool { mixedColumns[table] != nil }

    public static func category(table: String, column: String) -> DataCategory? {
        if let columns = mixedColumns[table] { return columns[column] }
        return tables[table]
    }

    /// Tables that are wholly one category (mixed tables are not in these).
    public static func wholeTables(_ category: DataCategory) -> [String] {
        tables.filter { $0.value == category && mixedColumns[$0.key] == nil }.keys.sorted()
    }

    /// Scooter-only columns of a mixed table (what a ride's battery math reads).
    public static func scooterColumns(of table: String) -> [String] {
        (mixedColumns[table] ?? [:]).filter { $0.value == .scooter }.keys.sorted()
    }
}

/// D2 7f: the Bluetooth tag -> a model name. Unknown -> a plain description. Pure knowledge, no connection needed.
public enum KnownScooters {
    /// "RND G100" for the advertised name "G2", else a generic name.
    public static func modelName(advertisedName: String?, makerTagged: Bool) -> String {
        if advertisedName == ScooterGatt.advertisedName { return "RND G100" }
        return makerTagged ? "Scooter (RND type)" : "Scooter"
    }

    /// 1a: "RND G100 \u{00B7} 3 km \u{00B7} 87 %" (parts that are not known yet are left out).
    public static func foundText(model: String, odometerKm: Double?, batteryPct: Int?) -> String {
        var parts = [model]
        if let km = odometerKm { parts.append(String(format: "%.0f km", km)) }
        if let pct = batteryPct { parts.append("\(pct) %") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
