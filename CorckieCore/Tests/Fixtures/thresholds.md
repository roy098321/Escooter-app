| ID | Threshold | Value | Used in | Kind |
|---|---|---|---|---|
| T01 | Wheel speed scale | 0.0476 km/h per unit | Decode | Fact |
| T02 | Max plausible speed (retired) | none · only the step check T03 (owner, P4 D1 A2) | G1b | Owner decision 2026-10-02: real speeds reach 50.7 km/h (ride 1), confirmed by GPS (ride 2) |
| T03 | Max speed step | 15 km/h within 1 s | G1b | Guess |
| T04 | Max battery % change while moving | 5% per 60 s | G1b | Guess |
| T05 | Voltage range | 39.0–55.5 V | G1b | Guess |
| T06 | Temperature range | −20…130 °C | G1b | Fact |
| T07 | Format-change watch | > 20% failed frames over 60 s, or no packet A for 10 s | G1b | Guess |
| T10 | Autostart wheel speed | > 2 km/h | M1 | Guess (0.14 km/h reported ✅) |
| T11 | Confirm: current | > 0.5 A for 1 s | M1 | Guess |
| T12 | Confirm: GPS speed | > 8 km/h for 3 s | M1 | Guess |
| T13 | Confirm: GPS distance | 50 m while the wheel moves | M1 | Guess |
| T14 | Cancel: GPS still | 20 s | M1 | Guess |
| T15 | Cancel: unconfirmed | 2 min | M1 | Guess |
| T16 | Walking trim | < 7 km/h and < 0.5 A | M1 | Guess |
| T17 | End A | disconnected 30 s + GPS still | M2 | Guess |
| T18 | End A without GPS | disconnected 2 min | M2 | Guess |
| T19 | End B hold | 1 s | M2 | Fixed |
| T20 | End C standstill | 10 min | M2 | Guess |
| T21 | Same ride window | 10 min and 200 m | M2 | Guess |
| T22 | Discarded pieces kept | 24 h | M36 | Fixed |
| T23 | Stop start | < 3 km/h for 3 s, moved < 5 m | M3 | Guess |
| T24 | Stop end | > 5 km/h | M3 | Guess |
| T25 | Stop merge | < 10 s and < 15 m apart | M3 | Guess |
| T26 | Stop, phone mode | GPS < 2 km/h for 5 s | M3 | Guess |
| T27 | GPS still | GPS < 2 km/h and moved < 15 m over the window | M1, M2 | Guess |
| T28 | Good fix | accuracy ≤ 20 m | all | Guess |
| T29 | GPS speed shown as 0 | < 5 km/h | G1 | Fixed |
| T30 | Clean stretch (wheel cal.) | ≥ 500 m, ≤ 10 m accuracy, ≥ 10 km/h, ≤ 20° turn | M5 | Guess |
| T31 | Wheel factor | median of last 30, clamped 0.90–1.10, used after 5 | M5 | Guess |
| T32 | Lifted / spinning wheel | wheel ≥ 50 m while GPS < 5 m | M5 | Guess |
| T33 | Top speed held | ≥ 1 s | M7 | Fixed |
| T40 | Rested reading | standstill, < 0.2 A, ≥ 20 s (start: first 5 s after connect) | M8 | Guess |
| T41 | Calibration ride | rested drop ≥ 10%, no gap > 1 min; ≥ 5 rides | M8 | Guess |
| T42 | Pack energy | Ah × 48 V; default 16 Ah | M8, M35, M37 | Fact (48 V); 16 Ah to confirm (label, P6) |
| T43 | Battery / km shown after | 1 km | M9 | Fixed |
| T45 | Charge detection | +3% and +0.5 V rested | M30 | Guess |
| T46 | Charge time | steady to 85%, last 15% = 1 h; charger 2.0 A | M37 | Guess |
| T47 | Heat warnings | hot 90 °C, very hot 100 °C; learned limit −5 °C after 2 protection events | M38 | Guess |
| T48 | Ran hotter | heating rate ≥ +30%, route ≥ 5 rides | M38 | Guess |
| T49 | Takeover battery estimate | last % − usual %/km × GPS km | G1 | Fixed |
| T50 | Barometer | 2-s median; spike > 3 m/s; 2 m hysteresis; drift ≥ 1 km windows, ≤ 2 m/km; confirmed climb = +2 m in 30 s with −3 km/h | M10 | Guess |
| T60 | Same place | 5% of trip, 100 m – 1 km | M11 | Guess |
| T61 | Same variant | 50 m corridor, ≥ 80% of distance | M12 | Guess |
| T62 | New variant | off-path > 5% of length (≥ 100 m), ≥ 80% of its points > 50 m | M12 | Guess |
| T63 | Suggest route | after 2 trips | C11 | Fixed |
| T64 | Usual range | middle 80% of the last 20 rides in 90 days; < 5 rides = full range | M13 | Fixed |
| T65 | Range split | width > 40% of median; groups ≥ 3 | M13 | Guess |
| T66 | Noticeably different | ≥ 1 min or ≥ 2% | M14 | Guess |
| T67 | Enough data | time 3, battery 5 rides; rare factors 12 months | M15 | Guess |
| T68 | Compare suggestion | both > 1 km | Compare | Fixed |
| T69 | Merge offer | ≤ 30 min, ≤ 200 m | Merge | Guess |
| T70 | Wind levels | < 15 · 15–30 · > 30 km/h | M16 | Guess |
| T71 | Wet | ≥ 0.2 mm/h; window 1 h + 1 h / 2 mm, max 4 h; heavy ≥ 2.5 mm/h | M17 | Guess |
| T72 | Rush hour | 07:00–09:30, 16:00–19:00, workdays | M18 | Fixed |
| T73 | Time at max | ≥ 0.9 × P95 reference, grade > −1%, last 10 rides | M20 | Guess |
| T74 | Full throttle (estimated) | current ≥ 90% of learned max | M22 | Guess |
| T75 | Load levels | Light 5 kg, Heavy 15 kg | M23 | Setting |
| T76 | Factor confirmation | same sign, within ×2 | M24 | Guess |
| T80 | Range reserve | **% where the battery ran out** (pushing event, M1 D3), else lowest % reached, else 5% | M25, M27 | Guess |
| T81 | Low battery band | < 20% | M25, M27 | Guess |
| T102 | Pushing (walking stretch) | wheel or GPS 1–7 km/h, motor < 0.5 A, for 30 s (M1 D3, 2026-10-04) | M2, M3, M4, M14 | Guess |
| T82 | There and back | ✅ ≥ 10% spare, ⚠ < 10%, ❌ < 0 | M27 | Fixed |
| T101 | Safety margin on decisions (G2, owner 2026-10-04) | +10% of what is needed | M27, Routes greying, V04, V06 | Fixed (policy) |
| T83 | Arrival display | ≤ every 30 s or change ≥ 1 min | M28 | Fixed |
| T84 | Arrive-by update | leave time ≥ 2 min earlier | M29 | Fixed |
| T85 | Real range basis | last 10 rides | M25 | Guess |
| T90 | Destination guess | ≥ 4 rides, ±60 min, 60 days, ≥ 70% | Q1 | Guess |
| T91 | Variant comparison | ≥ 2 variants × ≥ 3 rides | Q1, Q2 | Fixed |
| T92 | Battery tight on arrival | < 10% | Q2 | Guess |
| T93 | Shortcut verdict | after 3 rides; < 20 s = no difference | Q3 | Fixed |
| T94 | Headwind at start | wind along route > 15 km/h | Q15 | Guess |
| T95 | Q23 prompts | options ≥ 3 rides, ≥ 20 s, ≥ 30 m; beat best ≥ 1 min; ~15 s ahead | Q23 | Fixed |
| T96 | Q13 noteworthy | ≥ 1 min or ≥ 2% | Q13 | Guess |
| T97 | Smart prompt | ≥ 5 rides, ≥ 2% unexplained, 1 / day, pause 7 days after 2 dismissals, 3 answers → factor | C26 | Fixed |
| T98 | Message budget | ride start ≤ 2 · banner ≤ 8 s · tappable < 5 km/h · queue ≤ 2 · ≤ 2 notifications / day · quiet 22–07 · weekly Sun 07:30 | C24 | Fixed |
| T99 | Speed warning tile | > **45 km/h**, red + "SLOW"; clears below 43 (owner, 2026-10-04; was 30) | C30, P3 D3 | Fixed |
| T100 | UI timers | No GPS chip after 10 s · connect fails after 30 s · last seen "yesterday" after 24 h · backup warning after 14 days | STATES, C13 | Fixed |
