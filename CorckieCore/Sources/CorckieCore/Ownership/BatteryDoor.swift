import Foundation

/// D2 section 7 (the "door"): every scooter-type read (calibration, real range, usual %/km, charges, health, drain warning) goes
/// through this one filter. A ride tagged with a scooter that was forgotten (an earlier scooter, kept by "Start fresh" with rider info)
/// still counts for times, places and routes, and never for battery math. Rides with no scooter tag (older data) still count.
/// Start fresh tags the old rides with the old scooter, so the filter can tell them apart.
public enum BatteryDoor {
    /// SQL condition for a ride table (or alias) in a battery-math query: `... WHERE <other conditions> AND <this>`.
    public static func rides(_ alias: String = "ride") -> String {
        "(\(alias).scooterId IS NULL OR \(alias).scooterId IN (SELECT id FROM scooter WHERE forgottenAt IS NULL))"
    }
}
