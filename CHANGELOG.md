# Changelog

One section per release name (VB.DDMMYY.HH: version, batch, due date, hotfix). Plain words, one line per change.

## 111.291126.06 — hotfix 06 of batch 11: fixes from the first G500 commute

- B103: a discarded piece (Start pressed, then a restart) is never a trip leg (`TripRules.Leg.discarded`); a trip opened before .06 drops such legs before merging; a merge reclasses from the merged distance even when its first leg was discarded. The 14 km ride had been hidden as "discarded".
- B104: route and place rides keep their times for every scooter, but their battery use (usedPct) only through `BatteryDoor` (the active scooter, or untagged older rides): Home's "uses N%", the arrival %, "more than usual" and the usage lines no longer borrow another scooter's rides; recent usage lines likewise.
- B105: after a spoken line the music is un-ducked by deactivating the session (notifyOthersOnDeactivation) and reopening it without duckOthers (changing the options on an active session left it low); a line spoken outside a ride also gives the music back.
- G500 battery %: between rested readings it counts down by the Ah used (packet current, at most 2 s per step); standing, a rested reading 1 point off the shown % is ignored.

## 111.291126.05 — hotfix 05 of batch 11: G500 battery %, pack per model, quiet byte watch

- B102: `ScooterModels` pack table (P-6: per model, not per rider): RND G100 48 V 13S 16 Ah, RND G500 60 V 16S 21 Ah. `BatterySettings.packAh` = the rider's value for the active scooter, else its model's pack, else T42; per scooter through the Garage swap. Turns on range, charge-timer start %, calibration and health for the G500.
- B102: G500 battery % from the resting voltage (`LiIonCurve`, NMC open-circuit curve): the first reading of a connection, then after 10 s standing at ≤ T40 current; held while riding; nil until a rested reading. Same settle / flip filter as the G100 path after that.
- B102: G500 temperature = highest of the last 10 s (it dips 3–11 °C above ~48 km/h, even coasting). Byte 18 documented: 0x08 brake, 0x02 motor driven (also electric braking; not throttle). Bytes 2–3 are RND's brand code, not an ID.
- B102: quiet watch log (`ByteWatch`, owner OK): G500 bytes 8–9, 16, 17 and unknown byte-18 bits; first value per connection, then changes only, with the moment's readings and raw packets; newest 500, 60 days; no UI. Written into Export everything with the Bluetooth events (`devLogs`, optional; Restore ignores it).

## 111.291126.04 — hotfix 04 of batch 11: B102, a ride with an unreadable scooter falls back to phone GPS

- B102: RideEngine.scooterGoneSince ignored a connection that never brought a usable reading (lastFrameT nil while connected), so phone mode never started: the ride saved 0 s, no path, and a GPS-integrated distance. `connectedSinceT` now counts such a connection as "scooter gone" from its start: after the ~5 s takeover wait the ride runs on phone GPS (samples, path, time). Tests in B102PhoneFallbackTests.

## 111.291126.03 — hotfix 03 of batch 11: B102 step 2, the RND G500 decoder

- B102: `PacketG500` (20 bytes starting 0x24 0x20): voltage 4–5 ÷ 100, current 6–7 ÷ 100, wheel speed 10–11 × 0.0516 km/h (GPS-checked; the dashboard's km/h in byte 12 reads ~8 % higher), temperature 14–15 ÷ 100 (🟡), status 18 (0x02 motor · 0x08 brake · 0x80 shutting down). No odometer, battery % or gear in the stream: they stay nil; ride distance comes from the wheel speed (RideEngine's integrated distance).
- FrameAssembler.Kind `.full` (one packet with the A and B fields): RideTotals adds speed and energy from it; plausibility voltage range per layout (`ScooterLayout.voltageRange`: G2 = T05, G500 42–68 V).
- Setup line: "Connected" when the scooter sends no km (instead of "check the same km"). Decoder.version 2.

## 111.291126.02 — hotfix 02 of batch 11: B102 setup kept searching while the scooter was connected

- B102: OnboardingView's found check ran on a Timer publisher made in the view's init; Home redraws every second and re-made it, so the tick could miss and setup kept "searching" (no Connect) although the scooter was connected. It now runs in a `.task` loop tied to the screen and also reacts to the connection at once (`onChange(of: connected)`). Guard test in B102Tests.

## 111.291126.01 — hotfix 01 of batch 11: B102 (the G500 can't be saved in setup and its numbers are wrong)

- B102 (a): any connection made while setup is open can be saved with Connect, also one iOS restored or reconnected (pairingPending was false then, so Connect did nothing).
- B102 (a): a scooter that was never paired is never reconnected on its own (didDisconnect reconnected whenever a peripheral was set: background connects to an unpaired scooter). It is let go and the app keeps looking; a new scooter is connected only while setup (or Add another scooter) is open.
- B102 (a): after Set up later the app keeps looking and remembers the closest scooter, so opening setup again connects it at once.
- B102 (b): packet A must be the G2 layout (Decoder.isG2PacketA: 20 bytes, byte 19 = 0, byte 2 = 0, gear 1–3, battery % ≤ 100; true for all 40 646 G2 packets on record). Any other layout is unknown: three such packets and no packet A on a connection → "Connected · numbers not supported yet" (Home, setup); no numbers on screen, in rides, calibration or charge logic; raw packets kept.

## 111.291126.00 — batch 11: feature worlds (Garage, tyre-pressure hint) + the 100th-bug thank-you

- N11-2 / O4 Garage (auto-first): a scooter not seen before is added when it connects, named after its model; active = the connected one (not connected: the last one); only the active scooter's row is "not forgotten", so BatteryDoor and ScooterRecord.latest give each scooter its own battery math, faults, maintenance and service book; per-scooter settings (pack, charger, learned Ah, charging speed, name, colour, photo frame) and the photo are parked as key@id and swapped back; new rides are tagged with the active scooter; rides from before the Garage go to the scooter in use at the time (GarageLegacy). Registry in setting garage.registry (no schema change).
- N11-2: Sold / Lost (no nearby notification) / Remove: nothing deleted, the service book still exports (MaintenanceHistoryView + HistoryPDF take a scooter id); Forget = Remove; Just borrowing = no maintenance alerts; Stats filter (all by default) from 2 scooters; lock screen name only with 2+; Bluetooth waits for any Garage scooter (pending connects) and the first one switched on becomes active; Add another scooter sheet. Still read-only (FFF2 notify + 180A read).
- N11-1 / E4 tyre-pressure hint (EnergyHint): Wh per km on the same route vs similar rides (temperature, wind, rain, speed, stops, gear, distance = no detour, pull = no extra load); clean data only (gaps, wheel km over GPS, no route skipped; firmware change / battery or tyre replaced / lasting drop = new normal); no hint before 10 clean rides; creep over 5 rides → Tyres tile "Check tyre pressure" (tyre type from the model), jump over 2 rides → Brakes "Check the wheels turn freely", rise + motor hotter → Motor "Worth a shop check"; optional taps (Pumped it, Checked pressure is fine → logged, Fine too, Found it); no tap and still high after 3 rides → next step; "Back to normal: +N km of range" once.
- N11-1 LoadEstimate (pull vs acceleration) replaces the "carrying more?" question. Tested on synthetic rides only: still to be checked against the owner's real export.
- N11-4: What's new hero line "Bug #100 fixed 🎉 Thanks for every report." + a one-time confetti burst behind the card (once per version, ~2 s, no sound, a tap ends it, none with Reduce Motion). Removed again in batch 12 (N12-1).
- N11-3 and N11-5 shipped first in hotfix 110.221126.02.
- Lab checks u203 (automatic), ui208–ui211 (phone).

## 110.221126.02 — hotfix 02 of batch 10: N11-5 and N11-3 from batch 11, shipped first (owner can't connect the new scooter)

- N11-5 / B101: scooters are found by a list of known advertised names (ScooterGatt.knownNames: G2 → RND G100, G500 → RND G500), not one name; the card is named after the model; unknown names are still ignored. Same read-only connection (FFF2 notify + 180A read).
- N11-5: a reconnect without a fresh scan takes the model from the peripheral's name, or keeps the saved name (it no longer falls back to RND G100).
- N11-3 / B100: HeaderMark @2x/@3x re-exported with the circle mask pulled in ~4 % (Tools/b100_headermark.py); guard test Batch111Tests reads the asset's pixels.

## 110.221126.01 — hotfix 01 of batch 10 (owner 22 Nov)

- B97 follow-up: Home's top-left logo is the owner's new round logo (the orange C on a black disc, cut to the circle); asset HeaderMark @2x/@3x.
- Option A (owner 22 Nov, mock tile-opens-part-A.png): a Scooter tab part tile and a Maintenance row open the part's own page (PartPageView); the push-then-pop-up is gone.
- EXPERIMENTAL (owner 22 Nov): charging speed from switch-on readings (ChargeAutoMeasure / ChargeAutoStore): 3 readings over 40+ min within 2 % of a straight line; first 10 s skipped; the charge timer stays on; readings (time, %, V) logged and kept for Export everything; never fed to F11 / F12.

## 110.221126.00 — batch 10: maintenance (fault recognition, Maintenance screen, history, mechanic report) + B97–B99

- N10-1..N10-11: fault recognition behind one shared gate (learn 10 rides per scooter, worst normal + 10 %, repeats, ruled-out rides, Checked it's fine, 2-week rule, one per summary; firmware change relearns, a replaced part resets): F1 battery strain, F2 power cuts (the scooter's shut-off signal; the link-lost path follows the standing test on the new scooter), F3 brake not cutting the motor, F5 tyre, F6 heat vs a learned model, F7 impossible sensor readings, F11 parked drain, F12 voltage at full, F16 km counter reset. F4 and F8 dropped after the audit.
- N10-2 / N10-3: in-ride voice (L3: ping, line, vibration) for the 2nd / 4th power cut and a repeated brake fault, red light on the ride screen.
- N10-12: one pop-up over the ride summary (amber / red / grey info), Tell me more with Checked it's fine / I fixed it; switch-on pop-up over Home or a notification.
- N10-13: new Maintenance screen (issue cards on top, one list per part, reminder page, Log what I did) replacing Settings → Maintenance's list; fault page with your normal vs the last rides.
- N10-14: full maintenance history (battery card + decay chart, counts, timeline with Measured / Entered) and a PDF service book in English / Hebrew.
- N10-15: mechanic report PDF (English / Hebrew, one issue; Leads left out until a mechanic checks them) + CSV of the readings around each occurrence.
- N10-19 / N10-20 / N10-21: orange dot on the Scooter tab, Home line when something is due, Scooter tab Maintenance card with the wide Battery tile (the separate Battery row removed), battery findings on top of the one Battery page.
- N10-16..18: B97 Home logo is the C only, B98 List rows no longer grey, B99 the ride colour strip is a bar.
- Lab checks u202 (automatic), ui204–ui207 (phone).

## 108.131226.04 — hotfix 04 of batch 8 (owner 20 Nov: welcome image OK, AI-generated)

- A-06: the welcome screen's theme image is in the app (asset WelcomeHero, JPEG from reports/onboarding-welcome/hero.webp, no metadata); the plain fallback stays in code.

## 108.131226.03 — hotfix 03 of batch 8: all of batch 9 (B96 + the new-rider audit of 18 Nov)

- N9-1 / B96: the ride replay sound plays out in full (no fade at the route-draw length); the line and the haptic keep their length.
- A-01 / A-02 / A-27: a fresh install opens onboarding by itself, marks What's new as seen silently, and Home on day 0 is the status and Start (Where to? with the first ride or place).
- A-03 / A-04: no outside data and no location fix before onboarding is done and location is allowed; Hebcal holidays only for phone region IL.
- A-05: the build stamp is off; the version shows in Settings → About.
- A-06: welcome screen (theme image or a plain fallback, slow zoom-out, none with Reduce Motion) + optional 7-card tour; Settings → About → App tour.
- A-07 / A-08 / A-09 / A-21: onboarding says Can't find your scooter after 30 s with tips and Which scooters work?; While Using now, Always later; plain alert words; one safety line.
- A-10 / A-11 / A-12 / A-13: Load row after 3 rides; hint lines on empty Routes and Stats; Connect on the empty Scooter tab; the card name is the model name.
- A-14 / A-15: one km-left number (KmLeft, the Battery page's real range at the smoothed level): "≈ N km left" under the live battery %, and the voice lines say km left (the % per km rate is no longer spoken; the plain line while learning).
- A-16: ride summary 8 tiles (2 × 4): + Cost (StatsCalc.rideCostIls, a period's rides add up to its Electricity) + km left at the end level.
- A-17: CSV, GPX and Replay file first ask "Hide where this ride starts and ends?"; Hide start and end blanks the location within ~200 m of the first and last point in the shared copy only.
- A-18: "Full ≈ … · learning" until a charging speed is learned or measured. A-24: Settings → About → Credits. A-26: fixed font sizes outside Developer and the live numbers now scale.
- Lab checks u201 (automatic), ui201–ui203 (phone).

## 108.131226.02 — hotfix 02 of batch 8 (owner 18 Nov, on 108.131226.01)

- iOS 26 look (the first Xcode 26 build): no shared glass shell around Home's gear and logo, no scroll edge effects, Home's bar background hidden; the N6-3 fade above the tab bar is removed (it faded the map background into a grey band).
- Place centre and outline editors use the standard map (not satellite); the pin follows the finger (a touch on the pin grabs it, the map holds still).

## 108.131226.01 — hotfix 01 of batch 8 (batch 7 and 8 open items finished)

- N8-1: more lights: recording problem, phone took over, power limit soon, dark before you arrive (offline sun position), rain within 20 min (stored forecast), gear reminder (60 s at the gear's cap); lights that never got a slot are listed on the ride summary.
- N7-4: summary numbers count up during the draw; place pins appear after the line.
- N7-5: charge target (green battery hop), savings milestone hop, real battery icon level, connect / disconnect glyph, backup arrows → green tick, arrival flag wave (plain flag, P-3).
- N7-6: MeshGradient glow on iOS 18.
- N7-7: Insights curve scrub, Battery report ticks, today's bar highlighted on Stats.
- N7-11: live tiles fly into their summary spots (matchedGeometryEffect).
- Xcode 26 build fixes (View.tint clash, main-actor haptics).
- Still open: N7-3 swipe-to-close only from the top bar; N7-5 pin drop and iOS 26 draw-on tick; N7-9 per-place controls (needs an App Group).

## 108.131226.00 — batch 8, due Sun 13 Dec 2026 (in-ride signals)

- N8-1: warning-light strip at the top of the live screen (at most 3, red / amber / blue, red first, nothing when all is fine); it replaces the very hot / hot / disconnected / No GPS / phone battery banners and the No GPS / Offline map chips. At a stop (wheel speed 0 for 1 s) a tap expands an icon into its line. Lights today: motor very hot / hot, disconnected, phone battery low, No GPS, offline map.
- N8-2: the battery tile turns amber at 20 % and red at 10 % (number and thin border, smoothed %); colour-blind mode adds a down triangle.
- N8-3: level-2 lights play one soft tone (draft) once per ride; level-3 warnings stay voice + vibration.
- N8-4: turn-back point in two steps: 1 km before (soft tone + "Turn-back point in one kilometre.") and at the point (ping-ping + "Turn back now to make it back.").
- Owner 17 Nov: speed readings are never discarded (no maximum, no jump check; T03 retired, only a negative value is dropped).
- Guard tests: Batch108Tests.

## 107.061226.00 — batch 7, due Sun 6 Dec 2026 (UI elevate round 2)

- N7-0: CI builds with Xcode 26 (iOS 26 SDK); the app still targets iOS 17.
- N7-1: scooter Live Activity / Dynamic Island: Ready on connect (km left, destination, Start ride / Change, gone after 2 min), Riding ("Recording", grey when GPS is lost), Arrived (End ride / Keep going). Charging adds "Enough for <place> by HH:MM". No alerts during a ride.
- N7-2: Liquid Glass on iOS 26 for the tab bar, map top bars and buttons, layer control, map sheet and Live tiles; the selected tab keeps its solid orange pill; Sunlight mode and Reduce Transparency keep today's look.
- N7-3: zoom transition (iOS 18): Rides, Routes, Places and Stats cards grow into their screens.
- N7-4: the route draws itself after a ride and on its first open; one length curve (0.6–1.8 s) for the line, the replay sound and a speed-following Core Haptics buzz ending in a thump.
- N7-5 (part 1): icon moments: Start squish and morph, connected bounce, cargo hop, gear turn, tab hop, motor-hot wiggle, charging pulse, searching waves, saved bounce.
- N7-6: charging glow on the Battery card, Scooter photo rim and Home charge line; green-gold when full; none in Sunlight mode.
- N7-7 (part 1): drag-to-scrub with callouts on Stats bars and the Battery log; VoiceOver per bar.
- N7-8: one haptic rule (tick / light / success / ride warnings), a light tap on every switch, Settings → Sounds → Vibration mutes them all.
- N7-9: Control Center controls Free ride and Ride to next (iOS 18); Siri / Spotlight "Ride to <place>".
- N7-11 (part 1): the live screen settles into the summary.
- N7-12: the sound family (synth drafts): new connect, ride start, ride end, arrival, ride replay, plugged in, charge full, saved; one warning sound for all three warnings; switch "Charging and saving".
- N7-13: scroll-reactive cards on Rides, Routes and Places.
- Guard tests: Batch107GuardTests, RouteDrawTests, BatteryLogTests (value at).

## 106.291126.00 — batch 6, due Sun 29 Nov 2026 (calmer screens, safer backups)

- N6-1 (B95): Remove place (place screen, with a confirm) keeps its history: it leaves Where to, quick dial, Places, map pins and the matching of new rides; past rides, routes and stats keep the name. Places → Removed places → Put back. Database v5 adds `place.removedAt` (no row is dropped). Bring rider info back copies the shared columns, so an older backup still restores.
- N6-2: the Charge log is now the Battery log: one line from every reading, rides drawn as their smoothed level (no load dips), light fill, dashed average line ("avg 80%", time-weighted), faint 0/50/100 grid and day lines, headline "51% now · 6 charges · 12 rides", Day / Week switch (tap a day to open it), legend behind the ⓘ, no charging bands. Charges less than 15 min apart count as one.
- N6-7: backups always run: to the folder you pick (iCloud Drive or any Files folder) when it can be reached, otherwise to the app's own folder with a quiet note. Settings → Data & backup → Backup shows the folder, the last backup, Choose folder and Back up now. The Home "not backed up" card counts only backups that left the phone.
- N6-3: lists fade out above the floating tab bar; a map screen's numbers fade under the sheet's top edge.
- N6-4: a soft blur behind the tab bar and the map top bars (none in Sunlight mode; a plain fade with Reduce Transparency).
- N6-5: an ⓘ in a section heading opens its explanation in place with a spring; tap again to close.
- N6-6: the selected tab widens and shows its name.
- Reduce Motion turns every new spring into a short fade.
- Guard tests: Batch106StoreTests (AppTests); BatteryLogTests, BackupTargetTests, MotionStyleTests (Core).

## 105.221126.01 — hotfix 01 of batch 5 (the rest of the new-scooter work)

- D2 4b: every alert has its own switch (Settings → Notifications, in groups Rides / Charging / Tips, plus the "always on" expiry line); switch-on, charge and battery-wear alerts check their switch; setup has an "All the alerts" list behind a tap.
- D2 4c: Home's first-ride card says "Switch-on alerts are off" with Open Settings when iPhone notifications are refused. D2 5c: a ride says "Climbs use GPS height only" with Open Settings when Motion is refused. D2 5b: a ride with no GPS says why and how to fix it.
- D2 A2: Start fresh → "Bring rider info back" returns places, routes and old rides from the backup (old rides stay out of the new scooter's battery math). The first setup screen has "Have a backup? Restore".
- D2 7e: the battery size is learned from the calibration ("16 Ah · learned from 5 rides", otherwise "Assumed 16 Ah"). D2 7c: the pack's voltage class (48 / 52 / 60 V) is noted from a rested full reading.
- D2 option C: "New scooter week" in Developer (9 milestones that tick by themselves, an optional note each, a week report to share; no thumbs; it removes itself after the report or 30 days).
- I2: no owner charging speed shown to every rider; new optional "Measure charging speed" on the Battery page (a reminder every 20 min, the rider types the scooter's %, the speed then replaces the learned one). K10: no fixed tyre pressure. K3: one Prices screen (Settings and Stats). K2: Settings → Battery is "Battery setup". T7: the odometer, "Phone took over" and ignored-reading lines are Developer-only. I9: CONCEPT colours text.
- Guard tests: Batch105Tests, LearnedPackTests, VoltageClassTests, NewScooterWeekTests, ChargeSpeedMeasureTests (Core); DataMapGuardTests bring-back (AppTests).

## 105.221126.00 — batch 5, due Sun 22 Nov 2026 (ready for a new scooter, a cleaner app)

- D2 DataMap: one list says which data is the rider's and which is the scooter's (CorckieCore Ownership/DataMap); a guard test reads the real schema and fails the build when a table or column is missing.
- D2 battery door: calibration, health, usual %/km, route battery need and Stats battery read only rides of the current scooter (BatteryDoor); rides of a forgotten scooter still count for times and routes.
- D2 A1 Start fresh (Settings → Data & backup): a backup on the phone first (and in the Files backup folder when one is set), then the scooter's data and estimates start over; "Keep my places, routes and ride times" is a switch; the old pairing is forgotten so setup runs again.
- D2 1a / 1b / 7f: setup shows "RND G100 · 3 km · 87 %" with "Check that your dashboard shows the same km"; the scooter is saved only when Connect is pressed; the closest scooter is chosen (two seconds of listening).
- D2 3a / 3b: the first setup screen says the iPhone will ask for Bluetooth (the link starts a second later); "Bluetooth is off" / "off for CorckieApp" on setup and Home, with Open iPhone Settings.
- D2 2a / 2b / 5a: the Always text matches the iPhone's pop-ups; Home's card follows the real location state (never asked → Allow, refused → Open Settings, While Using, Precise location off).
- D2 4a: "Scooter alerts" on setup. D2 6a: a quiet "Your first ride" card before ride 1. D2 7a: 15 Ah battery size.
- N5-1: Export log can make a privacy-safe file (about 200 m around ride starts, ends and saved places removed, no names, no diary or report files) or "No GPS at all".
- N5-2: thumbs, ride notes and "Right?" rows are gone from the rider's screens; Ride not recorded, Export log and Report a problem live in Developer; the ride page's developer lines show only after the Developer password (T3); data-update-failed text (T4); crash card "Share crash report" (T5); onboarding no longer writes a lab check (T8); read-only wording (T9, T10).
- N5-3: Developer keeps Checks, Results, Crash, Backup, Scooter check, Simulator, Permissions and the moved rows; Sensors, Outside data, Readability, Insights, Accuracy, Ride screen preview, Voice play-all, Voice replay and Route line lab are no longer listed (the files stay).
- N5-4: Developer asks for a password once per launch; only a SHA-256 hash is in the code.
- T2: What's new starts clean (one "Welcome to CorckieApp" card); guard test: no internal codes or test words in WhatsNew.json.
- I1: the SideStore expiry notice and its notification are gone for everyone.
- K1 / C3: "Motor" everywhere (voice, map layer, ride note, ride tiles). C7: "Last chance to turn back in three hundred metres." K4 / K5: "min" and "·" everywhere on Home. K6: "Avg speed" / "Top speed". K8: "Ways". C4/C5: calmer alert texts. C9 / C10: capital letters. I7 / I8: "Detailed readings", "Learning".
- Guard tests: Batch105Tests, DataMapTests, DeveloperGateTests, PrivacyExportTests (Core); DataMapGuardTests, PrivacyTrimTests (AppTests).


## 104.151126.00 — batch 4, due Sun 15 Nov 2026 (one battery number, a calmer voice, Start opens at once)

- N4-16 (D-PR-09): the live dashboard shows the smoothed battery level, the same one the voice, the map's 10 % marks, the arrival line and the 20 / 15 / 10 % warnings use (phone-only rides keep "~ est.").
- N4-9 / B88: one Core rule for the voice's "Battery at N percent" and the map's N% marks: the smoothed level first reaches N (the map replays it over the stored ride).
- N4-10 / B89: no battery lines after "Arrived"; every spoken battery number from the smoothed level.
- N4-15 / B94: the ride's level is saved every few seconds; after a relaunch it is re-seeded from the live reading (its highest in the first 30 s) and no 10 % line at or above it is said again.
- N4-5: "Battery at ninety percent, using two point five percent per kilometre." (rate from 1 km); drain and far-above say "Energy use higher than normal, using … percent per kilometre."; the ride-page note "Energy use higher than normal from km 6, 2.5 % per km."; "Unusual drag, check brakes and tyres." unchanged.
- N4-11 / B90: drain warning ratio 1.5 → 1.8, at least 8 points (was 6), on the smoothed level.
- N4-6 / B86: Start on a quietly recording ride sets it as started by hand: the ride screen opens on the same tick.
- N4-7 / B87: the announced destination is remembered per ride across relaunches; only a change is said.
- N4-14 / B93: no arrival line for rides under 2 km; at the ride end it names the destination announced at the start.
- N4-12 / B91: one start / end / used per ride (RideBatteryEnds): summary, map Battery legend and voice proof agree; end = start − used.
- N4-13 / B92: the ride list's battery used = the ride page's (shown figure, then the ride's own, then rested start − end).
- N4-8: Home's big button reads "Offline" (grey, no action) when the paired scooter is off or out of reach; unpaired keeps "Connect"; "Try again" is gone from Home.
- N4-3 / B84: past the first-read mark without a rise: "No rise in battery use" (others "No clear pattern yet"), "Based on 16 rides", the bar stops at 90 %.
- N4-4 / B85: an early read whose interval touches or crosses 0 says "No clear cost yet", "less than 0.02 % per km for each +1 km/h so far"; never "−0.00".
- N4-1: Place → Move centre (drag the pin or tap the map, Undo, Save).
- N4-2: the riding ask names its street ("Try it on Main St, between First Ave and Second Ave (your Uni route, about 3.5 km in).", rounded points through the cached street helper, offline = the old line), Show where (small map, stretch in orange), "Any 500 m steady at 20 km/h counts."; Settings → Sounds → Riding ask cue (off by default): "Straight ahead: hold twenty for five hundred metres." once on reaching it.
- Guard tests: Batch104Tests (Core).

## 103.081126.03 — hotfix 3 of batch 3, Mon 9 Nov 2026 (Stats chart labels; Run all automatic crash)

- B82: the Stats chart's 10 / 20 / 30 km (rides, time, ₪) values sit in their own column left of the bars; bars no longer cover them.
- B83: "Run all automatic" closed the app inside u44 (UIViewControllerHierarchyInconsistency). Each screen is now drawn in its own hidden window instead of as a child of the app's root screen, and the diary notes each screen drawn.

## 103.081126.02 — hotfix 2 of batch 3, Mon 9 Nov 2026 (rides sometimes not recorded: gather the data)

- B81: Settings → "Ride not recorded" (first row): When did you ride? → Save report; a one-line cause when the app can tell (recorded after all, dropped and why, location not Always, app not running, never connected, connected but no ride). Also saved by itself on an odometer gap.
- B81: Settings → "Export log" (second row): one zip with every table, rides' samples and raw packets, the Report a problem files, the diary and the reports; at most 5 MB, the oldest detail left out first (per ride raw packets, then samples); README lists what was left out.
- B81: a 30-day diary on the phone (app launch / foreground / background / close / memory warning / lock, iOS background exit reasons, Bluetooth events, ride started / really riding / dropped with reason, phone state, all log lines, voice lines). Cleaned daily: diary, error log and reports 30 days, messages 90 days.

## 103.081126.01 — hotfix 1 of batch 3, Mon 9 Nov 2026 (Home during a background ride; two battery % on Home; walk note noise; recording-problem voice)

- B77: Home followed the background ride (stage 1) and showed "Riding" with a dead "Live view" button, hiding Where to, places, load and cards. Home now changes only for a ride the rider sees (confirmed riding or Start pressed), the same rule as the ride screen (B76). Start during a quiet ride confirms it.
- B78: the trip line read "Uni • 28 mins • 36% battery" next to the 99% pill. It is what the trip uses: now "uses 36%" (quick dial and Where to?).
- B80: "Recording problem. Check the app when you stop." only after 2 minutes of a recording problem (owner's drops were ~70 s); short drops stay silent, the ride page still notes them.
- B79: the "Part of this ride was on foot" note only when one push was over 40 m or the pushes add up to 200 m; shorter pushes stay grey on the map and out of the average speed.

## 103.081126.00 — batch 3, Sun 8 Nov 2026 (battery report, smarter battery warnings, fresh readings)

- B73 (every metric): a new scooter connection starts with every value empty (speed, battery, odometer, temperature, current, power); the scooter's 0xFFFF "no temperature yet" clears the value; engine lines only once the motor has pushed on this ride. Fixes "Engine hot, 87 degrees" at the start of a ride (yesterday's last reading).
- B74: place circles of 25 m and 50 m (plus 100–1000 m); the "widen it?" offer steps up from them.
- B75: fuel price typed as 3 digits, the point goes in by itself (8 2 7 → 8.27); electricity keeps the decimal point.
- B76: the ride screen opens at the real ride start (B62: motor power or riding speed for a few seconds) or when Start is pressed; scooter on and wheeled out records quietly in the background.
- V-U1 Level 1: "above usual" starts at the rider's own 9-in-10 line for the route (owner ≈ +12 %; under 10 rides +15 %).
- V-U1 Level 2: urgent "Unusual drag, check brakes and tyres." (high use in two opposite directions), "Battery draining abnormally fast." (% falls 1.5× faster than the energy drawn), "Battery use far above usual, check the scooter." (≈ 2× the worst-ever deviation held over 2 km). Once per ride, again only 20 points worse; Level 1 stays quiet after it; a note on the ride page with thumbs.
- V-U2: battery report (Health tile on the Battery page, or the notice): range on a full battery in km next to health %, graph with km left and % right that you can press, losing km a year, next level, charge cycles, similar-weather note, replacement tip at High, "I replaced the battery".
- V-U2 notices at 90 / 85 (Battery decay detected), 80 / 75 (Battery wearing), 70 and every 5 below (Battery worn); 3-month comparisons in similar weather, the level must hold 2 weeks, baseline after the first 20 cycles; never during a ride; each once.
- Cleanup (D1–D8, D10, D12–D14): 13 unused pieces removed. readyByLine and nextOccurrence stay (the ready-by notification uses them).

## 102.011126.02 — hotfix 2 of batch 2, Mon 2 Nov 2026 (arrival battery = battery now; Scooter tab vs Home battery)

- B71: the voice's arrival battery said your battery now ("Arrival battery now about 60" right after "Battery at 60"). Past rides are stored a row about every 5 seconds, and the arrival maths skipped any gap over 5 seconds, so every past ride seemed to use nothing. One gap limit (6 seconds) now for the live battery, the route's past rides and the voice replay.
- A past ride that seems to use under 1 % while its battery fell 3 % or more is left out of the route's history (the reason goes in the log).
- No arrival battery line while under 5 points are left to use on the route; never the battery now; never the same number as the line just before.
- Voice replay: a ride fails when, halfway, the arrival equals the battery now, or a line repeats a number. Tests now use rides stored like real ones (a row every 5.1–5.3 s, 85 → 48 %, about 340 Wh). Lab checks u191–u192, phone checks ui191–ui192.
- The voice replay over stored rides was never "steady" (it waited for 58 s of readings that come ~5 s apart), so it never said a battery line; it now allows one reading step.
- B72: after "Unplugged" the Scooter tab kept "≈ 84 % estimate when unplugged" while Home said "Last reading 47 %". The next real reading now ends the estimate even with no charge timer running: a scooter connection (not while riding), or the ride after it (its rested start %). That charge then counts as measured for the learned charging speed. With the scooter off, the Scooter tab shows the same last reading and time as Home. Lab check u193, phone check ui193.
- Smaller: check ui184 lists all 15 voice lines.

## 102.011126.01 — hotfix 1 of batch 2, Mon 2 Nov 2026 (voice you can trust)

- H1 / B69: the arrival battery the voice says comes from the energy you use (not the scooter's % that dips on a hill), compared point by point with your past rides on the route. It speaks only after the estimate held for a minute, never in the first 2 km, rounded to 5 ("about 40 percent"), only when 5 points worse than the last number, and never says a higher number after a lower one; better stays quiet, with one "Back on track" at 10 points better. Arriving under 20 %, the point of no return and the every-10 % lines use the same level.
- H2 / B70: late means later than TODAY's estimate (the time the Where-to chip promised), measured at the point you are, from setting off. Only after 3 km and a third of the route, held a minute, 5 minutes or more and slower than most of your rides there; again only 5 minutes later; "Back on time" once. Line: "Running 6 minutes late, arriving at 9:02." The ride screen's arrival time uses the same point-by-point time, so an early red light no longer pushes it later twice.
- H3: a few seconds after setting off on a known route: "Riding to Uni, arriving at 8:56, battery at 98 percent." once (Voice energy updates switch).
- Proof: every spoken line is kept with the numbers behind it; the ride summary (More) shows what was said next to what really happened; Developer → Voice replay runs the new voice over your newest rides and says Pass or what went wrong. Lab checks u186–u189, phone checks ui186–ui190.

## 102.011126.00 — batch 2, due Sun 1 Nov 2026 (the last feature build before the finish)

### Hotfix 02 and bugs
- R1 / note 17: every ride map (and Replay) draws the route as a thin, even line of short pieces, the way you picked in the Route line lab (B); the colour still changes along the ride.
- R2: the Battery layer marks 90%, 80% … where the battery first dropped below each 10 %; a flicker gives one mark, the level you started at gets none.
- R3 / B64: with the scooter off, Home shows your last reading and when it was ("Last reading 66% · 07:49"); the small pill reads "Charge to 100%".
- R5 / B65: charging starts from that same last reading, and the screen shows one full time (the full alert still waits a little longer, as before).
- R4 + B68: the Lock Screen and Dynamic Island count down to your target ("2:16:05") and fill a battery shape (marks at a quarter, half, three quarters) on their own; the frozen % number is gone.
- B67: a ride brought back with Restore discarded ride is written to the backup folder like any ride; a lab check names any ride missing from the export.

### Places and the ride graph
- Note 18: each place is a Circle (default) or an Outline you draw like Google Earth (tap corners, drag one, add one between two, Undo, Reset, area). The outline is used everywhere; you arrive the moment you cross into it; a ride that stays inside is listed as "Around <place>" and stays out of the estimates.
- B66: a trip's usual time and battery show only at the place the trip starts; anywhere else the quick dial shows just the name.
- Note 15: on the ride graph a tap adds or removes a line; a selected chip has ⇄ to switch to its deeper line (Speed ⇄ Accel); hold-to-hide is gone.
- Note 16: pinch with two fingers to zoom time; swipe one finger up or down on the graph to change the scale; drag sideways for the cursor; double tap fits.
- Ride detail works like Replay: under the tiles, Replay's speed strip, play / pause, 1× / 5× / 20× and a dot moving along the route.

### Insights and the battery
- Insights now learn from whole rides (battery per km): what hills, speed, cold and wind cost you, battery use over time, best time to leave. Each says how far it is ("About 7 more rides", "Waiting for colder days"), shows a graph solid where you rode and dashed where data is thin, with a one-line hint. The old speed sweet spot is gone.
- Riding asks: the speed card asks for one small steady stretch ("800 m steady at 35 km/h fills your speed graph") and names a straight, flat part of your usual routes; "Not here" offers another; "Got it ✓" when it is done. These stretches fill only the speed graph.
- Charging speed is learned from your own Plug ins (after 3 charges with a real reading).
- LBP: the app learns where your scooter starts holding back power at low battery, only from rides below 15 %; the Battery page says so, and below it the arrival time counts on slower riding. Nothing changes before such a ride.

### Voice
- V09 voice energy updates while riding: every 10 %, using more than usual, arriving under 20 %, a sharp drop, running late, the point of no return on tight trips, the power limit coming, "Engine hot" at 85 °C and "Engine overheating" at 93 °C (once each), a recording problem, and "Arrived at Uni, battery at 58 percent". Urgent ones at once, the rest at a stop, before a usual stop or on a straight stretch (at most ~2 min later). Switch: Settings → Sounds → Voice energy updates.
- Lab: Developer → Voice messages plays every line once; the ride screen preview speaks them on its made-up ride and shows "Now" or "At a good moment".

## 101.251026.01 — hotfix 1 of batch 1, Mon 26 Oct 2026

- Route colours: the ride map and Replay showed one shade for the whole ride; the line is now drawn with a gradient that follows the route (option A). Developer → Route line lab shows the same made-up ride drawn three ways (A / B / C) to compare on the phone.
- H6 Speed sweet spot: it always said "0 steady stretches" because it wanted readings at most 3 s apart while rides store one every 5 s. It now follows the recorder (up to 12.5 s apart), so it counts your stretches again, for every rider.
- H4 Stats dashed lines: three lines in round steps with the top one about at the tallest bar (13 km → 5 / 10 / 15, ₪99 → 30 / 60 / 90, 7 rides → 2 / 4 / 6), drawn on the same scale as the bars.
- H5 Stats bars: each bar sits centred over its day, wider with a clear gap; the tallest bar is red.
- H1 Ride graph: time zoom is back. Pinch sideways to zoom time, up-down to stretch the values; drag to move along the ride when zoomed in; double tap fits both.
- H2 Ride graph: tap a chip that is already on to see its deeper line: Speed → acceleration, Battery → battery per km, Height → incline; tap again to go back. Hold a chip to hide it.
- H3 Ride graph: the part of the ride shown on the graph is orange on the map, the rest grey; Hills jumps to a climb. Select, Scatter and ✕ are gone.

## 101.251026.00 — batch 1, due Sun 25 Oct 2026

### A · Never lose a ride
- B56: the battery % no longer flips between 100 and 99; a scooter that does not flip is left alone.
- B57: a ride with 300 m or more of real GPS distance is never thrown away after "Phone took over"; it is kept as "Recorded by phone", and Rides has "Restore discarded ride" for the last 30 days.
- B54: a ride's start and end battery use settled readings, so a short hop no longer goes from 99 % to 100 %.
- F-38: a ride ends at your last movement; short stops inside it still count in its time.
- B62: a ride that starts by itself begins at your first real riding movement (motor pushing or faster than walking for ~3 s); pressing Start takes over the ride already running.
- F-39 + ↻ Continue: legs to the destination you picked become one ride where the trip really ended; "↻ Continue to …" when you did not arrive; detours stay out of the estimates; "Includes a 25 min stop, trim it?".
- Notes 12 + 10: bad scooter readings are trimmed, never the whole ride; a warm-up after switching on; trust comes back when the readings look normal; the "ignored" note only when it changed a number.
- B63: a ride is never ended while the scooter is connected and sending, or while GPS shows you moving.

### B · Where to? and places
- F-35: "Riding to Uni, 8 km." when you set off; change the destination with a tap at a stop.
- F-36: pick the destination from the Scooter on notification's buttons.
- B61: never two rows for the same destination in Where to?; routes link to the place they end in.
- B58: the arrival times in Where to? are always worked out from now.
- Note 14: destinations show time and battery: "Home • 30 mins • 27% battery".
- B55: the quick dial is always on Home; a failed read is logged instead of hiding it.
- Places: hold a place card to drag it into a new order; hold and let go for its menu.
- B51: the › of the Places list sits inside each card.
- B60: no parked pin on Home's background map.

### C · Map and ride review
- F-34: a shared energy track spreads the battery used along the ride by the scooter's power; climbs use it.
- F-33: map layers Speed · Hills · Wind · Battery · Temp in one row; tap the active one again for its deeper view (Steady · Grade · Wind cost · Drain · Heating); stops as dots on Speed.
- B59: the route is one smooth gradient line, no blobs at the joins (ride, summary, Replay).
- B52: the ride summary's map takes about half the screen, the tiles sit below it.
- B53: the route draws itself smoothly after a ride; with Reduce Motion the map just fades in.
- Note 11: drag the ride card like Apple Maps: full, default, one line, or hidden with a lip.
- F-31b: after every ride one big Plug in button (one tap starts the charge timer) and a small pill for when to tell you (Battery or Range, with an honest "estimated" time).

### D · Stats and graphs
- Note 8: one clear Stats chart with a title, km · rides · time · ₪ saved, dashed reference lines and a tap to read a bar; Past weeks moves one tap away.
- Note 9: each insight shows how far along it is (early read and confident marks), early reads show a range that narrows; confident insights become their own pages.
- Note 13: one ride graph with chips (Speed by default; battery, height, incline, acceleration, battery per km, power, temperature, wind), linked to the map both ways, hills to select, a scatter view with a plain-words link; a pinch stretches the value scale while the whole ride stays visible.

### E · Release
- F-32: a What's new card after each update ("What's new · 251026"); Settings → What's new keeps every list.
- F-30b: the release name 101.251026.00 everywhere: About, the build stamp, the report zip and the IPA file name.
- F-37: Developer → Ride screen preview plays a made-up ride on the real ride screen (never records).
