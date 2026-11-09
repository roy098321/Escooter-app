# Changelog

One section per release name (VB.DDMMYY.HH: version, batch, due date, hotfix). Plain words, one line per change.

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
