# Route shapes — group "israel" (bus.gov.il, stride, transitous)

All live checks on Monday 2026-10-19, 08:40–09:10 IDT (morning peak; bus.gov.il was slow for every endpoint
this morning — a night sweep on 2026-10-19 01:30 measured 0.3 s per call). [V] = verified live on that date,
[U] = unverified. Requests: bus.gov.il 30, Stride 13, Transitous 18, ≥ 1.1 s apart, UA
`BusBus-research/1.0 (you@example.com)`. No 429/403 anywhere. Raw replies are in
`/private/tmp/claude-501/-Users-amir-Developer-BusBus/679ea7dd-05fc-4173-ad13-8f8bc473d67a/scratchpad/regions/dl/{busgovil,stride,transitous}/`
(`log.tsv` there has status, latency, sizes and headers per request); shapecheck inputs are in
`/private/tmp/claude-501/-Users-amir-Developer-BusBus/679ea7dd-05fc-4173-ad13-8f8bc473d67a/scratchpad/regions/israel_work/`.

**Headline:** bus.gov.il's `Routes/GetRouteFullData?routeId=` returns the stops **and** the shape (`data.polyline`)
in one reply. Swapping it in for `Routes/GetRouteStops` in `routePattern` makes a cold line cost exactly what it
costs today: one call, no trip id, no calendar, and it works on days the line does not run. Stride uses the same ids,
so it can borrow this shape.

---

## bus.gov.il

### 1. How the adapter loads a line today
- `lines(atStop:)`: `GET {scheduler}/Stops/GetStopFullData?stopCode=<code>` → `routesInStop[]`.
  `TransitLine.id = String(routeId)` (the MOT GTFS `route_id`), `providerRefs["routeDesc"]` = `"13112-2-#"`
  (makat-direction-alternative).
- `routePattern(for:)`: `GET {scheduler}/Routes/GetRouteStops?routeId=<line.id>` → `data.route.stops[]`
  (`stopid` = GTFS stop_id, `stopcode`, lat/lng, `stopSequence`).
- `arrivals`: `GET {scheduler}/Calendar/GetRouteCalendarAtStopsByStopCodes?stopCodes=&routeDesc=` →
  `stopTimes[].staticTripId`.
- `{scheduler}` = `https://api.bus.gov.il/prod/mot-scheduler-prod/api/{he|en|ar}`.

**Does any reply we already fetch carry a trip id or a shape?** [V]
| reply | shape | usable trip id |
|---|---|---|
| `GetRouteStops` | no | no (`route.{routeId, stops, tripHeadSign}` only) |
| `GetStopFullData` | `routesInStop[].polyline` is always `null` | no |
| `GetStopsCloseToLocation` | `polyline` `null` | no. Also note: radius=30 m returned 968 KB in 22 s |
| `GetRouteCalendarAtStopsByStopCodes` (arrivals) | no | `staticTripId` = `585405133_151026`. **The suffix is stale**, so the id as given returns `""` from the shape endpoint (see the trip-id rule below) |
| `SearchStations` (planner) | no | no (stations only) |

### 2. Shape recipe: 0 extra calls (piggyback)
```
GET https://api.bus.gov.il/prod/mot-scheduler-prod/api/<lang>/Routes/GetRouteFullData?routeId=<line.id>
→ data.polyline   (HERE Flexible Polyline string)
→ data.stops[]    (same fields as GetRouteStops: stopid, stopcode, name{he,en,ar}, cityName, streetName,
                   streetNumber, lat, lng, stopSequence, plus per-stop nextStopsTimes)
```
Found in the route.bus.gov.il bundle (`main-QMRTX3UN.js` / `chunk-PCGESSUS.js`, `getRouteFullData(routeId,
boardingStationName?, boardingStationCode?, droppingStationName?, droppingStationCode?)`). Optional params are not
needed.

- [V] Route 13389 (line 112 Haifa): `polyline` is byte-identical to `GetTripShapePolyline` for that route's trips.
  Its 67 stops are identical to `GetRouteStops` (same seq, code, lat, lng).
- [V] Route 13390 (112 alternative "ב", Saturday-only, calendar `saturday:1`, all other days 0) was fetched on a
  Monday and still returned its own polyline (1,368 pts) and 70 stops. So the reply does not depend on the line
  running today. This covers Shabbat, holidays and lines that run only some days. A Saturday run was not tried. [U]
- [V] Route 3743 (line 33 Haifa, circular `10033-3-#`): polyline identical to the shapes of trips from two different
  trip-id families (25323833_…, 20792855_…).
- [V] Route 6791 (554 Jerusalem→Arad, alternative "א", intercity 158 km): polyline present, PASS.
- Also in the same reply, free: `calendar` (weekday flags + start/end date), `routeDesc`, `oppositeDirectionId`,
  `headsign`, `specialMessages`.

**Implementation:** in `routePattern`, call `GetRouteFullData` instead of `GetRouteStops` and decode the same stop
DTO. Then hand `polyline` to the shape cache. If you don't want the bigger reply on every daily pattern refresh, use
`GetRouteFullData` only when the shape is missing or older than 7 days, and keep `GetRouteStops` otherwise. Sizes:
13389 is 110 KB vs 30 KB; the server does not gzip.

**Fallback if `polyline` is null/empty** (not seen in 4 routes):
1. Call `Calendar/GetRouteDailyCalendar?routeId=&startStopId=<first stopid>&endStopId=<last stopid>&day=<ISO>` and take
   `data.start[0].tripId`.
2. Call `Routes/GetTripShapePolyline?tripId=` with it.

Total: 2 calls.
- [V] `endStopId` is required: with only `startStopId` the reply is `{"start":[],"end":[]}`.
- [V] Use any day the line runs. Trip ids carry the *GTFS file date*, not the service date: the calendar for
  Tuesday 20 Oct returned `…_191026` ids. Choose the day from the `calendar` weekday flags already in hand (0 calls),
  so no day-by-day probing is needed.
- [V] The site's own path, `Calendar/GetTripCalendar?routeId=&stopId=&stopSequence=&date=`, returned `{}` for a
  09:00 date. It wants an exact departure time. Not worth it.
- [V] `Calendar/GetRouteNextDayOfService?routeId=&dayToCheckFrom=` returned `null` (asked from a Saturday, for a
  route that runs Sun–Fri). Not needed.
- [V] `Routes/GetRoutePolylineByRouteDescStopAndTime?routeDesc=13112-2-%23&stopCode=41122&time=08:56` returned `""`.
  The site uses it only for the vehicle→boarding-stop piece in the trip planner.
- No endpoint returns shapes for many routes at once. The bundle's full endpoint list is: AutoComplete/*, Calendar/{GetRouteCalendarAtStops,
  …ByStopCodes, GetRouteDailyCalendar, GetRouteNextDayOfService, GetTripCalendar, GetTripCalendarByRouteDesc},
  Routes/{AutoComplete, GetIntercityLines, GetNextRouteLocation, GetRouteFullData, GetRouteLocations,
  GetRoutePolylineByRouteDescStopAndTime, GetRoutePrice, GetRouteStops, GetSpecialMessage*, GetTripShapePolyline,
  IsRouteHasAlternatives}, Stops/*, location/*, RoutePlanning/*.

**Trip-id rule (matters only for the fallback):** [V] tripId = `<GTFS trip_id>_<ddMMyy of the GTFS file currently
loaded>`.
- On 19 Oct, `_191026` worked for every trip.
- `12304188_181026` (yesterday) and `12304188_201026` (tomorrow) returned `""`.
- The arrival's `staticTripId` (`585405133_151026`) only worked once re-suffixed (`585405133_191026` → 20.7 KB).
- Stride's rides for 18 Oct carry `_171026`, and the prior session at 01:30 on 19 Oct saw `_181026`.
- So the suffix lags the service date by an unknown amount and the client cannot know it. Don't build trip ids;
  `GetRouteFullData` makes this unnecessary.

### 3. Format and decoding
- `polyline` / `GetTripShapePolyline.data` is a HERE Flexible Polyline: version 1, header precision **15**
  (confirmed [V]), no third dimension. Order is lat,lon. One piece, already in travel order. No stitching or
  reversing is needed. Decoder: `tools/flexpoly.py`, about 25 lines to port to Swift.
- [V] Despite precision 15, every decoded coordinate is an exact multiple of 1e-6: the source is MOT `shapes.txt`
  at 6 decimals. Precision-6 re-encoding is lossless.
- **On-disk encoding:** a Google encoded polyline at precision 6 is lossless and uses the same decoder as Transitous
  `legGeometry`.
  - 13389: 1,350 pts. Flexible 20,673 chars → p6 4,669 chars (3.4 KB gz); p5 would be 3,322 (2.1 KB gz).
  - 6791: 3,425 pts, 54 KB → p6 13.4 KB.
  - Optional Douglas–Peucker at about 2 m before storing cuts it further. Store `[stopcode]` hash +
    `fetchedAt` beside it.
- Variants: each alternative (`#`, `ב`, `ך`…) is its own routeId with its own shape. The shape always matches the
  routeId's own stop list, so there is nothing to pick.
  - [V] 112 dir 2 has `#` 13389 (Sun–Fri), `ב` 13390 (Sat) and others.
  - [V] All sampled trips of one routeId share one shape: 13389 had 4 trip families (12304188, 12716404, 16153100,
    585405133); 3743 had 2.

### 4. Live verification [V]
| line | routeId | stops | pts | shape m | ratio | max / median offset | verdict | reply raw (no gzip on wire) | latency |
|---|---|---|---|---|---|---|---|---|---|
| 112 Haifa (Sun–Fri) | 13389 | 67 | 1,350 | 23,885 | 1.16 | 5.1 / 5.0 m | PASS | 110 KB (18 KB if gz) | 3.6 s, 9.2 s |
| 112 alt ב (Sat only, fetched Mon) | 13390 | 70 | 1,368 | 23,661 | 1.16 | 5.1 / 5.0 m | PASS | 56 KB | 7.6 s |
| 33 Haifa loop | 3743 | 34 | 512 | 7,824 | 1.22 | 5.1 / 5.0 m | PASS | 53 KB | 38.7 s (outlier) |
| 554 Jerusalem→Arad alt א | 6791 | 49 | 3,425 | 158,453 | 1.21 | 5.1 / 5.0 m | PASS | 79 KB | 5.0 s |

The same morning, `GetRouteStops` took 5.3 s and 11.9 s and `GetTripShapePolyline` 0.8–8.1 s. The server was slow
across the board, so `GetRouteFullData` is not clearly slower than what it replaces. Expect about 0.3–0.5 s off-peak
(prior night sweep).

### 5. Cache key and change detection
- **Key:** `shape/il-mot/<routeId>`. Don't use the language `datasetID`: the shape is the same on he/en/ar. Stride
  (same id) and Transitous-Israel (`il-Israel-MOT_<routeId>`) can share it.
- [V] **routeId is stable.** Stride's `gtfs_routes` has line_ref 13389 on every service day from 2025-01-01 to
  2026-10-19 (550 days, gaps only on Saturdays). The Saturday alternative 13390 also persisted all year (92
  Saturdays).
- **"Has it changed?" signal:**
  - [V] There is no ETag, Last-Modified or Cache-Control.
  - Use the stop list: hash the ordered `stopcode`s from the daily pattern refresh (which happens anyway, 24 h
    lifetime). If the hash changes, refetch the shape with `GetRouteFullData`.
  - Otherwise revalidate weekly.
  - If `shapecheck` fails against the current stops, drop the cached shape and refetch once.

### 6. Rate limits and terms
- Undocumented, keyless API with no ToS and no published limit [U].
- [V] 30 calls at ≥ 1.1 s spacing: no 429/403 and no rate-limit headers. One connection error (URLError after 16 s)
  on `GetStopsCloseToLocation`; it succeeded on retry.
- [V] Responses go through CloudFront (`x-amz-cf-pop: TLV55-P3`, `server: volt-adc`), always "Miss from cloudfront",
  even on an identical repeat of `GetRouteFullData?routeId=13389`. So there is no edge caching, every call reaches
  origin, and the client cache must be the only cache.
- [V] No gzip, even with `Accept-Encoding: gzip`.
- The geometry is MOT GTFS `shapes.txt` (public MOT open data). Drawing it is fine; keep the existing attribution
  "Israel National Public Transport Authority" [U for licence wording].

### 7. Proxy changes
None. Keyless, called directly from the phone.

---

## stride

### 1. How the adapter loads a line today
`TransitLine.id = String(gtfs_route__line_ref)`. `routePattern` makes 2 calls:
1. `gtfs_rides/list?gtfs_route__line_refs=<id>&gtfs_route__date_from/to=<day>&limit=1`
2. `gtfs_ride_stops/list?gtfs_ride_ids=<ride.id>&…&order_by=stop_sequence asc`

On an empty reply it retries the previous day. [V] Today's ride stops were not loaded yet at 09:00, so the adapter's
fallback day was used.

### 2. Shape: none in Stride. Borrow bus.gov.il's (1 extra call per cold line)
- [V] Stride has no shape. The OpenAPI has no polyline or geometry anywhere; the only "shape" field is
  `gtfs_ride_stops.shape_dist_traveled`.
- [V] Stride's `line_ref` **is** bus.gov.il's `routeId`, which is the MOT GTFS `route_id`:
  - line_ref 13389 = route_mkt 13112, direction 2, alternative `#` = bus.gov.il routeId 13389, routeDesc `13112-2-#`;
  - 3743 = 10033-3-#.
- **Recipe:** `GET https://api.bus.gov.il/prod/mot-scheduler-prod/api/he/Routes/GetRouteFullData?routeId=<line.id>`
  → `data.polyline`, decoded and cached exactly as above, under the shared key `shape/il-mot/<line.id>`. If a
  bus.gov.il board has already opened the line, it costs 0 calls.
- [V] Stride's `journey_ref` is also an MOT trip id with the file-date suffix (`12304190_191026` today, `_171026` for
  18 Oct rides). Don't use it with `GetTripShapePolyline`: the suffix goes stale (see the trip-id rule).
- Free sanity check: the last ride-stop's `shape_dist_traveled` (13389: 23,840 m; 3743: 7,723 m) is about the decoded
  shape length (23,885 / 7,824 m).

### 4. Live verification [V]
Stride's own ride-stops (as the adapter loads them, 18 Oct ride) against the bus.gov.il shape:
| line | stops (Stride = bus.gov.il coords?) | max / median | ratio | verdict |
|---|---|---|---|---|
| 112 / 13389 | 67 (identical) | 5.1 / 5.0 m | 1.16 | PASS |
| 33 loop / 3743 | 34 (identical) | 5.1 / 5.0 m | 1.22 | PASS |

### 5–7.
- Cache key: same as bus.gov.il.
- Stride limits: volunteer-run, no published quota [U]. Unaffected anyway: the shape call goes to bus.gov.il.
- No proxy changes.

---

## transitous

### 1. How the adapter loads a line today
- `TransitLine.id = "<routeId>|<directionId or h:headsign>"`, with `providerRefs` `routeId` and `stopId`.
- `routePattern` calls `/api/v6/stoptimes` (shared, cached 15 s), then
  `GET https://api.transitous.org/api/v6/trip?tripId=<next departure's tripId>&language=` and uses `legs[0]`.

### 2. Shape recipe: 0 extra calls (already downloaded)
- Decode `legs[0].legGeometry`: `{points, precision: 6, length}`, a Google encoded polyline, lat/lon, in travel
  order. `detailedLegs` defaults to true.
- [V] The precision is 6 on every reply.
- `length` = number of points.

**Adapter caveat found [V]:** `joinInterlinedLegs` defaults to `true`, so the trip reply can be a joined
stay-seated block.
- Example: the Zürich tram **4** departure (`…ojp-91-4-F.1.TA.3646.j26`) came back as one leg labelled route **13**,
  Albisgütli → Rehalp, with tripId `…ojp-91-13-B…`.
- The pattern and the shape then include another line's stops.
- **Fix:** pass `joinInterlinedLegs=false` and take the leg whose stops contain the boarding stop. This affects
  today's `routePattern` too.

### 3. Shapeless feeds
MOTIS has `RoutePathSource = NONE | TIMETABLE | ROUTED` (openapi).
- [V] Switzerland's GTFS has no shapes. Transitous returns **ROUTED** geometry for it: OSM map-matched by MOTIS and
  computed on demand. That costs latency:
  - Zürich trips took 8.1 s and 16.8 s, against 0.6–2.2 s for feeds with shapes.
  - `experimental/map/route-details` took 42.9 s for an uncomputed route.
  - It still passes shapecheck: bus 912, max 17.5 m.
- In `experimental/map/routes`, "NONE" marked routes whose segments were not computed yet (`segments: []`). Two such
  routes came back ROUTED from `route-details`. So NONE does not mean "straight lines".
- A trip `legGeometry` that is genuinely stop-to-stop straight (MOTIS's fallback when there is no shape and routing
  fails) was **not observed** [U].
- **Detector, needed because shapecheck alone PASSes a straight line** (stops lie on it, ratio about 1.0):
  - reject if `legGeometry.length < 1.5 × stopCount`, or if more than 50% of vertices lie within 2 m of a stop
    coordinate;
  - observed real shapes: 0.2–8% of vertices on stops, 8–40 points per stop. A straight line is 100% and 1 point per
    stop.
- Don't use `experimental/map/routes`: one zoom-17 box returned 7,545 routes, 4.5 MB raw / 1.3 MB gz, in 25 s.

### 4. Live verification [V]
| city / line | feed shape source | stops | pts | max / median | ratio | verdict | trip reply wire (gz) / raw | latency |
|---|---|---|---|---|---|---|---|---|
| Berlin M45 | VBB shapes.txt | 39 | 353 | 5.1 / 1.4 m | 1.04 | PASS | 4.8 / 23 KB | 1.45 s |
| Berlin 100 | VBB shapes.txt | 19 | 242 | 5.2 / 2.1 m | 1.10 | PASS | 3.2 / 12.5 KB | 1.49 s |
| Helsinki HSL 55 | HSL shapes.txt | 25 | 200 | 7.5 / 4.7 m | 1.13 | PASS | 3.4 / 15 KB | 0.63 s |
| Zürich bus 912 | none → MOTIS ROUTED | 19 | 544 | 17.5 / 4.3 m | 1.19 | PASS | 3.6 / 14 KB | 8.1 s |
| Zürich tram "4" (joined 13+4 block) | none → ROUTED | 28 | 1,124 | 7.8 / 1.8 m | 1.05 | PASS (wrong line, see caveat) | 5.7 / 21 KB | 16.8 s |
| Haifa 112 (il-Israel-MOT_585138803_191026) | MOT shapes.txt | 67 | 1,352 | 5.3 / 5.0 m | 1.16 | PASS | 9.1 / 42 KB | 2.2 s |

[V] Transitous's Israel data uses the MOT ids: route `il-Israel-MOT_13389` and stop `il-Israel-MOT_<stopid>` (as in
bus.gov.il). Its trip ids embed the same `<trip>_<file date>`. The geometry is the bus.gov.il shape: every vertex is
within 5.5 m, with 2 extra end vertices snapped to the terminals.

### 5. Cache key
- Use `shape/transitous/<routeId>|<direction>` plus a hash of the ordered stop ids. For `il-Israel-MOT_*`, use the
  shared `shape/il-mot/<routeId>`.
- No change signal (no ETag observed).
- Refresh when the pattern's stop list changes; otherwise weekly.

### 6. Terms [V, transitous.org/api, read 2026-10-19]
"Go ahead if **all** of these apply: open-source, not commercial, light on resources, conforms to usage policy."
It also asks you to publish your code under an open-source licence.
- Commercial use is not allowed.
- Attribution: link transitous.org/sources and follow OSM attribution. ROUTED shapes are OSM-derived (ODbL).
- Heavy endpoints need prior contact on Matrix.
- **A free but closed-source app does not qualify** (it fails "open-source"). The provider must stay behind
  `transitous_enabled=false` in the shipping build, as the adapter comment already says. Shapes add no new
  obligation beyond that.

### 7. Proxy changes
None (keyless). The UA must carry the app name, version and contact; the adapter already sends it.

---

## Summary

| provider | extra calls per cold line | piggyback? | format | verified lines PASS/FAIL | max offset | size | latency | cache key | notes |
|---|---|---|---|---|---|---|---|---|---|
| bus.gov.il | **0**: use `Routes/GetRouteFullData?routeId=` in place of `GetRouteStops` | yes (stops + `polyline` in one reply) | HERE flexible polyline, header p15, data really p6, lat/lon, one piece | 4/4 PASS (112, 112-Sat-alt fetched on a Monday, 33 loop, 554 intercity) | 5.1 m | 53–110 KB raw (no gzip); polyline 8–54 KB → p6 1.8–13 KB on disk | 3.6–9 s this morning (one 38.7 s outlier); about 0.3–0.5 s off-peak | `il-mot/<routeId>` (stable 22 months [V]) + stop-code hash | works when the line doesn't run today; fallback `GetRouteDailyCalendar` (needs end stop) → `GetTripShapePolyline` (2 calls); never build trip ids (file-date suffix lags) |
| stride | **1** (bus.gov.il `GetRouteFullData?routeId=<line_ref>`), 0 if cached | no (Stride has no shape) | as bus.gov.il | 2/2 PASS against Stride's own stops | 5.1 m | as bus.gov.il | as bus.gov.il | shared `il-mot/<line_ref>` | line_ref = MOT route_id = bus.gov.il routeId [V]; `shape_dist_traveled` gives a free length check |
| transitous | **0** (`legs[0].legGeometry` of `/api/v6/trip`, already fetched) | yes | Google polyline p6, lat/lon | 6/6 PASS (Berlin ×2, Helsinki, Zürich ×2 ROUTED, Haifa) | 17.5 m (Zürich routed); ≤ 7.5 m with feed shapes | 3–9 KB gz per trip reply | 0.6–2.2 s; 8–17 s for on-demand ROUTED feeds | `<routeId>|<dir>` + stop-id hash; `il-mot/<routeId>` for Israel | set `joinInterlinedLegs=false` (joined blocks seen); reject straight lines by vertex-on-stop share; **terms exclude closed-source apps** |

**Blockers / open items**
- Transitous cannot be used in a closed-source build, however free (terms).
- Not run on an actual Saturday: `GetRouteFullData` on Shabbat itself [U]. A Saturday-only route fetched on a
  Monday worked, so day-independence is strongly indicated.
- A real Transitous straight-line `legGeometry` was not found to test the detector against [U].
- bus.gov.il has no edge cache or gzip, and morning-peak latency was 4–12 s for every endpoint. The client cache is
  essential. Fetch the shape once and keep it.
