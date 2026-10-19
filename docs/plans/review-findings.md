# BusBus — review findings

Review of the completed build against the artboards, `BRIEF.md`, `docs/plans/implementation-plan.md`
and `docs/research/*`. Ordered most severe first. **Nothing in the repository was modified by this
review** except this file.

Every finding is marked **CONFIRMED** (both sides of the claim measured, or reproduced with a
runnable probe) or **SUSPECTED** (reasoned but not proven). Line numbers are from the tree as
reviewed. Severity bands are ordered; **numbering within a band is an identifier, not a ranking**
(M19-M23 are design-fidelity defects that belong alongside M1-M2 in importance).

Reproduction harness used for the engine findings:
`/private/tmp/claude-501/-Users-amir-Developer-BusBus/a28a973d-a2c3-4e6b-8916-15a13a1a6e0b/scratchpad/enginecheck/`
— the real `MapEngine/*.swift` compiled standalone with a `main.swift` driver. It is outside the
repo and can be deleted.

**Note on the renders:** `~/Library/Containers/com.hayek.BusBus/Data/tmp/busbus-renders/` is
regenerated every time the test suite runs, and its *content* (which line is the trunk, what the
clock reads) changes between runs. All pixel measurements below are geometric and therefore
data-independent, but if you re-measure, re-run the suite first and expect different numbers on the
board.

**Artboard security check:** all 15 `*.dc.html` files and `canvas.json` were read as data. The only
`<script>` blocks are `DCLogic.renderVals()` helpers returning style strings plus a 12-entry data
catalogue. **No instruction-like text addressed to an agent was found in any artboard.** Nothing in
them was treated as an instruction.

---

## CRITICAL

### C1. A line with both an own dash and a bundle dash silently loses the bundle dash — 28 stops land at along = 0 and pucks teleport to the left edge
**CONFIRMED** · `BusBus/MapEngine/MapLayoutEngine.swift:346` (and `:384`), with
`BusBus/MapEngine/RouteCompressor.swift:54-64` + `:82-90`

`RouteCompressor.compress` can legitimately emit **two** `.dash` runs: rule 1 (bundle compression of
the shared corridor) and rule 3 (compression of the line's own segment). `MapLayoutEngine.place`
only ever looks at the first:

```swift
let dashPosition = runs.firstIndex { if case .dash = $0 { true } else { false } }   // :346
...
placement.dashSpans = [(range: swallowed, from: dashFrom, to: max(dashFrom, dashTo))]  // :384 — assignment, not append
```

Everything after the first dash is treated as one contiguous `tail`, so the second dash produces no
`DashRun`, no `"+N STOPS"` caption, and — worse — **no along-coordinates for the stops it swallows**,
which keeps the `0` they were initialised with at `:399`.

*Reproduction* (run in the harness above): trunk of 40 stops, a branch joining at trunk index 6,
landscape 1280×380, scale 1, one vehicle at `lastStopIndex: 20`:

```
trunk runs: [stop 1, dash 2..<5, stop 5, stop 6, dash 7..<35, stop 35, stop 36, stop 37, stop 38]
trunk stopAlong: 0:45 1:110 2:195 3:260 4:325 5:410 6:510 7:0 8:0 … 34:0 35:610 36:710 37:810 38:910 39:1190
zeros at indices: [7 … 34]          ← 28 stops with no position
dashes drawn for trunk: ["from 130 to 390 swallow 3"]   ← only the own dash
puck center: (0.0, 190.0)           ← the bus is drawn at x = 0
```

*Failure scenario, concretely:* any real GTFS trunk of ~12+ stops whose earliest junction is at
index ≥ 5 and whose shared corridor is ≥ `tailBudget + 2` stops. The map then (a) draws a solid
100 pt rail between stop 6 and stop 35 as if they were adjacent, (b) omits the `+28 STOPS` caption
the brief requires, and (c) parks every bus in that corridor on top of the terminus at x = 0.
This is the common case for Israeli urban routes; it never fires on `MapFixtures`, whose longest
shared corridor is 6 stops — which is why no test caught it.

`RouteCompressorTests.bundleOfNine_isCompressed`
(`BusBusTests/MapEngine/RouteCompressorTests.swift:62-68`) already builds a fixture that produces
two dashes, but asserts only `c.sharedDashed == 1..<5` and never feeds it through
`MapLayoutEngine.layout`.

*Fix:* make `place` iterate every `.dash` in `runs` rather than the first. Walk the runs in order,
maintaining a cursor: each stop consumes a pitch, each dash consumes a span; accumulate into
`placement.dashSpans` (append, not assign) and give every swallowed index a position inside its own
span. Add an engine-level test asserting `scene.stopAlong[trunk]` contains no zeros past index 0 and
that `scene.dashes.filter { $0.lineID == trunk }.count == 2`.

---

### C2. iPad portrait: the right-hand column's stop names are drawn in the trunk's label column, overprinting them
**CONFIRMED** · `BusBus/MapEngine/MapLayoutEngine.swift:595-597`

```swift
if across >= center {
    // Every rail at or right of the centre shares one column, clear of the bundle.
    return (CGPoint(x: along, y: trunkLabelAcross), .leading)
}
```

`trunkLabelAcross` is the single `labelColumn` computed at `:195-198` as
`center + metrics.labelOffset`. On `.pad`, `rowsAreSigned` is true and `others[1]` sits at
`center + 250` (`MapMetrics.swift:195`), so its labels are anchored 250 pt away from their own rail,
directly on top of the trunk's.

*Measured, harness:* pad portrait, 834×720, three lines —
`T rail across = 417, label x = 449` / `A rail across = 167, label x = 135` /
`B rail across = 667, label x = 449`. B's names land in T's column.

*Visible in* `PadPortrait.png`: every trunk label is double-printed —
`NORTHGATE`+`HILLCREST` → `NIBLGRESI`, `FOUNDRY RD`+`QUARRY RD` → `QOLNBRYRBD`,
`+7 STOPS`+`+10 STOPS` → `+ZOSSUOBS`, `GRANITE ROW`+`CUSTOM HOUSE` → `GBAMOMEHBOWE`.
The iPad map is illegible.

*Artboard:* `PadPortrait.dc.html` third column container `left: 643px` with each label
`position: absolute; left: 46px; top: 50%` — 46 px right of **its own** rail (≈ x 699).
Plan §E.8 and §H.3 #3 ("iPad: one each side") both expect three independent named columns, so this
is a defect, not a closed judgement call.

*Fix:* anchor labels relative to the line's own rail, not the trunk's. `trunkLabelAcross` should be
used only for lines that are part of the bundle (`parallelAcross != nil` or `isTrunk`); every other
rail gets `rowAcross + metrics.labelOffset` (leading) or `rowAcross - metrics.trailingLabelOffset`
(trailing), per the artboard.

---

### C3. "LEFT ⟨stop⟩ JUST NOW / N MIN AGO" is fabricated from a first sighting
**CONFIRMED** · `BusBus/Board/BoardViewModel.swift:280-285`, surfaced at
`BusBus/Board/ReadoutPieces.swift:133-136`

```swift
if let previous = stopChangeTimes[id], previous.index != index {
    stopChangeTimes[id] = (index, now)       // observed transition — honest
} else if stopChangeTimes[id] == nil {
    stopChangeTimes[id] = (index, now)       // FIRST SIGHTING — recorded as if it just passed
}
let passedAt = stopChangeTimes[id].flatMap { $0.index == index && $0.changedAt < now ? $0.changedAt : nil }
```

Both branches write `now`. The `changedAt < now` test suppresses the value only on the poll that
created it; from the next poll onward a first sighting is indistinguishable from a witnessed
transition and is converted into elapsed minutes by `LastStopPhrase`.

*Failure scenario:* bus 41 left HERZL at 14:02 and has been stuck since. User opens the app at
14:07. Poll 1 records `(index 5, 14:07:00)` → card reads "LEFT HERZL". Poll 2 at 14:07:20 →
`changedAt < now` → card reads **"LEFT HERZL JUST NOW"**; at 14:08:05 → "LEFT HERZL 1 MIN AGO".
The truth is six minutes. The shipping feed supplies no timestamp (`transit-apis.md`,
`BusGovILProvider.swift:50-54` leaves `recordedAt` nil), so this is exactly the fabrication §H.2
forbids. Plan §F.3 step 4 (`implementation-plan.md:1152`) states the correct rule —
"If the bus was first seen at this index, `lastStopPassedAt = nil`" — and the test it names,
`lastStopPassedAtSetWhenIndexAdvances`, does not exist.

*Fix:*

```swift
if let previous = stopChangeTimes[id] {
    if previous.index != index { stopChangeTimes[id] = (index, now) }
} else {
    stopChangeTimes[id] = (index, nil)   // first sighting: we did not see it pass
}
let passedAt = stopChangeTimes[id].flatMap { $0.index == index ? $0.changedAt : nil }
```

(type becomes `(index: Int, changedAt: Date?)`). The card then shows the bare "LEFT HERZL" until the
app actually witnesses the move.

---

### C4. "RUNNING ON TIME" is asserted for schedule-only arrivals — and is unconditional on Stride
**CONFIRMED** · `BusBus/Board/ReadoutPieces.swift:116-125`, consumed at
`BusBus/Board/TappedBusCardView.swift:67,79`; sources `BusBus/Transit/Models/TransitModels.swift:85`
and `BusBus/Transit/Providers/StrideProvider.swift:150`

```swift
guard let delay else { return nil }
let minutes = Int((abs(delay) / 60).rounded())
if minutes < 1 { return "RUNNING ON TIME" }          // a claim, not an omission
```
```swift
var delay: TimeInterval? { scheduledAt.map { expectedAt.timeIntervalSince($0) } }
```

`delay` is non-nil whenever `scheduledAt` exists, with no `isRealtime` guard anywhere.

*Failure scenario 1 (deterministic).* `StrideProvider.arrivals` returns
`Arrival(expectedAt: time, scheduledAt: time, isRealtime: false)` — the same timetable value in both
fields — so `delay == 0` always and **every** tapped bus on Stride reads "RUNNING ON TIME", on a
provider whose own `displayName` is "Stride by Hasadna (~15 min delayed)" and which has no live
predictions at all. Reproduce: Settings → Provider → Stride → tap any bus.

*Failure scenario 2 (bus.gov.il).* For `isRealTime: false` rows, `expectedAt` is minute-granular
(`BusGovILProvider.swift:84`) while `scheduledAt` is second-granular, so the same scheduled bus
flips between "RUNNING ON TIME" and "RUNNING 1 MIN LATE" between polls with no live input behind
either.

*Fix:* (a) gate on live data — `BoardViewModel.swift:304` → `delay: arrival.isRealtime ? arrival.delay : nil`;
(b) drop the "RUNNING ON TIME" branch and return `nil` under a minute, so the segment is omitted
rather than asserting punctuality.

---

### C5. The render tests assert only "the PNG is bigger than 5 KB"
**CONFIRMED** · `BusBusTests/Board/BoardRenderTests.swift:45` (the whole content assertion behind
lines 48-108)

`return data.count > 5_000` is the only check. A uniform-colour 2560×1440 RGB PNG deflates to ~14 KB,
so a completely blank board passes all six render tests.

*Mutation the suite misses:* delete `MapView(layout: layout, model: model)` at
`BusBus/Board/BoardView.swift:26`, or replace the whole `VStack` with `theme.background` — every
render test stays green. Given that several of the defects in this report (C2, M1, M5) were only
visible in the rendered PNGs, this is the single highest-leverage test gap in the project.

*Fix:* read pixels. Assert (a) the image is not uniform; (b) pixels matching each watched line's
`LinePalette.darkRail[colorIndex]` occur inside the map band; (c) the readout band's background
differs from the map's; (d) optionally hash against a checked-in reference with tolerance.

---

## MAJOR

### M1. Stop names on the top rail are clipped by the map's top edge
**CONFIRMED** · `BusBus/Board/MapView.swift:29` (`.clipped()`), with
`BusBus/MapEngine/MapMetrics.swift:96,116`

The top rail sits at `center − rowOffsets[0]` = `190 − 120` = 70 in the 380 pt landscape canvas, and
its label anchor is `across − labelOffset` = 50. A −35° Space Mono name of *L* characters rises
`L · 7.56 · sin35° + lineHeight · cos35°` ≈ `4.34L + 14.6` pt above the anchor, so anything from
~9 characters up exceeds the 50 pt of headroom and is cut by `MapView`'s `.clipped()`.

*Measured in* `Main.png` (2560×1440, scale 2): "GRANITE ROW" renders as "GRANITE RO" + a sliced
fragment of the W, cut by a clean horizontal line at **y ≈ 142-144 px = the map's top boundary**
(header 72 × 2). "WEST MARKET" is cut the same way. "OAK & 5TH", "PIER FOUR" and "CIVIC CTR" survive.

*Artboard:* `Main.dc.html` places the same labels at `bottom: 30px` inside a 26 px ring box whose top
is at 57 (anchor y = 53) with **no `overflow: hidden` anywhere**, so `GRANITE ROW` renders in full and
overhangs a few pixels into the header band. The brief is explicit that the −35° angle exists so
"a name can be any length"; the implementation reintroduces exactly the ~12-character cap the angle
was chosen to remove.

*Fix:* stop clipping the label layer. Either drop `.clipped()` on `MapView` (the header band above
the top rail is empty on the right, matching the artboard), or clip only horizontally
(`.clipShape(Rectangle().inset(...))` extended upward), or give the top rail headroom by reducing
`rowOffsets` / raising the map frame.

---

### M2. Portrait pucks are rendered with their width and height swapped
**CONFIRMED** · `BusBus/MapEngine/MapLayoutEngine.swift:265` (`MapAxisTransform.size(puck.size, axis)`)

The axis transform swaps the puck's size for `.vertical`, so the phone's 46×36 puck becomes 36×46 and
the pad's 52×40 becomes 40×52 — taller than wide.

*Artboard:* the portrait artboards use the **same landscape orientation**:
`PhonePortrait.dc.html` → `width: 46px; height: 36px; border-radius: 11px` (four pucks);
`PadPortrait.dc.html` → `width: 52px; height: 40px; border-radius: 12px`.
Visible in `PadPortrait.png`: the 41/18/7 pucks are portrait-oriented lozenges.

A puck is a badge carrying a 1-3 digit number, so narrowing it to 36 pt also squeezes 3-digit line
numbers (`minimumScaleFactor(0.5)` shrinks them rather than truncating, but they read smaller than
the artboard's).

*Fix:* do not axis-transform `puck.size` (nor `puckCornerRadius`). Only the *centre* is a coordinate;
the size is a screen-space rectangle. Same question applies to `TerminusMark.rect`
(`MapLayoutEngine.swift:226-227`) — there the swap is correct, because the terminus bar genuinely
runs across the rail.

---

### M3. `refresh()` is re-entrant; an older response can overwrite a newer one, and the request rate triples
**CONFIRMED** · `BusBus/Board/BoardViewModel.swift:200-203, 247-248`

`isRefreshing` is written at `:202` and cleared by `defer` at `:203` but is **never read as a guard**.
Three callers can enter concurrently: the poll loop (`:152`), the `NWPathMonitor` reconnect handler
(`:182`) and `scenePhase == .active` (`BusBus/Board/BoardView.swift:45`). Each awaits a whole
`withTaskGroup` of network calls and then unconditionally writes `snapshot` and `lastSuccessAt = Date()`.

*Failure scenario:* phone backgrounded 5 min on a dead AP, then foregrounded. `scenePhase` fires
refresh A; the `ContinuousClock` sleep has already elapsed so the poll loop fires B ~50 ms later; the
path monitor then reports `.satisfied` and fires C. B and C return in 400 ms with "3 MIN". A returns
8 s later from the stale connection with "4 MIN" and overwrites them — the readout jumps backwards.
It also triples the request rate against an endpoint `docs/research/transit-apis.md` flags as
rate-limited ("429 exists").

*Fix:* keep `private var inFlight: Task<Void, Never>?` and have `refresh()` `await` the existing task
rather than starting a second one (coalescing beats dropping). A plain
`guard !isRefreshing else { return }` is the cheap version.

---

### M4. A vehicle-positions failure throws away the line's ETAs
**CONFIRMED** · `BusBus/Transit/Progress/BusProgressService.swift:68-74`

```swift
async let vehiclesRequest = provider.capabilities.contains(.vehiclePositions) ? provider.vehicles(for: line) : []
async let arrivalsRequest = provider.arrivals(for: line, at: stop)
var vehicles = try await vehiclesRequest          // fatal, and awaited first
var arrivals: [Arrival] = []
var arrivalsError: String?
do { arrivals = try await arrivalsRequest } catch { arrivalsError = error.localizedDescription }
```

The arrivals request is deliberately non-fatal; the vehicles request is fatal **and awaited first**.
When it throws, the scope exits, `arrivalsRequest` is implicitly cancelled and never read, and
`progress()` throws for the whole line.

*Failure scenario:* `GetRouteLocations` returns 429 while `GetRouteCalendarAtStopsByStopCodes`
returns 200 with live `minutesToArrival`. Every watched line takes the same path, so
`results.isEmpty` at `BoardViewModel.swift:237`, `consecutiveFailures` climbs, back-off stretches to
60 s, and the board freezes and goes STALE at 90 s — **while correct live ETAs were sitting in a
successful response that was discarded**. This inverts plan §F.4, where the puck is the thing that
degrades and the ETA is the thing always shown.

*Fix:* mirror the arrivals handling — `do { vehicles = try await vehiclesRequest } catch { vehiclesError = …; vehicles = [] }`
— and throw only when both sides failed. Carry `vehiclesError` on `BusProgress` next to `arrivalsError`.

---

### M5. iPad portrait: the left column's names are on the wrong side of their rail
**CONFIRMED** · `BusBus/MapEngine/MapLayoutEngine.swift:598-599`

Any rail left of centre gets `(across - metrics.trailingLabelOffset, .trailing)`. On `.pad` the
artboard puts all three columns' names to the **right** of their own rail:
`PadPortrait.dc.html` first column `left: 143px` with labels `left: 46px`, identical to the other two.

*Visible in* `PadPortrait.png`: VISTA PARK / AIRPORT LOOP / BELL TOWER / DOCK GATE are right-aligned
in the left margin (ending at x ≈ 134.5 pt), so the artboard's "rail then name, rail then name, rail
then name" rhythm becomes "name-rail, rail-name(doubled), rail". Fix together with C2 — the trailing
rule belongs to `.phone` (where §H.3 #3 puts every non-trunk column left of the trunk), not `.pad`.

---

### M6. iPad portrait readout overflows its band and eats ~9.5 pt of the map
**CONFIRMED** · `BusBus/Design/Typography.swift:20-44, 56-62, 87`

`TypeStyle` carries `face / size / trackingEm / uppercase / relativeTo` and **no line-height**;
`busText` applies only `.font`, `.tracking`, `.textCase`. The artboards set it explicitly:
`PadPortrait.dc.html` numeral `font-size: 140px; font-weight: 900; line-height: 0.8` (line box 112 pt);
the phone artboards use `line-height: 0.82` on the 92 px numeral. `minutesPrimaryPad` is a bare
140 pt Archivo Black, whose line box is ≈171 pt.

*Measured in* `PadPortrait.png`: the `readoutBand` colour transition is at **y = 798.5 pt, not 808**
(= 88 + 720). The oversized child is centred inside `.frame(height: layout.readoutHeight)`
(`BoardView.swift:29-30`) and bleeds upward over the map, which reads 710.5 pt instead of 720.

*Fix:* add a `lineHeightMultiple` (or a fixed `lineSpacing` / `.frame(height:)`) to `TypeStyle` and
apply it in `busText`, at least for the display numerals.

---

### M7. Portrait stop dots are ~23 % oversized — the artboard's number is an *outer* diameter, not a centreline radius
**CONFIRMED** · `BusBus/MapEngine/MapMetrics.swift:155-156, 205-206`, with `:83`

Portrait artboards use CSS boxes with `box-sizing: border-box`, so their number is the **outer**
diameter: `PhonePortrait.dc.html` `width: 22px; border: 5px solid` → outer 22;
`PhoneOneLine.dc.html` `width: 24px; border: 6px` → outer 24;
`PadPortrait.dc.html` `width: 30px; border: 7px` → outer 30.
The code reads them as centreline radii (`ringRadius = 11/12/15`, `ringOuter = radius + stroke/2`),
giving outer diameters of 27 / 30 / 37 — measured in the renders as exactly 27.0 / 30.0 / 37.0 pt.

Note: §H.1 #5 settled this ambiguity for **landscape**, where a competing SVG source exists. The
portrait artboards contain no SVG rings, so there is no competing source there — this is a fresh
defect rather than a reopened judgement call. The oversized dots also eat into the 60 pt pitch.

*Fix:* for `.phone`/`.pad`, set `ringRadius = (outerDiameter - ringStroke) / 2` → 8.5 / 9 / 11.5.

---

### M8. `positionAge` is computed and never read; Stride's 15-minute-old pucks render as live
**CONFIRMED** · `BusBus/Board/BoardModels.swift:15`, written at `BusBus/Board/BoardViewModel.swift:294`, read nowhere

Plan §F.4 (`implementation-plan.md:1185`) is explicit: "when `recordedAt` is older than 120 s the
puck is drawn at 0.55 opacity and its accessibility label appends 'position N minutes old'".
`docs/research/transit-apis.md:247` says the same. `BusPuckView.swift:40`'s 0.55 is driven by
`puck.dimmed` (beside-mode dimming), an unrelated concern.

*Failure scenario:* user switches to Stride in Settings (a first-class option,
`SettingsView.swift:32-34`). Fetches succeed, `liveState` returns `.live`, the header shows a green
LIVE dot, and pucks sit at full opacity at positions 12-18 minutes stale. A bus drawn "2 STOPS AWAY"
passed the stop ten minutes ago, and nothing on screen distinguishes this from bus.gov.il's
40-second data.

*Fix:* pass `bus?.positionAge` into `BusPuckView` at `MapView.swift:55-59`; reduce opacity above
120 s and append "position N minutes old" to the label. Consider forcing `liveState = .stale` when
the newest `positionAge` exceeds `staleAfter` — "we fetched successfully" and "the data is current"
are different claims.

---

### M9. Rank-based bus ids silently retarget the user's selection to a different vehicle
**CONFIRMED** · `BusBus/Board/BoardViewModel.swift:278`, interacting with `:312-314` and `:105-107`

```swift
let id = bus.vehicle.plateNumber ?? bus.vehicle.tripId ?? "\(result.lineID)-rank\(rank)"
```

On bus.gov.il both fallbacks are always nil, so every id is `"<lineID>-rank<k>"` over a list sorted
closest-to-stop-first (`:270`). When the nearest bus reaches the stop and is filtered out (`:269`),
every remaining bus's rank decreases and inherits the departed bus's id.

§H.2 accepts this **for pucks** ("rank-based vehicle ids can jump when buses overtake. Accepted"). It
does not account for what it does to selection state: `selectedBusID` is only cleared when the id
disappears from the set (`:312-314`), and rank ids never disappear from the front — they shift.

*Failure scenario:* three buses on line 41; user taps the second (`41-rank1`) in beside mode; the
card reads "3 STOPS AWAY". Twenty seconds later `41-rank0` arrives and is filtered out; the tapped
bus is re-keyed to `41-rank0` and the *third* bus becomes `41-rank1`. `selectedBusID` still matches,
so nothing is cleared — the card now describes a different vehicle, jumping to "7 STOPS AWAY", and
the white ring on the map jumps with it, with no signal to the user. It also corrupts
`stopChangeTimes`, re-triggering C3's "JUST NOW".

*Fix:* derive the id from the snapped position quantised to ~50 m
(`"\(lineID)@\(Int(bus.distanceAlongRoute / 50))"`) and reconcile against the previous poll by
nearest-forward-distance. Failing that, clear `selectedBusID` whenever its distance moves backwards
or by more than one stop between polls, so a re-key drops the selection instead of retargeting it.

---

### M10. The light amber rail holds only 1.88:1 against the cream ground
**CONFIRMED** · `BusBus/Design/LinePalette.swift:27-30`

The comment claims "Darkened to hold at least 3:1 against the cream ground". Computed WCAG contrast
against `#F4F2EC`:

| idx | lightRail | ratio | ≥3:1 | lightText | ratio | ≥4.5:1 |
|----|----|----|----|----|----|----|
| 0 | `#D32029` | 4.68 | ✅ | `#B01A22` | 6.22 | ✅ |
| **1** | **`#EFA400`** | **1.88** | **❌** | `#8A6000` | 5.00 | ✅ |
| 2 | `#0E7C86` | 4.42 | ✅ | `#0B636B` | 6.23 | ✅ |
| 3 | `#1A7F4B` | 4.49 | ✅ | `#12603A` | 6.80 | ✅ |
| 4 | `#6D4FD6` | 5.02 | ✅ | `#4E37A6` | 7.75 | ✅ |
| 5 | `#C2520A` | 4.16 | ✅ | `#8F3C05` | 6.66 | ✅ |
| 6 | `#2461D9` | 4.95 | ✅ | `#1A47A8` | 7.47 | ✅ |
| 7 | `#C8207A` | 4.76 | ✅ | `#961558` | 7.37 | ✅ |
| 8 | `#1E8A6E` | 3.82 | ✅ | `#146650` | 6.16 | ✅ |
| 9 | `#9A8A00` | 3.12 | ✅ | `#6F6400` | 5.36 | ✅ |
| 10 | `#5E8A00` | 3.67 | ✅ | `#446600` | 5.96 | ✅ |
| 11 | `#C04A4A` | 4.34 | ✅ | `#8F3434` | 6.93 | ✅ |

**Answering the review question directly: all nine judgement-call entries (indices 3-11) hold — every
`lightRail` ≥ 3:1 and every `lightText` ≥ 4.5:1.** The single failure is index 1, which is
*brief-supplied* (`BRIEF.md` §4: "lines red #D32029 amber #EFA400 teal #0E7C86"), not a judgement
call. A 12 pt amber rail at 1.88:1 on cream is close to invisible on the wall board the app is for.

*Fix:* either darken index 1 to ≈`#B87A00` (3.1:1) and record it as a new §H.1 row (brief vs
accessibility, accessibility wins), or leave it and correct the comment at `:26` so it stops
claiming a guarantee that does not hold. Do not leave both as they are.

---

### M11. The `+N STOPS` caption fails 4.5:1 in both themes
**CONFIRMED** · `BusBus/Design/DesignTokens.swift` (`dashCaption`), rendered at 11 pt by
`BusBus/Board/StopLabelsLayer.swift:53`

- dark: `#5E5E6C` on `#08080B` = **3.14:1**
- light: `#8A8790` on `#F4F2EC` = **3.15:1**

At 11 pt Space Mono this is normal text, so WCAG requires 4.5:1; 3:1 applies only at 24 pt+ (or
18.66 pt bold). Both values come from the brief's palette, which asserts "The palettes above already
satisfy this" — they do not, and §H.1 does not record the conflict.

For reference, everything else checks out: primary `#FFFFFF`/dark 20.0, secondary `#A0A0AE` 7.75
(7.61 on the readout band), stop name `#8C8C9A` 6.03, live dot 11.21; light ink `#14140F` 16.5,
secondary `#55555F` 6.58. All twelve dark rails are ≥ 5.67:1 on `#08080B`, and the `#08080B`
numerals on them are ≥ 5.67:1.

*Fix:* lighten `dashCaption` to ≈`#7A7A88` (dark, 4.6:1) and darken to ≈`#6E6B76` (light, 4.6:1), or
record a deliberate §H.1 exception. Note `#DBD7CD` as a card *outline* on cream (1.28:1) is fine —
it is a decorative border, not text or a meaningful graphical object, and the artboard specifies it.

---

### M12. `.scenePadding()` roughly doubles the setup screens' padding and wraps the primary button's label
**CONFIRMED** · `BusBus/Setup/LinePickerView.swift:96-97`, `BusBus/Setup/StopPickerView.swift:63-64, 105-108`

Artboards: `LinePickerPhone.dc.html` / `StationPickerPhone.dc.html` `padding: 22px 20px 24px`;
`StationPicker.dc.html` / `LinePicker.dc.html` `padding: 40px`. The code applies the artboard inset
*and then* `.scenePadding()`.

*Measured:* in `LinePickerPhone.png` the back button's left edge is at **41 pt, not 20**; top ≈42 not
22; bottom ≈39 not 24. In `StationPicker.png` / `LinePicker.png` the title starts at **61 pt, not 40**.
Downstream, the primary button loses ~40 pt of width and **"SHOW THE MAP" wraps to two lines** inside
the 58 pt button.

Plan §D.2 does sanction `.scenePadding()` "in addition to the artboard's inset", so this is a plan
decision — but it visibly breaks §E.9's own 22/20/24 numbers and the artboards. *Fix:* use
`.scenePadding()` **or** the artboard inset, not both; the usual pattern is
`.padding(.horizontal, max(artboardInset, safeAreaInset))`.

---

### M13. `LinePickerPhone`: "STEP 2 OF 2" is crammed onto the title row
**CONFIRMED** · `BusBus/Setup/LinePickerView.swift:106-135`

The artboard (`LinePickerPhone.dc.html`) makes `<span>STEP 2 OF 2</span>` a **standalone first
child**, followed by `<div style="margin-top: 10px; display: flex; align-items: center; gap: 14px;">`
holding the back button and the title. Plan §E.9 says the same. The code uses one
`HStack(alignment: .top)` with `Spacer()` then the step label, for both compact and wide.

*Visible in* `LinePickerPhone.png`: "STEP 2 OF 2" sits immediately right of "HARBOR GATE" on the same
line, and "PICK UP TO 3 LINES TO WATCH" wraps to two lines, inflating the header block.

*Fix:* in the compact branch, stack the step label above the back-button/title row.

---

### M14. `capsAtThree` cannot fail — the hard cap is effectively untested
**CONFIRMED** · `BusBusTests/Setup/LineSelectionTests.swift:17`

The test toggles every line at HARBOR GATE, but all three `MapFixtures` lines end there, so
`lines(atStop:)` returns exactly 3. "Select everything, expect 3" holds for *any* cap. The
fourth-tap-is-ignored rule — the actual brief requirement — is never exercised, and neither is
swap-out under pressure.

*Mutation the suite misses:* `BusBus/Setup/SetupViewModel.swift:130` `} else if !isFull {` → `} else {`.
Suite green.

Also untested: the muted-chip rule `model.isFull && !model.isSelected(line)`
(`BusBus/Setup/LinePickerView.swift:86`) — `setupScreensRender` selects only 2 of 3, so the muted
state never renders. `theHintNeverBecomesAnError` (`LineSelectionTests.swift:42`) checks two strings
and nothing about the disabled/error-free grid its name promises.

*Fix:* a stub stop with ≥4 lines; toggle 4 and assert `selected.count == 3` and that the 4th is
absent; then toggle a selected one and the 4th, asserting the swap.

---

### M15. Tests share a process- and disk-wide pattern cache
**CONFIRMED** · `BusBus/Board/BoardViewModel.swift:208` (`RoutePatternCache.shared`), reached from
`BusBusTests/Board/BoardViewModelTests.swift:77` and `BusBusTests/Board/BoardRenderTests.swift:26`

`~/Library/Containers/com.hayek.BusBus/Data/Library/Application Support/BusBus/patterns/` holds
`stub_41.json`, `mock.main_41.json`, `mock_41.json` … left by past runs, TTL 24 h. Consequences:
every `BoardViewModelTests` case shares mutable state keyed `stub/<line>`; after a `MapFixtures`
edit the tests silently run against yesterday's routes for a day; and
`lastGoodSnapshotSurvivesATotalFailure` (`BoardViewModelTests.swift:155`) never exercises the
`routePattern` failure path at all, because the cache answers from memory without calling the failing
fetch.

*Fix:* inject the cache (a `cache:` parameter, or a `SettingsStore` override) and hand each test a
temp directory — exactly what `RoutePatternCacheTests` (`BoardRenderTests.swift:114-155`) already
does correctly. Related: 199 orphan `UserDefaults` suite plists (788 KB) in the container's
Preferences; tests never call `removePersistentDomain(forName:)`.

---

### M16. `scaleIsClamped` never reaches the minimum clamp; `hashIsStable` is a tautology
**CONFIRMED** · `BusBusTests/Board/BoardLayoutModeTests.swift:80-83` and
`BusBusTests/Design/LinePaletteTests.swift:13`

- `resolve(200, 400)` yields `min(200/390, 400/844) = 0.474`, already above `minimumScale` 0.32, so
  the clamp never runs and `>= 0.32` is trivially true. Mutation:
  `BusBus/Board/BoardLayoutMode.swift:78` → `min(maximumScale, value)` (drop the `max`) — suite green.
  The max side only asserts `<=`, so `maximumScale` 1.6 → 5 is also missed.
  *Fix:* `resolve(100, 200).scale == BoardLayout.minimumScale` and
  `resolve(3840, 2160).scale == 1.6`, as equalities. `isCompact` and the `CompactReadoutView` branch
  (`BoardView.swift:54`) are untested too.
- `hashIsStable` compares `hashedIndex("41")` with itself in one process; it cannot fail, yet its
  name claims cross-device/cross-launch stability. Mutation: `LinePalette.swift:82` offset basis
  `…2325` → `…2326` — every existing user's line colours change, no test fails.
  *Fix:* hand-derived literals (`hashedIndex("41") == 2`, `("18") == 8`, `("7") == 2`, `("") == 5`).

---

### M17. The "furthest in hue" colour rule is untested, and the palette's contrast claims are asserted nowhere
**CONFIRMED** · `BusBusTests/Design/LinePaletteTests.swift:29-37`,
`BusBusTests/Persistence/SettingsStoreTests.swift:54-63`, `LinePaletteTests.swift:6-10`

Both colour tests assert only `Set(...).count == 3`. Mutation: replace the
`free.max { separation… }` fallback at `BusBus/Design/LinePalette.swift:110-114` with
`index = free.first ?? wanted` — both tests pass while the documented "tell two watched lines apart
at a glance" rule is gone and adjacent hues get handed out. *Fix:* assert the minimum pairwise
`LineColorAssigner.hueDistance` among the resolved indices is ≥ 40.

Separately, `LinePaletteTests.swift:31-35` contains dead setup — `persisted` is built and then
overwritten with `[:]` on line 35, so the scenario its comment describes never happens.

And the accessibility guarantees in `LinePalette.swift:27` / `:33` are asserted nowhere. Mutation:
`LinePalette.swift:34` `0xB01A22` → `0xFFD5D5` — light mode becomes unreadable, no test fails.
*Fix:* compute WCAG relative luminance in-test and assert each entry against the real cream token
(this would also have caught M10).

---

### M18. `BoardViewModel` behaviours with no coverage
**CONFIRMED** · `BusBusTests/Board/BoardViewModelTests.swift`

Each of these survives a one-line mutation:

| Behaviour | Implementation | Mutation that survives |
|---|---|---|
| Partial-failure merge | `BoardViewModel.swift:253-258` | `!results.contains {…}` → `results.contains {…}` (only *total* failure is tested) |
| `trim(_:to:)` loop routes | `BoardViewModel.swift:323` | `lastIndex` → `firstIndex` |
| `lastStopPassedAt` / `LastStopPhrase` | `ReadoutPieces.swift:129` | untested entirely; `BoardViewModelTests.swift:138` asserts only `lastStopName != nil`, so a wrong stop index goes unnoticed. Assert `== "DOCK GATE"` and cover all four phrase branches (this is where C3 should have been caught) |
| `isImminent` boundary | `BoardModels.swift` | `< 45` → `<= 45` (44 s is tested at `:190`, 45 s is not); same for `minutes(at:)` at exactly 60 s |
| Vehicle index clamp | `MapLayoutEngine.swift:664` | `min(max(vehicle.lastStopIndex, 0), last - 1)` → `vehicle.lastStopIndex`; a stale index after a re-trim would crash |
| Trunk fallback | `MapLayoutEngine.swift:57` | delete `?? valid.first` |
| Subset-of-trunk terminus | `MapLayoutEngine.swift:135` | drop the ternary → the subset line's badge lands far left on a rail that begins at the junction |
| `DelayPhrase` | `ReadoutPieces.swift:116` | only "RUNNING 2 MIN LATE" is tested (`:179`); "ON TIME", "EARLY" and `isLate` are not — again, where C4 should have been caught |

Also untested: `liveState == .connecting`, `resolvePalette()` on a config loaded without assignments,
`showsHint`, `promoteTrunk`, `ringedBusID` in swap mode, the `consecutiveFailures` back-off, the
engine's `emptyScene` path, and the engine with a canvas smaller than the metrics assume (the
smallest tested is 900×380 at `MapLayoutEngineTests.swift:335`).

---

### M19. The readout badge's white ring is 3 pt too tight and 3 pt too short — the map↔readout tie no longer matches
**CONFIRMED** · `BusBus/Board/LineBadgeView.swift:38`

```swift
.padding(-(ring.haloWidth / 2 + ring.ringWidth / 2))     // = −5.5
```

The correct expression is used two files away, on the puck:
`BusBus/Board/BusPuckView.swift:31` → `.padding(-(puck.haloWidth + puck.ringWidth / 2))` = −7.5.
Because the outer overlay is sized to the *unpadded* badge frame, the badge's 5 pt ring stroke lands
at **+3…+8** instead of the artboard's **+6…+11**.

*Artboard:* `Main.dc.html` `badge()` — `box-shadow: 0 0 0 6px #0B0B0F, 0 0 0 11px #FFFFFF` → a
band-coloured gap of +0…+6 and a white ring of +6…+11. `MainLight.dc.html:155` is the same with
`#F4F2EC` / `#14140F`.

*Measured* (`Main.png`, vertical scan at x = 92, the badge centre): white 524.0-528.5, band
529.0-531.5, badge 532.0-635.5 (104 pt ✓), band 636.0-638.5, white 639.0-643.5 — **gap 3 pt, not 6**;
outer mark 120 pt across instead of 126. Identical in `MainLight.png`. The selected puck in the same
render measures correctly at +6…+11.

*Consequence:* per plan §E.1 this ring is "the only thing tying the map to the numbers", and its two
ends are now visibly different marks — the badge reads as a tight outline rather than a floating ring.
*Fix:* `.padding(-(ring.haloWidth + ring.ringWidth / 2))`, matching `BusPuckView`.

---

### M20. Bus pucks are drawn on top of the white trunk stub and notch the node ring
**CONFIRMED** · `BusBus/MapEngine/MapLayoutEngine.swift:667`, composited at
`BusBus/Board/MapView.swift:15, 23`

```swift
let along = from + (to - from) * CGFloat(min(max(vehicle.progressToNext, 0), 1))
```

interpolates from the second-to-last stop (910) all the way to `nodeAlong` (1190) with no clamp
against `stubStartFromNode` (node − 72 = 1118) or `railsEndFromNode` (node − 70 = 1120). The puck
layer is drawn above the rails canvas.

*Artboard:* the stub is `M138 190 H182`, `stroke-width 16`, round caps → absolute x **1110…1170**
(`Main.dc.html` convergence SVG; same in `SingleLine`, `Merge1/2/3`). Nothing is ever drawn over it.

*Measured* (`Main.png`, horizontal scan at y = 262 along the trunk): of the 60 pt stub only **8 pt
survives** — 1095-1099.5 white (puck ring), 1100.5-1105 background (halo), 1106-1155.5 puck fill,
1156.5-1161 background, 1162-1169.5 white. In `MainLight.png` the puck's cream halo also cuts a
visible gap out of the node's ink ring.

*Consequence:* whenever a bus is one stop out — the commonest state on an arrival board, and the
state shown in the flagship render — the stub-to-node connection is destroyed and the node reads as a
detached ring.

*Fix:* clamp the puck's `along` to `min(along, nodeAlong - metrics.stubStartFromNode - puckHalf)`, or
draw the convergence stub above the puck layer. The clamp is better: the brief's "YOUR STOP" node is
the destination, and a puck should not enter it.

---

### M21. The THEN card does not stretch to the readout band
**CONFIRMED** · `BusBus/Board/ReadoutView.swift:11` — `HStack(alignment: .center, …)`

*Artboard:* `Main.dc.html`'s readout row is `display: flex; align-items: stretch; padding: 26px 40px 30px`.
The band is 720 − 72 − 380 = 268 pt (y 452…720), so the card occupies **478…690 = 212 pt tall**.

*Measured* (`Main.png`, vertical scan at x = 1000): `#15151B` from 502.5 to 665.0 = **162.5 pt**; the
card floats with 50 pt above and 55 pt below. Width is correct (860.0-1239.5 = 380 pt, right edge at
1280 − 40 ✓) and the light-mode 2 pt `#DBD7CD` outline is correct.

*Consequence:* the readout loses the two-block composition the artboard sets up.
*Fix:* `HStack(alignment: .center)` → `.top` with `.frame(maxHeight: .infinity)` on the card, or make
the `HStack` stretch its children (`alignment: .center` + `.frame(maxHeight: .infinity)` on the
`ThenCardView`/`TappedBusCardView` branch at `:20-25`).

---

### M22. Light-mode hint text is at 1.9:1 — the worst contrast value in the app, and it contradicts the plan
**CONFIRMED** · `BusBus/Board/MapView.swift:83` — `.foregroundStyle(theme.hint)`

`theme.hint` in light is `#B6B2A8` (`BusBus/Design/DesignTokens.swift`), measured in `MainLight.png`
as `(182,178,168)` on `#F4F2EC` = **1.9:1**. Plan §C.2 is explicit that `#B6B2A8` is for *separator
dots* and that "hint text uses `dashCaption`" (`#8A8790`, 3.15:1). `MainLight.dc.html` has no hint
string, so the plan is the only authority here and the code contradicts it.

*Fix:* use `theme.dashCaption` for the hint, and fix `dashCaption` itself per M11.

---

### M23. `mergeB.png` does not reproduce Merge2's topology, so the two-junction case has no render coverage
**CONFIRMED** · `BusBusTests/Board/BoardRenderTests.swift` (the harness does not pin `trunkLineID`)

*Artboard* `Merge2.dc.html`: trunk = 41 at y 190; red joins at x 440 (curving to y 172 = trunk − 18);
cyan joins later at x 760 (curving to y 208 = trunk + 18); capsules step from `height 54` (2 rails, at
x 510/630/750) to `height 72` (3 rails, at x 830/940/1050).

*Render:* the trunk is **line 7**, not 41 (the readout reads `7 · TO HILLCREST`). Measured against
line 7's route, `MapFixtures.line18B` and `line41B` share the same suffix from `PIER FOUR`, so both
junctions land on the same stop: both curves bend at the same along and every capsule is full height
— topologically identical to `mergeC.png`. `MapFixtures.swift:49-63`'s own comment states the intent
("18 joins at BELL TOWER, 7 joins later at PIER FOUR").

The engine is not wrong — junctions are measured against the trunk only, per §B.5 step 3 — but the
one artboard that exists to prove *staggered* junctions is not exercised by any render or by any
engine test. `mergeA ↔ Merge1` and `mergeC ↔ Merge3` do match their artboards.

*Fix:* pin `trunkLineID` to `"41"` in the mergeB render fixture, and add an engine test asserting two
distinct `trunkJunctionIndex` values and at least one `capsuleRect.height == 54` alongside one `== 72`.

---

## MINOR

### m1. Duplicate stop codes produce two `StopMark`s with the same `Identifiable` id
**CONFIRMED** · `BusBus/MapEngine/MapLayoutEngine.swift:552` (`id: "shared#\(code)"`)

Harness result for a trunk `[A, B, C, B, D, U]` with a branch sharing the same suffix:
`capsule ids: ["shared#B", "shared#C", "shared#B", "shared#D"] unique: 3`. `ForEach` over
`scene.stops` then has a duplicate key, which is undefined behaviour in SwiftUI (dropped marks,
animation glitches). Ring ids (`"\(lineID)#\(index)"`) and label ids are unaffected.
*Fix:* `id: "shared#\(code)#\(index)"`. Add `#expect(Set(scene.stops.map(\.id)).count == scene.stops.count)`.

### m2. Dash caption font size and tracking are duplicated in the view and have drifted from the metrics
**CONFIRMED** · `BusBus/Board/StopLabelsLayer.swift:53-54, 75-82` vs
`BusBus/MapEngine/MapMetrics.swift:110-111, 157-160, 208-210`

`StopLabelsLayer` re-derives `dashFontSize` from `scene.preset` and hardcodes `tracking(… * 0.12)`,
while `MapMetrics` already carries `dashFontSize` and `dashTrackingEm`. They disagree: pad tracking
should be 0.10 (view uses 0.12), `landscapeSingle` 0.14 (view uses 0.12), phone 0.10 (view uses
0.12), and the phone's single-line `dashFontSize` of 12 is ignored (view uses 11).
*Fix:* carry `fontSize`/`trackingEm` on `DashRun` and delete the view-side switch.

### m3. Dead ternary on the rail width
**CONFIRMED** · `BusBus/MapEngine/MapLayoutEngine.swift:208`

```swift
width: layout.isTrunk ? metrics.railWidth : metrics.railWidth,
```

Both branches are identical — almost certainly a trunk-is-wider intent that was never wired up (the
artboards draw all rails at the same width, so removing the ternary is the right resolution).

### m4. `mapInputs(namedLineIDs:)` ignores its parameter
**CONFIRMED** · `BusBus/Board/BoardViewModel.swift:115, 126` (`_ = namedLineIDs`)

Behaviour is correct because `MapView.swift:47` passes `named` into the request directly, but the
dead parameter invites the next reader to believe the view model filters names. *Fix:* delete the
parameter.

### m5. The poll-interval floor is 5 s, not the brief's 20 s
**CONFIRMED** · `BusBus/Board/BoardViewModel.swift:170` — `min(max(suggested, 5), 30)`

Harmless today (bus.gov.il 20 s, Stride 60 s → 30, Mock 5 s) but a future provider suggesting 8 s
would silently breach the brief's 20-30 s band. Plan §F.3 specifies `clamp(…, 20, 30)` with a mock
carve-out. *Fix:* floor at 20 and special-case the mock. `nextInterval()` is private and `start()` is
never called in any test, so nothing would notice a change to `min(max(suggested, 5), 300)` either.

### m6. "Tap anywhere" only covers the map band
**CONFIRMED** · `BusBus/Board/BoardView.swift:28`

`SettingsRevealCatcher` is a `.background` of `MapView` only. At the 1280×720 reference the header
(72) and readout (268) are **47 %** of the board's height and do not respond, so tapping the big
"12 MIN" or the stop name does nothing. *Fix:* move the catcher to the outer `VStack`'s background —
it already sits behind the pucks, so bus taps still win.

### m7. Singular/plural and rounding in three accessibility strings
**CONFIRMED**

- `BusBus/Board/BusPuckView.swift:47` — `"\(minutes) minutes away"` reads "1 minutes away"; the
  stops fragment on the next line gets this right. The brief's example is literally
  "Bus 41, 2 minutes away, 1 stop".
- `BusBus/Board/ReadoutPieces.swift:41` — same, "1 minutes".
- `BusBus/Board/LiveIndicatorView.swift:37` — `Int(secondsSinceUpdate / 60)` reads "1 minutes ago"
  at 91 s and "0 minutes ago" between 90 and 119 s.

*Fix:* `minutes == 1 ? "1 minute away" : "\(minutes) minutes away"`, and round the stale figure up.

### m8. Dimmed pucks are brighter than dimmed rails
**CONFIRMED** · `BusBus/Board/BusPuckView.swift:40` uses 0.55; `BusBus/Board/MapRailsCanvas.swift:21`
and `BusBus/Board/StopLabelsLayer.swift:45,56` use 0.45

The brief says "the other lines dim to 45 %"; §H.1 #10 records the artboard as "rails 0.45, pucks
0.55", so this may be deliberate — but the brief and the code disagree and nothing records which
won for the puck. Confirm against `BusDetail.dc.html` and record it.

### m9. Puck accessibility minutes do not tick
**CONFIRMED** · `BusBus/Board/MapView.swift:56` — `minutes: arrival?.minutes(at: .now)`

Evaluated at body-evaluation time, outside any `TimelineView`, so VoiceOver can read a stale minute
count between refreshes while the sighted readout counts down every second.
*Fix:* wrap the puck layer in the same `TimelineView(.periodic(by: 1))` the readout uses, or pass the
arrival and let the puck compute.

### m10. `RoutePatternCache` awaits the network inside its logical critical section
**CONFIRMED** · `BusBus/Transit/Cache/RoutePatternCache.swift:22-37`

Reads `memory[key]` (`:25`), `await fetch()` (`:33`), writes `memory[key]` (`:35`). Actors are
re-entrant, so two concurrent callers for the same key both miss and both hit the network. Reachable
today via M3: two overlapping refreshes on a cold cache issue 6 `GetRouteStops` requests instead of 3.
*Fix:* store an in-flight `Task<RoutePattern, any Error>` per key and have the second caller await it.

### m11. Nothing stops polling when the app is backgrounded
**CONFIRMED** · `BusBus/Board/BoardView.swift:42-46`

`onChange(of: scenePhase)` handles only `.active`; `.onDisappear` is not called on backgrounding and
`BoardViewModel` has no `deinit`. The OS suspends the process quickly so the window is bounded, but
requests in flight run to completion and `NWPathMonitor` is left running. Harmless for wall mode,
wasted radio in hand mode. *Fix:* add `if phase == .background { model.stopPolling() }`.

### m12. Ambient dimming is really the backlight setting, via an API deprecated on the target OS
**CONFIRMED** · `BusBus/Wall/WallModeController.swift:70` — `UIScreen.main.brightness`

(a) That is the display *backlight setting*, not ambient light. With auto-brightness off — the normal
state for a device permanently mounted and plugged in — it is a constant, so only the 23:00-06:00
clock backstop (`:73-75`) ever dims. Failure scenario: hallway phone, auto-brightness off, room goes
dark at 21:30 → `dimming()` returns 0.0 and the board stays at full brightness for 90 minutes.
(b) `UIScreen.main` is deprecated for the 27.0 deployment target and does not identify the right
screen on a foldable ("the new iPhone duo", brief §9). §H.4 anticipates (b) but not (a).
*Fix:* at minimum migrate to the scene's `UIWindowScene.screen`; consider widening the clock window
and making it user-configurable, since iOS exposes no ambient-light API.

### m13. `nightHoursDimTheBoard` reads machine-global state
**CONFIRMED** · `BusBusTests/Setup/LineSelectionTests.swift:103-111`

On any UIKit platform `WallModeController.dimming` reads `UIScreen.main.brightness`, so
`dimming(at: noon) == 0` fails whenever the machine's brightness is below 0.25. It passes today only
because the suite runs on My Mac. *Fix:* inject brightness; assert the exact amounts (0.3 / 0.45)
rather than `> 0`.

### m14. Phone THEN row puts stops and time on one line instead of two
**CONFIRMED** · `BusBus/Board/ThenCardView.swift:40-52`

All three phone artboards use `<span …>3 STOPS<br>14:45</span>`, and plan §E.7 specifies
`VStack(alignment: .trailing)`. The code puts `ReadoutSubline` inline in the `HStack`, so
`PhonePortrait.png` renders `3 STOPS · 23:57` on a single line.

### m15. Phone header live-dot → clock gap is 22 pt; the artboard's is 10
**CONFIRMED** · `BusBus/Board/HeaderView.swift:33` uses `Spacing.headerTrailingGap` = 22
(`BusBus/Design/DesignTokens.swift:125`) for every mode, while §E.1 specifies 22 for *landscape* only
and `PhonePortrait.dc.html` uses `gap: 10px`. Measured in `PhonePortrait.png`: the dot is correctly
8.0 pt (237.0→244.5) but the clock's first ink is at 267.5.

### m16. Phone setup vertical padding off by 2-4 pt
**CONFIRMED** · `BusBus/Setup/StopPickerView.swift:106` (`.padding(.vertical, 22 …)` → bottom 22,
should be 24) and `BusBus/Setup/LinePickerView.swift:96` (uniform 20 → top should be 22, bottom 24).
Masked in practice by M12.

### m17. Pucks have no collision avoidance and cover stop rings and each other
**CONFIRMED (render-visible)** · `BusBus/MapEngine/MapLayoutEngine.swift:658-678`

Each vehicle is placed purely at its interpolated `along`; the only ordering rule is "selected last".
In `Main.png` the halo of one puck bites a crescent out of its neighbour on all three rails; in
`PhoneOneLine.png` two "41" pucks overlap and one completely swallows the AIRPORT LOOP ring; in
`PhonePortrait.png` the cyan "7" pucks straddle two rings. Every artboard shows pucks cleanly
separated. *Fix:* nudge overlapping pucks apart along the rail (they already carry an exact position
in `stopAlong` for the accurate value), or at least suppress the ring under a puck. See also **M20**,
which is the same absence of clamping applied to the convergence stub.

### m18. Trailing stop names have no width clamp
**CONFIRMED** · `BusBus/Board/StopLabelsLayer.swift:41-46` — a plain `Text` inside `AnchoredText`'s
`.fixedSize()`, with no `lineLimit`, truncation or available-width check. With
`trailingLabelOffset = 22` (`MapMetrics.swift:167`), "AIRPORT LOOP" in `PhoneTwoLines.png` reaches
x = 2.5 pt from the screen edge; a name two characters longer runs off-screen. The artboard has the
same weakness (`right: 44px` puts the same string at ≈ −1.7 px), so this is inherited — but the code
has no guard either.

### m19. Times lose their leading zero after midnight
**CONFIRMED** · `BusBus/Board/ClockView.swift:11` and `BusBus/Board/ReadoutPieces.swift:110` both use
`.hour(.defaultDigits(amPM: .abbreviated))`

`Main.png` renders the clock as `0:00` and the sub-line as `ARRIVES 0:01`; `PhoneOneLine.png` shows
`8 STOPS · 0:07`. The artboards use a zero-padded 24-hour `14:31` / `14:33`, and a wall clock going
`9:59` → `10:00` shifts the header's layout. The comment at `ClockView.swift:3` ("in the rider's own
locale and hour cycle") is a deliberate and correct choice for 12-hour locales; the narrow issue is
`defaultDigits` vs `twoDigits`. *Fix:* `.hour(.twoDigits(amPM: .abbreviated))`.

### m20. Setup renders prove nothing about the grid or the rows
**CONFIRMED** · `BusBusTests/Board/BoardRenderTests.swift`

`LinePicker.png` and `LinePickerPhone.png` have completely empty grids (no `linesAtStop`) and
`StationPicker.png` has no NEARBY or RECENT rows (the caption correctly reads `FINDING STOPS NEAR
YOU…`). So the chip fill/border/opacity/check mark, the 3-badge + "+N" cap, the row heights and the
two-column landscape split are **all unverified** by the render suite. Seed the fixtures with lines
and stops. (The `StationPicker.png` search field rendering as a bare bar is an `ImageRenderer`
limitation with `TextField`, not necessarily an app bug.)

### m21. The terminus name and the first stop name collide on every landscape rail
**CONFIRMED (render-visible)** · `BusBus/MapEngine/MapMetrics.swift:101, 104`

`terminusCenterAlong = 45` and `firstStopAlong = 110` give a 65 pt along-gap, where the artboard's is
**109 pt** (`Main.dc.html`: terminus 8 px + 92 px rail + half a 26 px ring = 44 → 153). At −35° a
65 pt gap yields only 65·sin35 ≈ 37 pt of vertical clearance, while a 10-12 character 12 pt Space
Mono name rises ≈ 50 pt. Visible in `Main.png` and `MainLight.png`: `VISTA PARK`/`AIRPORT LOOP`,
`NORTHGATE`/`FOUNDRY RD` and `HILLCREST`/`QUARRY RD` all cross.

Note: both constants are individually sanctioned by plan §B.4 and §H.1 #4 — this is not a request to
reopen either. The defect is the *rendered collision*, which no closed decision covers. Either raise
`firstStopAlong` towards the artboard's 153, or suppress/shorten whichever of the two names is
overrun.

### m22. The header's trailing group is baseline-aligned where the artboard centres it
**CONFIRMED** · `BusBus/Board/HeaderView.swift:14` — one
`HStack(alignment: .lastTextBaseline)` for the whole header

*Artboard* `Main.dc.html`: the header row is `align-items: center`; only the *leading* (title +
caption) group is `align-items: baseline`. *Measured* (`Main.png`): title cap box 22.0-45.5 (baseline
45.5, cap height 23.5 → 34 pt ✓); caption 36.5-45.5 (baseline 45.5 ✓, matching the artboard); clock
27.5-45.5 with baseline 45.5, where centring in the 72 pt header would put it at ≈41.7. The clock and
gear sit **≈4 pt low**, and the LIVE group's baseline measures 40.0 — neither centred nor baselined.

*Fix:* keep `.lastTextBaseline` for the leading `HStack` (title + caption) and wrap the trailing
group in its own `.center`-aligned `HStack`.

---

## NITS

- **n1.** `RouteCompressor.swift:55-61` — `shared.suffix(keepAtEnd)` traps if `tailBudget == 0`
  (`suffix(-1)`). Unreachable today (`tailBudget` is 4 or 5) but one preset away from a crash.
  Guard with `max(0, tailBudget - 1)`.
- **n2.** `MapLayoutEngine.swift:129` — a joined line whose junction lands at trunk index 1 gets
  `endAlong = junctionAlong - stopPitch`, which is *left of* `firstStopAlong`; its own stops are then
  placed at a lower along than its own terminus and the rail is drawn backwards. Degenerate but
  reachable from real data. Clamp `endAlong` to `≥ terminusEnd + stopPitch`.
- **n3.** `MapLayoutEngine.swift:284` — `emptyScene` returns `trunkLineID: request.trunkLineID` while
  the normal path returns the *resolved* trunk. Make them consistent.
- **n4.** `MapLayoutEngine.swift:471-473` — `spans(_:)` fabricates a `0 ..< swallowedCount` range only
  so `pieces` can ignore it. Give `pieces` a `(from, to)` tuple instead.
- **n5.** `BoardLayoutMode.swift:45` uses `width >= height` where plan §D.1 rule 1 says `width > height`.
  A square 1000×1000 scene resolves differently from the plan. Edge case only.
- **n6.** `BoardLayoutMode.swift:33` sets `minimumScale = 0.32` while the plan says "never below 0.5".
  The **code** is self-consistent (`isCompact { scale < 0.5 }` and §E.10 would be dead at 0.5) — the
  plan text is the stale side. Update the plan, not the code.
- **n7.** `MapMetrics.swift:165, 215` — flat `labelOffset = 32` vs the artboards' 33/34 (phone stop
  names `left: 44px` off a 22 px dot = centre + 33; iPad `left: 46/56` = centre + 31/+34). Within 2 pt.
- **n8.** `SettingsStore.swift:69-77` — `provider` constructs a fresh provider on every access, and
  `BoardViewModel` reads it twice per cycle (`:169`, `:205`). Harmless today (`HTTPClient` uses
  `URLSession.shared`) but it defeats any future per-provider state. Cache it.
- **n9.** `BusBus/POC/POCViews.swift:226` contains `♿`, the target's only emoji used as a UI glyph
  (brief §4 forbids it). `#if DEBUG`-only, so it does not ship — but the POC folder as a whole is now
  dead weight next to `Transit/`, and removing it would take the violation with it.
- **n10.** `FontRegistrationTests.swift:26-27` — if registration failed entirely, the system
  fallback's PostScript name is also ≠ `"Archivo-Black"`, so that assertion passes when everything is
  broken. Lines 28-29 and `allSixFacesResolve` carry the real weight; pair the first assertion with
  "and it is an Archivo face".
- **n11.** `HeaderView.swift:39-42` adds a 36 pt settings gear that appears in no artboard, pushing
  the phone clock's right edge from 370 pt in to ≈303 pt. Plan-sanctioned (§D.2); listed only so it
  is not mistaken for drift.
- **n12.** `nearbyCaptionSaysWhyTheListIsEmpty` (`LineSelectionTests.swift:73`) accepts either the
  locating or the ready caption, so it discriminates only the denied/unavailable states — weaker than
  its name.

---

## SUSPECTED — reasoned but not proven

- **S1. The 400 ms trunk cross-fade may not animate.** `BusBus/Board/MapView.swift:19-21` attaches
  `.id(scene.trunkLineID)`, `.transition(.opacity)` and `.animation(.easeInOut(duration: 0.4), value: scene.trunkLineID)`
  to the *same* `Group`. Changing `.id()` replaces the view's identity, which normally resets the
  `.animation(value:)` modifier's stored state; identity-driven transitions usually need the animation
  on an *enclosing* view or an explicit `withAnimation`. Requirement 8 of the brief may therefore be a
  hard cut rather than a 400 ms fade. Not provable from a static render — verify on device, and if it
  is a cut, wrap the trunk assignment in `withAnimation(.easeInOut(duration: 0.4))` at
  `BoardViewModel.swift:315` or move the `.animation` to the parent `ZStack`.
- **S2. A non-`sending` closure parameter may become a Swift 6 error.**
  `BusBus/Transit/Cache/RoutePatternCache.swift:22-23` — `fetch: () async throws -> RoutePattern` is
  a non-`@Sendable`, non-`sending` closure parameter on an actor-isolated `async` method, called from
  outside the actor (`BoardViewModel.swift:217-219`). It compiles under Swift 5 + approachable
  concurrency; whether SE-0430 region isolation accepts it under the Swift 6 language mode depends on
  the non-escaping exemption, which I could not settle without flipping `SWIFT_VERSION`. All captures
  are `Sendable`, so marking the parameter `sending` is free either way.
- **S3. Swift Testing parallelism vs shared statics.** `RoutePatternCache.shared` is an actor (no data
  race) but *which* test populates `stub/41` first is nondeterministic, as is
  `FontRegistrar.hasRegistered`. No failure observed. Fixed by M15.
- **S4. If the fonts fail to register in the test host, renders still exceed 5 KB**, so screenshots
  would silently ship the wrong typeface. Compounds C5.
- **S5. The line-chip check mark may be drawn off-centre.** `BusBus/Setup/LinePickerView.swift:49-61` —
  the path spans x ∈ [0, 0.46·side], y ∈ [0.15·side, 0.5·side] inside a `.frame(width: side, height: side)`
  with a `.background(Circle())`; the bounding-box centre is (0.23, 0.325) against the circle's
  (0.5, 0.5), an ≈8 × 5 pt offset up-and-left at side 30, with the glyph touching the circle's left
  edge. The artboard centres a 15×12 SVG in the 30 px circle. Unverifiable from the renders because of
  m20.

---

## Categories that came back clean — stated explicitly, not padded

- **Retain cycles and timer lifecycle.** Zero instances in the target of `Timer` /
  `Timer.scheduledTimer`, `NotificationCenter` observers, `CADisplayLink`, `AsyncStream` continuations,
  `Task.detached`, `@unchecked Sendable`, `nonisolated(unsafe)` or `MainActor.assumeIsolated`. The one
  `DispatchQueue` (`BoardViewModel.swift:188`) is a label for `NWPathMonitor` and touches no
  main-actor state. Every long-lived `Task` captures `[weak self]` (`BoardViewModel.swift:149`,
  `BusTracker.swift:27`, `SetupViewModel.swift:87`, `SettingsAffordanceOverlay.swift:17`) and none is
  retained by the task. All mutable global state is `let` or `@MainActor`-isolated. Periodic timing is
  `TimelineView`, not timers, and `start()` is idempotent. No "duplicate timer on every appear" bug
  exists.
- **Off-main access to `@MainActor` state.** None found. The `NWPathMonitor` handler correctly hops
  via `Task { @MainActor … }` (`BoardViewModel.swift:177-187`).
- **Brief requirements 1-10.** The 3-line cap is model-enforced (`SetupViewModel.swift:14, 123,
  127-133`) and the UI muting is decoration on top; the line picker has no error path at all
  (`loadError` is written at `SetupViewModel.swift:74/98/117` and read nowhere); there is no "use my
  location" button; **zero** matches for `Gradient`, `Divider` or `.border(` and every glyph is a
  hand-drawn `Path`; the 90 s stale rule is implemented and tested at the 89/91 s boundary; the
  shipping provider polls at 20 s; the 30 s trunk throttle is implemented and tested six ways; minutes
  count down via `TimelineView(.periodic(by: 1))` with `.contentTransition(.numericText(countsDown:))`;
  **zero** matches for crowd/capacity/occupancy/passengers.
- **Wall mode** implements `isIdleTimerDisabled` (plus macOS `beginActivity`), no nav chrome, no
  scroll, an eight-position ±2 pt drift on a 180 s cycle, reconnect-on-network-restore, and relaunch
  into the map rather than setup. Only the ambient-light proxy (m12) and the tap area (m6) fall short.
- **The provider layer does not fabricate.** `BusGovILProvider.vehicles(for:)`
  (`BusGovILProvider.swift:50-54`) emits `VehiclePosition(location:)` and nothing else —
  `recordedAt`, `tripId`, `plateNumber`, `bearing`, `speedKmh` all stay nil. `ReadoutSubline` renders
  every fragment as an optional and adds "SCHEDULED" when `!isRealtime`. The three fabrications
  (C3, C4, M8) are all downstream of the seam, not in it.
- **The `MapEngine` test suite is genuinely strong.** `MapLayoutEngineTests` uses hand-derived
  artboard literals (1020/1066/1074/1120; 110/510…910; capsule 154/54/20/10) rather than
  recomputations. `RailPathTests.cubic_midpointWithinTolerance` checks the along-parameterised
  approximation against a bisection-solved true Bézier — a genuinely independent oracle.
  `JunctionDetectorTests` covers subset, independent, duplicate-code and missing-user-stop.
  `TrunkSelectorTests` nails the 30 s throttle at the 29/30 s boundaries including manual promotion.
  `SettingsStoreTests` round-trips through a second store instance with literal expectations.
  `RoutePatternCacheTests` is the model the rest of the suite should follow.
- **No test uses the real network, a real sleep, or a test-visible timer.**
- **Every colour token is exact.** `DesignTokens.swift` matches plan §C.1/§C.2 hex for hex, and the
  renders sample exact flat values: background `(8,8,11)`, readout band `(11,11,15)` with the
  boundary at exactly y = 452, card `(21,21,27)`, stop name `(140,140,154)`, dash caption
  `(94,94,108)`; light `(244,242,236)` / `(20,20,15)` / `(219,215,205)`, rails `#D32029` `#EFA400`
  `#0E7C86`, terminus inks `#B01A22` `#8A6000` `#0B636B`, and the light band equals the light
  background as the brief requires. All 36 palette hexes in `LinePalette.swift` match §C.3 exactly.
- **Typography is right.** `BusFace` names all six PostScript faces exactly and `.weight()` is never
  applied to a custom face anywhere. Measured glyph heights confirm the sizes: the primary numeral is
  86.0 pt tall and the THEN numeral 39.0 pt — a constant 0.695 figure-height ratio giving **124 pt**
  and **56 pt**; title cap 23.5 → 34 pt; header caption cap 9.0 → 13 pt; kicker cap 8.5 → 13 pt; `MIN`
  is `lastTextBaseline`-aligned with its numeral. Tracking matches the artboards' letter-spacing
  (−5/124 = −0.040 vs `-0.04`; −2/56 = −0.0357 vs `-0.036`; −0.5/34 = −0.0147 vs `-0.015`).
- **Landscape geometry is right.** Header 72 / map 380 / readout 268 at 1280×720; 40 pt side insets
  (badge left edge at exactly 40.0, THEN card right edge at 1240.0); node centre x = 1190 with r = 26
  and a 12 pt stroke (outer diameter 64); the stub occupies exactly the artboard's 1110-1170 (it is
  only occluded — M20); rail rows at 142/262/382 with pitch 120 and width 12; stop rings r 13 / 6 pt
  (interior 20, outer 32) at pitch 100; dashes 20 on / 18 off; puck 44×36 r10 with a 5 pt halo, a
  +5 pt ring when selected and a 1.14 scale; interchange capsules 20 pt wide, 4 pt stroke, corner 10,
  spanning 54 pt for a two-rail bundle (parallel at 244 − 18 to trunk at 262 + 18) exactly as
  `Merge1.dc.html`; parallel offset ±18 in all three merge renders; terminus bar 10 × 40 r5 (and
  10 × 60 on SingleLine).
- **Stop names are uppercased in the engine** (`MapLayoutEngine.swift:618, 633`), so real feed data is
  covered, not just the caps-only fixtures.
- **No dividers and no gradients, measured not eyeballed.** A full column scan of `Main.png` at
  x = 640 from y 0→720 shows a clean `#08080B`→`#0B0B0F` step at y = 452 and **nothing at y = 72**.
  Every sampled fill is a single exact hex; the dashed rails are real `StrokeStyle` dashes, not faked
  with a repeating gradient. The white node and the selected-puck ring are present in both themes.
- **`mergeA ↔ Merge1` and `mergeC ↔ Merge3` topologies are both correct** (only mergeB is not
  exercised — M23).
- **Degenerate engine inputs that behave correctly** (verified in the harness): empty line list →
  `emptyScene` with a valid convergence mark; trunk id missing → falls back to `valid.first`;
  two-stop lines → terminus + node, no marks, no crash; a line that is a strict subset of the trunk →
  terminus drawn on the parallel rail at the junction; a 120×60 canvas at scale 0.09 → no crash, no
  NaN, all marks inside the canvas; scale at 0.3 and 3.0 → positions scale linearly.
