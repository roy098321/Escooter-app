# Changelog

One section per release name (VB.DDMMYY.HH: version, batch, due date, hotfix). Plain words, one line per change.

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
