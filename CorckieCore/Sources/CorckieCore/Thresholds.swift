import Foundation

/// Every threshold of CALC_SPEC §10, one constant per T-ID (ARCHITECTURE §2.4, §6.2).
/// P6 tuning changes this file only. Units are in the names; SI inside unless named.
/// `T.catalog` mirrors the doc's Value column word for word; a test compares it with
/// `Tests/Fixtures/thresholds.md` (a copy of the doc table) so code and doc can't drift.
public enum T {
    // MARK: Decode and G1b
    /// T01 Wheel speed scale (Fact)
    public static let t01WheelKmhPerUnit = 0.0476
    /// T02 Max plausible speed (43 seen)
    public static let t02MaxSpeedKmh = 45.0
    /// T03 Max speed step within 1 s
    public static let t03MaxSpeedStepKmhPerS = 15.0
    /// T04 Max battery % change while moving, per 60 s
    public static let t04MaxBatteryStepPct = 5.0
    public static let t04WindowS = 60.0
    /// T05 Voltage range
    public static let t05MinVoltage = 39.0
    public static let t05MaxVoltage = 55.5
    /// T06 Temperature range
    public static let t06MinTempC = -20.0
    public static let t06MaxTempC = 130.0
    /// T07 Format-change watch
    public static let t07FailedFrameShare = 0.20
    public static let t07WindowS = 60.0
    public static let t07NoPacketAS = 10.0

    // MARK: M1 start, M2 end, M3 stops
    public static let t10AutostartKmh = 2.0
    public static let t11ConfirmCurrentA = 0.5
    public static let t11ConfirmCurrentS = 1.0
    public static let t12ConfirmGpsKmh = 8.0
    public static let t12ConfirmGpsS = 3.0
    public static let t13ConfirmGpsDistanceM = 50.0
    public static let t14CancelGpsStillS = 20.0
    public static let t15CancelUnconfirmedS = 120.0
    public static let t16WalkingKmh = 7.0
    public static let t16WalkingCurrentA = 0.5
    public static let t17EndDisconnectedS = 30.0
    public static let t18EndNoGpsS = 120.0
    public static let t19EndHoldS = 1.0
    public static let t20EndStandstillS = 600.0
    public static let t21SameRideS = 600.0
    public static let t21SameRideM = 200.0
    public static let t22DiscardedKeptS = 86_400.0
    public static let t23StopKmh = 3.0
    public static let t23StopS = 3.0
    public static let t23StopMovedM = 5.0
    public static let t24StopEndKmh = 5.0
    public static let t25StopMergeS = 10.0
    public static let t25StopMergeM = 15.0
    public static let t26PhoneStopKmh = 2.0
    public static let t26PhoneStopS = 5.0
    public static let t27GpsStillKmh = 2.0
    public static let t27GpsStillM = 15.0
    public static let t28GoodFixM = 20.0
    public static let t29GpsZeroKmh = 5.0

    // MARK: M5, M7 distance and speed
    public static let t30CleanStretchM = 500.0
    public static let t30CleanAccuracyM = 10.0
    public static let t30CleanKmh = 10.0
    public static let t30CleanTurnDeg = 20.0
    public static let t31WheelFactorCount = 30
    public static let t31WheelFactorMin = 0.90
    public static let t31WheelFactorMax = 1.10
    public static let t31WheelFactorUsedAfter = 5
    public static let t32LiftedWheelM = 50.0
    public static let t32LiftedGpsM = 5.0
    public static let t33TopSpeedHeldS = 1.0

    // MARK: Battery (M8, M9, M30, M37, M38)
    public static let t40RestedCurrentA = 0.2
    public static let t40RestedS = 20.0
    public static let t40StartWindowS = 5.0
    public static let t41CalibrationDropPct = 10.0
    public static let t41CalibrationMaxGapS = 60.0
    public static let t41CalibrationRides = 5
    public static let t42PackVoltage = 48.0
    public static let t42DefaultPackAh = 16.0
    public static let t43BatteryPerKmAfterM = 1_000.0
    public static let t45ChargeRisePct = 3.0
    public static let t45ChargeRiseV = 0.5
    public static let t46SteadyToPct = 85.0
    public static let t46LastPartS = 3_600.0
    public static let t46ChargerA = 2.0
    public static let t47HotC = 90.0
    public static let t47VeryHotC = 100.0
    public static let t47LearnedMarginC = 5.0
    public static let t47LearnedAfterEvents = 2
    public static let t48HotterRate = 0.30
    public static let t48HotterMinRides = 5
    public static let t50BaroMedianS = 2.0
    public static let t50BaroSpikeMps = 3.0
    public static let t50BaroHysteresisM = 2.0

    // MARK: Places and routes (M11–M15)
    public static let t60SamePlaceShare = 0.05
    public static let t60SamePlaceMinM = 100.0
    public static let t60SamePlaceMaxM = 1_000.0
    public static let t61CorridorM = 50.0
    public static let t61CorridorShare = 0.80
    public static let t62OffPathShare = 0.05
    public static let t62OffPathMinM = 100.0
    public static let t63SuggestRouteTrips = 2
    public static let t64UsualRangeRides = 20
    public static let t64UsualRangeDays = 90.0
    public static let t64UsualRangeMiddle = 0.80
    public static let t64FullRangeBelowRides = 5
    public static let t65RangeSplitWidth = 0.40
    public static let t65RangeSplitGroup = 3
    public static let t66DifferentS = 60.0
    public static let t66DifferentPct = 2.0
    public static let t67EnoughTimeRides = 3
    public static let t67EnoughBatteryRides = 5
    public static let t67RareFactorMonths = 12
    public static let t68CompareMinM = 1_000.0
    public static let t69MergeS = 1_800.0
    public static let t69MergeM = 200.0

    // MARK: Factors (M16–M24)
    public static let t70WindLightKmh = 15.0
    public static let t70WindStrongKmh = 30.0
    public static let t71WetMmPerH = 0.2
    public static let t71HeavyMmPerH = 2.5
    public static let t71WetMaxWindowH = 4.0
    public static let t73TimeAtMaxShareOfP95 = 0.9
    public static let t73TimeAtMaxMinGradePct = -1.0
    public static let t73TimeAtMaxRides = 10
    public static let t74FullThrottleShare = 0.90
    public static let t75LightLoadKg = 5.0
    public static let t75HeavyLoadKg = 15.0
    public static let t76FactorConfirmRatio = 2.0

    // MARK: Estimates (M25–M29)
    public static let t80ReserveDefaultPct = 5.0
    public static let t81LowBatteryPct = 20.0
    public static let t82SparePct = 10.0
    public static let t83ArrivalEveryS = 30.0
    public static let t83ArrivalChangeS = 60.0
    public static let t84ArriveByEarlierS = 120.0
    public static let t85RealRangeRides = 10

    // MARK: Insights and messages
    public static let t90DestinationRides = 4
    public static let t90DestinationWindowMin = 60.0
    public static let t90DestinationDays = 60.0
    public static let t90DestinationShare = 0.70
    public static let t91VariantCount = 2
    public static let t91VariantRides = 3
    public static let t92TightArrivalPct = 10.0
    public static let t93ShortcutRides = 3
    public static let t93NoDifferenceS = 20.0
    public static let t94HeadwindKmh = 15.0
    public static let t96NoteworthyS = 60.0
    public static let t96NoteworthyPct = 2.0
    public static let t97SmartPromptRides = 5
    public static let t97SmartPromptPct = 2.0
    public static let t98BannerS = 8.0
    public static let t98TappableBelowKmh = 5.0
    public static let t98NotificationsPerDay = 2
    public static let t98QuietFromHour = 22
    public static let t98QuietToHour = 7
    public static let t99SlowKmh = 30.0
    public static let t100NoGpsChipS = 10.0
    public static let t100ConnectFailS = 30.0
    public static let t100LastSeenYesterdayS = 86_400.0
    public static let t100BackupWarningDays = 14.0

    /// CALC_SPEC §10 Value column, word for word (checked against the doc copy by a test).
    public static let catalog: [String: String] = [
        "T01": "0.0476 km/h per unit",
        "T02": "45 km/h (43 seen)",
        "T03": "15 km/h within 1 s",
        "T04": "5% per 60 s",
        "T05": "39.0–55.5 V",
        "T06": "−20…130 °C",
        "T07": "> 20% failed frames over 60 s, or no packet A for 10 s",
        "T10": "> 2 km/h",
        "T11": "> 0.5 A for 1 s",
        "T12": "> 8 km/h for 3 s",
        "T13": "50 m while the wheel moves",
        "T14": "20 s",
        "T15": "2 min",
        "T16": "< 7 km/h and < 0.5 A",
        "T17": "disconnected 30 s + GPS still",
        "T18": "disconnected 2 min",
        "T19": "1 s",
        "T20": "10 min",
        "T21": "10 min and 200 m",
        "T22": "24 h",
        "T23": "< 3 km/h for 3 s, moved < 5 m",
        "T24": "> 5 km/h",
        "T25": "< 10 s and < 15 m apart",
        "T26": "GPS < 2 km/h for 5 s",
        "T27": "GPS < 2 km/h and moved < 15 m over the window",
        "T28": "accuracy ≤ 20 m",
        "T29": "< 5 km/h",
        "T30": "≥ 500 m, ≤ 10 m accuracy, ≥ 10 km/h, ≤ 20° turn",
        "T31": "median of last 30, clamped 0.90–1.10, used after 5",
        "T32": "wheel ≥ 50 m while GPS < 5 m",
        "T33": "≥ 1 s",
        "T40": "standstill, < 0.2 A, ≥ 20 s (start: first 5 s after connect)",
        "T41": "rested drop ≥ 10%, no gap > 1 min; ≥ 5 rides",
        "T42": "Ah × 48 V; default 16 Ah",
        "T43": "1 km",
        "T45": "+3% and +0.5 V rested",
        "T46": "steady to 85%, last 15% = 1 h; charger 2.0 A",
        "T47": "hot 90 °C, very hot 100 °C; learned limit −5 °C after 2 protection events",
        "T48": "heating rate ≥ +30%, route ≥ 5 rides",
        "T49": "last % − usual %/km × GPS km",
        "T50": "2-s median; spike > 3 m/s; 2 m hysteresis; drift ≥ 1 km windows, ≤ 2 m/km; confirmed climb = +2 m in 30 s with −3 km/h",
        "T60": "5% of trip, 100 m – 1 km",
        "T61": "50 m corridor, ≥ 80% of distance",
        "T62": "off-path > 5% of length (≥ 100 m), ≥ 80% of its points > 50 m",
        "T63": "after 2 trips",
        "T64": "middle 80% of the last 20 rides in 90 days; < 5 rides = full range",
        "T65": "width > 40% of median; groups ≥ 3",
        "T66": "≥ 1 min or ≥ 2%",
        "T67": "time 3, battery 5 rides; rare factors 12 months",
        "T68": "both > 1 km",
        "T69": "≤ 30 min, ≤ 200 m",
        "T70": "< 15 · 15–30 · > 30 km/h",
        "T71": "≥ 0.2 mm/h; window 1 h + 1 h / 2 mm, max 4 h; heavy ≥ 2.5 mm/h",
        "T72": "07:00–09:30, 16:00–19:00, workdays",
        "T73": "≥ 0.9 × P95 reference, grade > −1%, last 10 rides",
        "T74": "current ≥ 90% of learned max",
        "T75": "Light 5 kg, Heavy 15 kg",
        "T76": "same sign, within ×2",
        "T80": "lowest % reached, else 5%",
        "T81": "< 20%",
        "T82": "✅ ≥ 10% spare, ⚠ < 10%, ❌ < 0",
        "T83": "≤ every 30 s or change ≥ 1 min",
        "T84": "leave time ≥ 2 min earlier",
        "T85": "last 10 rides",
        "T90": "≥ 4 rides, ±60 min, 60 days, ≥ 70%",
        "T91": "≥ 2 variants × ≥ 3 rides",
        "T92": "< 10%",
        "T93": "after 3 rides; < 20 s = no difference",
        "T94": "wind along route > 15 km/h",
        "T95": "options ≥ 3 rides, ≥ 20 s, ≥ 30 m; beat best ≥ 1 min; ~15 s ahead",
        "T96": "≥ 1 min or ≥ 2%",
        "T97": "≥ 5 rides, ≥ 2% unexplained, 1 / day, pause 7 days after 2 dismissals, 3 answers → factor",
        "T98": "ride start ≤ 2 · banner ≤ 8 s · tappable < 5 km/h · queue ≤ 2 · ≤ 2 notifications / day · quiet 22–07 · weekly Sun 07:30",
        "T99": "> 30 km/h, red + \"SLOW\"",
        "T100": "No GPS chip after 10 s · connect fails after 30 s · last seen \"yesterday\" after 24 h · backup warning after 14 days"
    ]
}
