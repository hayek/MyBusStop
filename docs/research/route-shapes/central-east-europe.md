# central-east-europe — route-shape recipes (2026-10-19)

Providers: entur, foli, tampere, ztm-poznan, ztm-gdansk, mpk-krakow, wienerlinien, efa-linz, lpp-ljubljana,
tallinn, vilnius, kaunas, iett. None of them is keyed, so functions/src/agencies.ts needs no changes for any of
them. [V] = verified live on 2026-10-19, [U] = unverified. Scratch scripts: regions/scriptsA, work-b, scripts-c,
partD-tools, scripts-iett; downloads under regions/dl/<provider>/.

### Adapter bugs found while verifying (they affect the stop list, not only shapes)
- **ztm-poznan:** PEKA `getBollardsByLine` merges every variant of a direction, and the variants each restart
  `orderNo`. `routePattern` sorts by it, which gives zig-zag stop lists on lines 12, 16, 174 and 5.
- **efa-linz:** the geo object's `locationSequence` is a union of variants (tram 3 has its depot branch after the
  terminus; 19 and 27 R are also wrong).
- **wienerlinien:** "longest variant" picks variants that don't run (tram 6 → Zentralfriedhof); the lowest
  PatternID matched the current shapes on the 3 lines checked.
- **mpk-krakow:** ttss.mpk.krakow.pl answered 503 with a block page in daytime too, which looks like a block of
  the whole provider. Re-test it from an EU IP.
- **End-stop tolerance:** several FAILs (Entur at the parent stop place, Poznań tram 16, Vienna tram 6 H, LPP
  Dolgi most, IETT EM1) come only from a terminus stop placed 60–75 m off the road. Two possible fixes: allow
  ~100–150 m at the first and last stop, or add a short stub from the terminus stop to the shape.

## entur

1. **Today** [V 2026-10-19]: `lines(atStop:)` POSTs `stopPlace(id){quays{journeyPatterns{id directionType line{…}}} soon: estimatedCalls…}` to
   `https://api.entur.io/journey-planner/v3/graphql`. `TransitLine.id = "<lineId>#<direction>#<stopPlace>"`,
   `providerRefs = {line: "SKY:Line:4", direction: "inbound"|"outbound"|<patternId>, stop: "NSR:StopPlace:…", headsign?}`.
   `routePattern(for:)` calls `linePatterns(line)` = one POST
   `{ line(id:) { journeyPatterns { id directionType serviceJourneysForDate(date:) { id } quays { id name latitude longitude stopPlace { … parent { … } } } } } }`
   (memory-cached per line+service date, also reused by every `vehicles` poll), then picks the busiest pattern of the
   direction that calls at the rider's stop place. The chosen journey pattern id (`SKY:JourneyPattern:4-2298`) is in hand.
2. **Recipe: 0 extra calls (piggyback)** [V]. Add `pointsOnLink { points }` to the journeyPatterns selection of the
   existing `linePatterns` query:
   `{ line(id: "SKY:Line:4") { journeyPatterns { id directionType pointsOnLink { points } serviceJourneysForDate(date: "2026-10-19") { id } quays { … } } } }`.
   Validated by the live server (no schema error); every pattern of 3 lines (Skyss 4, 11; Ruter 20) carried it. Decode
   the chosen pattern's `pointsOnLink.points`. There is no `journeyPattern(id:)` root field (tested: `FieldUndefined`),
   so a separate per-pattern query would have to go through `line(id:)` anyway — piggybacking is the only sensible form.
   Cost: the line reply grows by ~2–5 KB gzipped (line 4: 3.4 → 8.7 KB gz; Ruter 20: 9.3 → 13.2 KB gz; line 11:
   1.4 → 3.3 KB gz). Because `linePatterns` is also used by `vehicles`, the growth is paid once per line per day
   (it is memory-cached). Optional: a second query string without `pointsOnLink` once the shape is on disk.
3. **Format** [V]: Google encoded polyline, **precision 5**, lat/lon order, one piece per pattern, already in travel
   order (no reversing/stitching). `pointsOnLink.length` is the number of points, not metres. Each pattern (incl.
   short turns, depot runs) has its own geometry, so use the shape of the exact pattern `routePattern` chose.
   Check the shape against **quay** coordinates (`quays[].latitude/longitude`, already in the reply): the adapter shows
   the multimodal parent's centroid for stops, which can sit 75 m off the road (see Ruter 20 below).
4. **Live verification** [V 2026-10-19, shapecheck]:
   - Skyss 4 inbound (fixture stop NSR:StopPlace:30853), chosen `SKY:JourneyPattern:4-2298`, 41 quays, 1,169 pts:
     quay-level PASS max 9.7 m / median 5.9 m, ratio 1.12; stop-place-level PASS max 35.1 m. Variant `4-2299`
     (48 quays, longer run): PASS max 9.7 m.
   - Skyss 11 inbound: `11-192` 19 quays, 517 pts: PASS max 11.6 m (quay), 9.8 m (stop place). Short variant `11-148`
     (7 quays): PASS max 11.6 m.
   - Ruter 20 outbound (Oslo): `RUT:JourneyPattern:011560` 23 quays, 666 pts: quay-level PASS max 7.6 m / median
     4.6 m; stop-place-level **FAIL** (first stop 75 m: the parent stop place centroid of a big interchange, not a
     shape error). Variant `011558` (26 quays): PASS max 7.9 m. Fix: run the check on quay coordinates.
   - Size: +5.3 KB gz on line 4 (47 KB raw), latency of the whole query 1.1–2.0 s with or without the field
     (server noise dominates; no measurable added latency).
5. **Cache key**: `entur:<journeyPatternId>` + hash of its quay ids. Change signal is free: the daily `linePatterns`
   fetch returns the pattern ids and quays; if the id+quay hash matches the cached shape, skip decoding/storing. TTL:
   keep until the pattern id/quay list changes; revalidated implicitly whenever the line is opened on a new day.
   [U] NeTEx pattern ids are not content hashes — they can persist across timetable versions, hence the quay hash.
6. **Limits/terms**: no published quota for identified clients; `ET-Client-Name` header mandatory, unidentified
   clients are strictly rate-limited [U, developer.entur.no; adapter comment]. Licence NLOD — geometry may be drawn;
   attribution "Data: Entur (NLOD)" already in the adapter [U].
7. **Proxy**: none (keyless, called directly).
8. n/a — live shape available.

## foli

1. **Today** [V]: dataset name from `GET https://data.foli.fi/gtfs/v0/` (`latest`, e.g. `20261014-184142`), cached
   per session with `stops`, `trips/all`, `routes`. `lines(atStop:)` → `/gtfs/v0/{ds}/stop_times/stop/{stop}`
   joined with trips. `TransitLine.id = "<route_id>/<direction_id>"`, `providerRefs = {routeId, direction, tripId,
   shapeId}` (shapeId = the GTFS `shape_id` of the representative trip). `routePattern` → `/gtfs/v0/{ds}/stop_times/trip/{tripId}`
   (fallback: `/trips/route/{route}` then pick a trip with the same `shape_id`).
2. **Recipe: 1 extra call** [V]: `GET https://data.foli.fi/gtfs/v0/{ds}/shapes/{shape_id}`. Take `shape_id` from the
   trip whose stop_times built the pattern (providerRefs `shapeId`, or the fallback trip's `shape_id`; the cached
   `trips/all` maps every trip id to its `shape_id`). No endpoint returns stops and shape together.
3. **Format** [V]: JSON array `[{"lat":60.45168,"lon":22.26546,"traveled":0},…]` (pretty-printed, with float noise
   like `60.45168000000000319…`, real precision 5 decimals); `traveled` = metres (matches `shape_dist_traveled` in
   stop_times). Travel order, one piece, no reversing. Points every ~20–25 m → Douglas–Peucker before storing.
   Variants are separate `shape_id`s within a route+direction (route 6: shapes 50/51 main, 55 short, 57/58 long).
4. **Live verification** [V 2026-10-19]:
   - Line 1 (fixture, route_id 1): dir 1 shape 2, 38 stops, 539 pts: PASS max 15.2 m / median 5.2 m, ratio 1.09;
     dir 0 shape 1: PASS max 12.2 m. 92 KB raw / 23 KB gz, 2.1–3.3 s.
   - Line 6 (route_id 13, variants): shape 51 (67 stops, 1,333 pts) PASS max 13.0 m; shape 50 PASS max 10.8 m;
     short variant 55 (32 stops) PASS max 9.8 m; long variant 58 (73 stops) PASS max 13.0 m. 220–241 KB raw /
     55–60 KB gz, 3.2–7.3 s.
   - Heavy for what it is (≈170 B/point raw); store re-encoded (≈4 KB polyline).
5. **Cache key**: `foli:<dataset>:<shape_id>` — shape ids are small integers, assumed to be renumbered between
   datasets [U]. Change signal: the `/gtfs/v0/` `latest` name the adapter already fetches each session; on a new
   dataset, re-fetch only when the line is opened (or keep the old shape if the pattern's stop-id list is unchanged
   and re-validate weekly). Response headers: `Cache-Control: max-age=1800`, `Last-Modified` (CDN, not useful per shape).
6. **Limits/terms**: no stated rate limit; CC BY 4.0 with the fixed attribution sentence already in the adapter
   [V docs page lists `shapes.txt` as "Linjojen reittikoordinaatit"]. Drawing allowed under CC BY.
7. **Proxy**: none.
8. n/a.

## tampere

1. **Today** [V]: `lines(atStop:)` → `GET https://data.itsfactory.fi/journeys/api/1/journey-patterns?stopPointId={stop}&exclude-fields=journeys,stopPoints.municipality,stopPoints.tariffZone`;
   `TransitLine.id = "<lineName>/<direction>"`, `providerRefs = {line, direction, patternId}` (patternId = content
   hash, longest pattern of the direction). `routePattern` → `/journey-patterns/{patternId}?exclude-fields=…`
   (fallback `/journey-patterns?lineId=…`). Every pattern object in both replies already carries
   `routeUrl` (`…/routes/2576278094`) — currently not decoded.
2. **Recipe: 1 extra call** [V]: decode `routeUrl` from the pattern reply `routePattern` already fetches, then
   `GET https://data.itsfactory.fi/journeys/api/1/routes/{routeId}?exclude-fields=journeys,journeyPatterns`
   (1.6 KB gz for 28 km). Without `exclude-fields` the same reply is 425 KB (every journey). The `/routes` reply's
   `journeyPatterns` lack `stopPoints`, so it cannot replace the pattern call; a true 0-call piggyback is not possible.
   Each route id maps 1:1 to one journey pattern (short turns have their own route).
3. **Format** [V]: `geographicCoordinateProjection` string: `"6144766,2383534:-6,-1:0,20:…"` — first pair is
   absolute lat,lon × 1e5; every following pair is a delta that is **subtracted** (`lat -= dLat; lon -= dLon`), lat
   first. (Adding the deltas — the obvious reading — produces a mirrored line that fails every stop.) Travel order,
   one piece. ~50–60 m spacing.
4. **Live verification** [V 2026-10-19]:
   - Line 4 (fixture), all 4 patterns: dir 0 full (61 stops, 460 pts) PASS max 13.9 m / median 8.0 m ratio 1.08;
     dir 1 short turn Keskustori–Länsi-Hervanta (24 stops) PASS max 13.2 m; dir 0 short (24 stops) PASS max 13.4 m;
     dir 1 full (64 stops) PASS max 15.3 m. 1.6–3.5 KB raw / 0.9–1.7 KB gz.
   - Line 3 (tram, 6 patterns, 3 checked): 28 stops PASS max 3.9 m; 15 stops PASS max 3.7 m; 17 stops PASS max 3.7 m.
   - Latency: 0.5–4 s typical, one outlier of 15.9 s and one TLS handshake timeout (retried OK): the ITS Factory
     server is slow/erratic — use a long timeout and never block the modal's stop list on the shape.
5. **Cache key**: `tampere:<routeId>`. Route and pattern ids look like content hashes (the adapter already notes
   pattern ids change with each timetable) [U for routes]. Free change signal: `routePattern` re-fetches the pattern
   and so sees its current `routeUrl`; same route id → cached shape is valid, no call. TTL: until routeId changes.
6. **Limits/terms**: keyless, no documented rate limit, CC BY 4.0 (attribution already in the adapter) [U].
7. **Proxy**: none.
8. n/a.

Measured 2026-10-19 05:40–06:30 UTC from an Israeli vantage. [V] = verified live that day, [U] = unverified.
"wire" = bytes on the wire with `Accept-Encoding: gzip`; "raw" = decoded JSON.

## ztm-poznan

**1. How the adapter loads a line today** [V, code + live]
- `lines(atStop:)`: `POST https://www.peka.poznan.pl/vm/method.vm?ts=<ms>` form `method=getBollardsByStopPoint&p0={"name":"<stop name>"}`,
  then `getBollardsByLine {"name":"<line>"}` per line. Line id = `"<line>|<headsign>|<PEKA direction name>"`,
  `providerRefs = ["line": "169", "pattern": "Łużycka", "bollard": "RKAP73"]`.
- `routePattern(for:)`: `getBollardsByLine {"name": line}` (cached 1 h) → the direction whose
  `direction.direction == providerRefs["pattern"]`, bollards sorted by `orderNo`; coordinates from the
  poznan.pl map layer `GET https://www.poznan.pl/mim/plan/map_service.html?mtype=pub_transport&co=cluster`
  (675 KB raw / 82 KB wire, 12.7 s from IL), keyed by PEKA `tag`.
- No shape id, trip id or variant id is in hand. PEKA knows only two "directions" per line.

**2. Shape recipe: no live shape exists → offline from ZTM's GTFS (0 calls to ZTM at runtime; 1 static
fetch from our host).** [V]
- PEKA VM has no geometry method (checked the method lists used by PozNode, MMM-pekavm, Gdzie-ta-bimba,
  skotniczny/peka, pyrkowy-gtfs-rt: getStopPoints, getBollardsByStopPoint, getBollardsByLine, getTimes,
  getLines, findMessagesForBollard). The poznan.pl map service only offers stop layers (`co=cluster|show|print`).
- **ZTM Poznań GTFS has `shapes.txt`** [V]: `GET https://www.ztm.poznan.pl/pl/dla-deweloperow/getGTFSFile`
  → `Content-Disposition: filename="20261019_20261031.zip"`, 11.2 MB zip (90 MB unzipped; shapes.txt 14.5 MB,
  stop_times 72.5 MB). Download took **268 s** (≈40 KB/s) — far too slow and too big for the phone.
  Archive of all feeds: `https://www.ztm.poznan.pl/otwarte-dane/gtfsfiles/` (`getGTFSFile/?file=<name>.zip`).
  1,796 shapes over 213 routes; shapes are per variant (`trips.shape_id`), points in lat,lon, decimal.
- **Id mapping is exact** [V]: GTFS `stops.stop_code` == PEKA bollard `tag` (e.g. `OSKO02`), and
  `routes.route_short_name` == PEKA `lineName`; `trips.trip_headsign` == PEKA `direction.direction`
  (16/16 directions sampled).
- **Pick rule** (verified on 16 directions of lines 169, 12, 16, 174, 191, 911, 348, 5): among GTFS shapes with
  `route_short_name == line` and `trip_headsign == PEKA direction`, take the one used by the most trips. Its
  stop codes were a subset of the PEKA direction's bollards in 16/16 cases.
- Pipeline output per (line, PEKA direction): `{ "codes": [GTFS stop_code order of the main variant],
  "polyline": <precision-5 encoded> }`, keyed `ztm-poznan/<line>/<sha1(direction name)>.json`. Also emit each
  short-turn variant (keyed by sha1 of its stop-code list) if the app ever shows variants.

**3. Format / decoding — and an adapter bug this exposed** [V]
- **PEKA's `getBollardsByLine` direction is not a trip: it is the union of all variants of that direction, and
  `orderNo` restarts per branch.** Sorting by `orderNo` (what `routePattern` does) interleaves branches:
  - tram 16 "Os. Sobieskiego": `GLHE72, FRWO42, RYLA72, SZWA42, PAWI72…` — depot-variant bollards
    (Głogowska/Hetmańska) alternate with the main route; 12 duplicated orderNos.
  - bus 174 "Os. Sobieskiego": `(1 MAGA01) (1 UNLU02) (2 GABA01) (2 FALI01)…` — two branches zipped
    together, 18 duplicated orderNos; stop chords add up to 213 km for a 17 km route.
  - Lines with duplicates in the sample: 12 (19/21), 16 (12/3), 174 (18/1), 5 (14/13), 911 (0/1);
    clean: 169, 191, 348. So **about half of the lines draw a zig-zag stop list today**, shape or not.
- Consequence: the PEKA stop list FAILS shapecheck against any real shape for those lines (table below). The
  fix belongs with the shape file: ship the GTFS main-variant stop-code order with the polyline, and have
  `routePattern` use that order (bollard coordinates still from the map layer) when it is available.
- Short-turn variants: the adapter folds every short-turn headsign into the main direction, so the main
  shape is the right one to draw. A short-turn variant's stops on the main shape pass the offset test but fail
  the length test (169: ratio 2.7) — if variants are ever shown, trim the main shape between the first and
  last stop's projections, or use the variant's own shape (618397 for 174 from Małe Garbary: PASS).
- Terminal loops: a tram loop terminus can sit beyond where the GTFS shape begins (tram 16, FRWO42, 60 m).
  Fix: let the check allow ≤100 m on the first/last stop, or prepend the stop to the polyline.

**4. Live verification** [V] (stops = adapter's coordinates from the poznan.pl map layer)

| line / direction | stop list | shape | pts | max / median offset | ratio | verdict |
|---|---|---|---|---|---|---|
| 169 → Łużycka | PEKA (clean) | GTFS 618257 | 219 | 15.2 / 8.7 m | 1.17 | PASS |
| 169 → Os. Kopernika | PEKA (clean) | GTFS 618258 | 215 | 14.2 / 7.4 m | 1.10 | PASS |
| 174 → Os. Sobieskiego | GTFS main codes | 618268 | 282 | 15.7 / 8.8 m | 1.17 | PASS |
| 174 short (Małe Garbary → Os. Sobieskiego) | GTFS variant codes | 618397 | 129 | 15.7 / 9.5 m | 1.10 | PASS |
| tram 16 → Franowo | GTFS main codes | 622242 | 276 | 37.3 / 5.5 m | 1.08 | PASS |
| tram 16 → Os. Sobieskiego | GTFS main codes | 622241 | 280 | 60.4 / 5.8 m | 1.08 | FAIL (terminus loop, see 3) |
| 174 → Os. Sobieskiego | **PEKA merged** | 618268 | 282 | ∞ (33 far) | 0.08 | FAIL (PEKA order, see 3) |
| 16 → Os. Sobieskiego | **PEKA merged** | 622241 | 280 | ∞ (28 far) | 0.11 | FAIL (PEKA order) |
| 174 → Unii Lubelskiej | PEKA (1 dup: MAGA02/MAGA03) | 618267 | 259 | 79.1 / 6.5 m | 1.11 | FAIL (alternate bollard MAGA03) |
| 169 → Łużycka, full stops | PEKA | short-turn 620386 | 121 | ∞ | 0.55 | FAIL (wrong variant — expected) |

- Size: precision-5 polyline of a 14 km line (219 pts) ≈ 1–2 KB; served from our static host.
- Latency: one static GET; ZTM itself is not called at runtime. PEKA `getBollardsByLine` (already called)
  measured 0.9–16 s from IL (wire 5.7–10.7 KB).

**5. Cache key + change detection**
- GTFS `shape_id` is NOT stable: each feed carries two copies per variant (618257 and 620261 are identical
  geometry, different calendars), and ids change with every feed. Key the hosted file by
  `ztm-poznan/<line>/<direction name>` and include the stop-code list's sha1 inside; the app keeps it until
  PEKA's bollard set for that direction stops containing the file's codes, re-validating weekly.
- Feed-change signal for the pipeline [V]: `getGTFSFile`'s `Content-Disposition` filename
  (`20261019_20261031.zip`), and the listing at `/otwarte-dane/gtfsfiles/`. New feeds appear every 1–2 weeks.

**6. Limits / terms** — No documented rate limit for PEKA or the GTFS download [U]. The GTFS host is slow
(40 KB/s) — the pipeline should fetch it once per new filename. Licence: ZTM Poznań open data, attribution
"ZTM Poznań" [U: no licence text found on the developer pages]. Drawing GTFS shapes is the feed's purpose.

**7. Proxy changes** — none (keyless). The pipeline host needs no key.

**8. Offline source** — URL `https://www.ztm.poznan.pl/pl/dla-deweloperow/getGTFSFile` (current feed) or
`.../getGTFSFile/?file=<YYYYMMDD_YYYYMMDD>.zip`; 11.2 MB; **has shapes.txt** (no pfaedle needed); ids map
1:1 (stop_code = PEKA tag, route_short_name = line, trip_headsign = PEKA direction name).

## ztm-gdansk

**1. How the adapter loads a line today** [V]
- Per service day (cached): `GET https://ckan2.multimediagdansk.pl/stops?date=YYYY-MM-DD` (1.19 MB) and
  `/trips?date=` (283 KB; `{routeId, tripId, tripHeadsign, directionId, type: MAIN|SIDE|NON_PASSENGER, activationDate}`).
- `lines(atStop:)`: `/departures?stopId=` → line id `"<routeId>-<directionId>"`,
  `providerRefs = ["route": "199", "direction": "1", "trip": "121" (the MAIN variant if present), "stop": "1016"]`.
- `routePattern(for:)`: `/stopsInTrip?date=&routeId=&tripId=` (5.7–7.6 KB) → ordered stops; each row also
  carries `topologyVersionId` and `tripActivationDate`.

**2. Shape recipe: 1 extra call per cold line** [V]
- `GET https://ckan2.multimediagdansk.pl/shapes?date=<same date>&routeId=<providerRefs.route>&tripId=<providerRefs.trip>`
  — same (date, routeId, tripId) triple `routePattern` already sends. Not piggybackable (separate endpoint) but
  can run in parallel with `stopsInTrip`, so cold-line latency stays ≈ max(two calls).
- Officially published: the ZTM dataset's resource "Lista przebiegów tras" (`.../download/shapes.json`,
  1.15 MB) is just a per-date list of these exact `ckan2.../shapes?date=&routeId=&tripId=` URLs. So the
  endpoint is documented by the operator, not merely found.

**3. Format** [V] — GeoJSON `{"type":"LineString","coordinates":[[lon,lat],…],"properties":{"date","routeId","tripId"}}`.
**lon,lat order**, 5 decimals (~1 m). One LineString per variant, already in travel order; no stitching or
reversing. Variants: the shape is per tripId (variant), and the adapter already picks the MAIN variant.

**4. Live verification** [V]

| line (routeId/tripId) | variant | pts | stops | max / median offset | ratio | verdict | raw | latency |
|---|---|---|---|---|---|---|---|---|
| 199 / 121 Oliwa PKP → Jana z Kolna | MAIN | 937 | 39 | 14.2 / 7.0 m | 1.19 | PASS | 18.6 KB | 0.56–0.98 s |
| 199 / 82 Jana z Kolna → Biały Dwór | SIDE (short-turn) | 729 | 30 | 12.2 / 7.4 m | 1.14 | PASS | 14.5 KB | 1.49 s |
| 111 / 121 Dworzec Główny → Górki Zachodnie | SIDE "REMONT" (works diversion) | 833 | 30 | 10.6 / 6.6 m | 1.19 | PASS | 16.5 KB | 0.59 s |

- No gzip: wire size == raw size (18,605 B with `Accept-Encoding: gzip`). Re-encoded as a precision-5
  polyline it is ≈2–3 KB.

**5. Cache key + change detection** [V]
- Key: `ztm-gdansk/<routeId>/<tripId>/<activationDate>` — `activationDate` comes from the `trips?date=` list
  the adapter already downloads daily (`R199T121 … activationDate 2026-10-17`), and equals `stopsInTrip`'s
  `tripActivationDate`. **Zero-cost change signal:** if the day's trip list shows a new `activationDate` for
  (route, trip), refetch; otherwise keep. The same (route, trip) returned byte-identical geometry for
  2026-10-19 and 2026-10-29.
- `topologyVersionId` (2731) is also in `stopsInTrip` and could be added to the key.
- No ETag; responses have no `Cache-Control` for `/shapes` [V].

**6. Limits / terms** — Regulamin (2024-01-08): reuse allowed with source credit "Zarząd Transportu Miejskiego
w Gdańsku" + portal URL; no rate limit stated [V per adapter notes; the PDF was not re-read today]. The
adapter's attribution string already satisfies it. Drawing is allowed (it is the published route-course data).

**7. Proxy changes** — none (keyless).

**8. Offline source (backup)** — GTFS `.../download/gtfsgoogle.zip` (29.8 MB, Last-Modified daily) [V size;
shapes.txt presence U]. Not needed.

## mpk-krakow

**1. How the adapter loads a line today** [code]
- Stop layer `GET https://ttss.mpk.krakow.pl/internetservice/geoserviceDispatcher/services/stopinfo/stops?left=…`
  (daily); `lines(atStop:)`: `services/passageInfo/stopPassages/stop?stop=<shortName>&mode=departure&timeFrame=120`
  → line id `"<routeId>-<direction>"`, `providerRefs = ["route", "direction", "trip" (TTSS tripId, the latest
  passage), "stop"]`.
- `routePattern(for:)`: `services/tripInfo/tripPassages?tripId=<trip>&mode=departure` (remaining stops; retried
  with a fresher trip if the first has already left).
- Trip id in hand: TTSS `tripId` (a 19-digit number). No route-variant or shape id.

**2. Shape recipe: 1 extra call per cold line** [U for Kraków — host unreachable; format V on another TTSS]
- `POST https://ttss.mpk.krakow.pl/internetservice/geoserviceDispatcher/services/pathinfo/trip?id=<providerRefs.trip>`
  (query-string param on a POST with empty body, as manniwatch and kiel-live do; GET is probably accepted too [U]).
- Same trip id `routePattern` uses, so the shape belongs to exactly the stop pattern shown. Can run in
  parallel with `tripPassages`.
- **Kraków was unreachable all session**: 4 requests between 07:40 and 08:00 Warsaw time (daytime) to
  `/`, `stopPassages`, `vehicles` and `stops` all returned **HTTP 503** "Server Unavailable! … Client IP
  192.168.201.1" (an upstream WAF/load-balancer block page, 57 KB HTML). Since the same host answered from IL
  on 2026-09-28, this is either a new geo/WAF block or an outage — it must be re-tested from an EU vantage.
  If it is a geo block, the whole adapter (not just shapes) is affected for non-PL users.

**3. Format** [V on KVG Kiel's Trapeze TTSS, the same product: `kvg-internetservice-proxy.p.networkteam.com/internetservice`]
- `{"paths":[{"color":"#9e1981","wayPoints":[{"lat":195700633,"lon":36277564,"seq":"1"},…]}]}`;
  `lat`/`lon` are **integer milliarcseconds** (÷ 3,600,000), same unit as the stop layer; `seq` is a string —
  sort numerically. One path per trip in the sample (manniwatch/kiel-live read `paths[0]`); if more than one
  path appears, concatenate in array order [U].
- Kiel sample (line 81, 35 stops, 685 waypoints, 54 KB raw / 7.4 KB wire, 1.6 s): max offset 112 m,
  median 4.3 m, ratio 1.04 → FAIL on 3 stops (first stop 112 m from the path start; two mid-route at
  64–89 m). The path itself follows the roads; the misses are the TTSS **stop-area** coordinates (one point per
  stop area, not per platform), which is also what the Kraków adapter uses. Kiel-specific, not proven for
  Kraków. Mitigation if it recurs: allow 120 m for TTSS stops in the check, or snap stops onto the path.

**4. Live verification** — Kraków: **not possible** (503, see 2). Format verified on Kiel only (above).
Fallback (ZTP GTFS shapes) verified in 8: 16/16 PASS, max 17.5 m.

**5. Cache key + change detection** — TTSS trip ids are per-day runs, not stable. Key by
`mpk-krakow/<routeId>/<direction>/<sha1 of the stop shortName list>`; refetch when `tripPassages` yields a
different stop list; revalidate weekly. No cheap change signal in TTSS [U].

**6. Limits / terms** — No published terms or rate limits (unofficial backend). Clients poll every 10–20 s
without issue (jacekkow/mpk-ttss). Attribution "MPK S.A. w Krakowie" as today. [U]

**7. Proxy changes** — none (keyless). If the 503 is a geo block, a proxy in PL/EU would be needed for the
whole provider, not a path allow-list change.

**8. Offline source** [V] — ZTP's official GTFS: buses `https://gtfs.ztp.krakow.pl/GTFS_KRK_A.zip`
(16.7 MB, Last-Modified 2026-10-16), trams `GTFS_KRK_T.zip` (4.1 MB). **The bus feed has `shapes.txt`**
(29.1 MB raw / 6.1 MB compressed) — read from the zip's central directory with an HTTP range request.
- Id mapping: GTFS `stop_code` is `<area>-<post>` ("501-01" Rondo Grunwaldzkie) — the area number is **not**
  the TTSS `shortName` (3338). Map by route_short_name + direction headsign + the sequence of stop *names*
  (TTSS `stop.name` ↔ GTFS `stop_name`), or match each TTSS stop to the nearest GTFS stop of the same name.
  GTFS trip ids are unrelated to TTSS trip ids.
- Fallback quality check [V, GTFS stops vs GTFS shapes, since TTSS stop coordinates were unreachable]
  (full zip downloaded once: 16.7 MB in 431 s):

  | line / shape | variant | pts | max / median offset | ratio | verdict |
  |---|---|---|---|---|---|
  | 179 → Kurdwanów Południe / 328015 | main (459 trips) | 591 | 9.3 / 6.7 m | 1.06 | PASS |
  | 179 → Dworzec Główny Zachód / 328011 | main (457 trips) | 504 | 11.7 / 6.1 m | 1.07 | PASS |
  | 144 → Rżąka / 327875 | main | 683 | 9.9 / 7.1 m | 1.09 | PASS |
  | 125, all 13 shapes incl. "przez: Nad Drwiną" detour variants | main + via | 496–593 | ≤ 17.5 / ≤ 7.1 m | 1.09–1.11 | 13/13 PASS |

  GTFS `trip_headsign` uses the same "X przez: Y" form TTSS shows in vehicle names, so the TTSS
  `direction` + route name should select the variant [U]. shape_ids are per calendar (several identical
  copies), so key the hosted file by route + headsign + stop-name list, not shape_id.

## wienerlinien

**Decision:** the live WL OGD routing service (an EFA run by VOR) answers `XML_GEOOBJECT_REQUEST` per line **and
direction**: 1 extra call, no proxy. The offline WL GTFS (`shapes.txt` per variant and direction) is the fallback
when that call's variant doesn't match the adapter's stop list.

### 1. How the adapter loads a line today
- Everything is local after three OGD CSVs (`wienerlinien-ogd-haltepunkte|linien|fahrwegverlaeufe.csv`,
  ~1.85 MB, uncompressed, once per session) plus the realtime `monitor?stopId=<RBL>` [V 2026-10-19].
- `lines(atStop:)` → `TransitLine.id = "<LineID>:<Direction>"` (e.g. `413:1` = 13A towards Hauptbahnhof);
  `providerRefs = [lineId, direction (1|2), rbl]`.
- `routePattern(for:)` → the **longest** CSV variant (`PatternID`) of that line+direction through `rbl`: ordered RBLs
  with coordinates from `haltepunkte` (which also carries the stop's **DIVA**, e.g. RBL 669 → DIVA 60201018).
- No geometry of any kind is fetched today. The WFS `OEFFLINIENOGD` was rejected earlier (merges both directions).

### 2. Shape recipe (1 extra call per cold line)
```
GET https://www.wienerlinien.at/ogd_routing/XML_GEOOBJECT_REQUEST
    ?outputFormat=rapidJSON&coordOutputFormat=WGS84%5Bdd.ddddd%5D&line=vor:2313A:%20:H:j26
→ transportations[0].coords  (pieces of [lat,lon]) + transportations[0].locationSequence (stops)
```
- Build the EFA line id from data in hand, `vor:2<mode><name, left-padded with 0 to 3 chars>: :<H|R>:j<yy>`:
  - mode digit: 1 = U-Bahn (`vor:210U4`), 2 = tram (`vor:22006` = 6), 3 = city bus (`vor:2313A` = 13A,
    `vor:2302A` = 2A), 4 = night bus (`vor:24N60`). [V 2026-10-19 on U4, U6, 6, 18, 12A, 13A, 14A, 2A, 57A, 48A, N60, N71]
  - CSV `Direction` 1 → `H`, 2 → `R`. [V for 13A, 6, 2A]
  - `j26` = "Jahresfahrplan 2026", `validity 2025-12-14 … 2026-12-12` (in the serving-lines reply). It becomes `j27`
    at the December timetable change. [V]
  - If the derived id 404s or comes back empty, get the exact id with 1 more call:
    `XML_SERVINGLINES_REQUEST?outputFormat=rapidJSON&type_sl=stopID&name_sl=<DIVA of the rider's RBL>&mode=odv`.
    That makes 2 calls. [V]
- Stitch the pieces with the same algorithm as EFA Linz (below; `efa_stitch2.py`). WL replies had 1–4 pieces.
- Map EFA stops to RBLs: `locationSequence[].id = "at:49:<DIVA − 60200000>:0:<platform>"` (60201018 → `at:49:1018`).
  For 13A and 2A the EFA DIVA sequence equals the CSV variant (PatternID 1) exactly. [V]

### 3. Format and decoding
- Coordinates are `[lat, lon]` at 6 decimals. Pieces are unordered and can come in either orientation; stitch them.
- There is **one transportation per line+direction**: the EFA's own main variant. It can differ from the adapter's
  "longest CSV variant":
  - Tram 6 H returned the Geiereckstraße variant (22 stops) [V].
  - The adapter's main pattern for 6 dir 1 is PatternID 20 to *Zentralfriedhof 3.Tor* (29 stops), and PatternID 120
    for dir 2. Neither appears in the current GTFS, so the adapter shows a stale/diversion variant.
  - Several CSV variants of tram 6 (132, 25, 13) are diversions via Hauptbahnhof/Quartier Belvedere that match no
    current shape. **Adapter issue, out of scope:** "longest variant" is a poor choice for WL. The lowest PatternID
    (`isRegular`'s base) matched the current shapes for 13A, 2A and 6 R.
- Choosing the pattern: run shapecheck against the adapter's pattern. On FAIL, use the offline GTFS shape (§8) or
  show stops only.

### 4. Live verification (2026-10-19) [V]
Stops are as the adapter builds them (CSV variant, RBL coordinates); the shape is the stitched EFA geo object.

| line / dir | CSV pattern | EFA shape vs pattern | size gz / raw | latency |
|---|---|---|---|---|
| 13A H (dir 1, fixture stop 669) | PatternID 1, 18 stops (adapter's choice) | **PASS** max 11.4 m, median 5.2 m, ratio 1.10, 129 pts | 2.8 / 12.8 KB | 9.8 s |
| 2A H (short, 7 stops) | PatternID 1 (adapter's choice) | **PASS** max 7.3 m, median 4.1 m, 46 pts | 1.4 KB gz | 2.3 s |
| tram 6 R (variants) | PatternID 2, 19 stops | **PASS** max 9.9 m, median 4.0 m, 213 pts | 3.7 / 16.8 KB | 1.5 s |
| tram 6 H (variants) | PatternID 1, 18 stops | **FAIL** max 65.2 m (stops 13 and 17) | 3.6 / 16.9 KB | 4.1 s (one earlier attempt timed out at 11 s) |
| tram 6 H / R | adapter's choice (PatternID 20 / 120, Zentralfriedhof) | **FAIL**: the variant doesn't run; the shape covers 22 of 29 stops | | |

**Diagnosis of 6 H:**
- The terminus RBL 3441 (Geiereckstraße) lies 65 m from where **both** the EFA shape and the GTFS shape end: a
  terminal loop or stop-coordinate offset, not a shape error.
- Stop 13 (Reumannplatz) sits next to a 54 m stitching gap / splice in the EFA pieces.
- Fix: allow terminal stops up to ~100 m in shapecheck, or fall back to the GTFS shape, which fails only at the
  terminus (65.1 m).

**Cross-check against the offline GTFS shapes** (matched geometrically, best shape per pattern):

| line | best shape | result |
|---|---|---|
| 13A H | `23-13A-j26-1.1.H` | PASS 11.3 m |
| 2A H | `23-2A-j26-4.3.H` | PASS 7.3 m |
| 6 R, PatternID 2 | `22-6-j26-2.12.R` | PASS 9.9 m |
| 6 H, PatternID 1 | `22-6-j26-1.8.H` | FAIL 65.1 m, terminus only |

The EFA and GTFS geometry are the same data (13A: 5,227 m in both).

### 5. Cache key and change detection
- **Key:** `wienerlinien/<EFA line id incl. jYY>/<sha1 of the pattern's RBL list>`, for example
  `vor:2313A: :H:j26` + sha1(RBLs).
- **Change signals:**
  - the `jYY` suffix or the serving-lines `properties.validity.to` (yearly, December);
  - the adapter's CSV stop list for the pattern changes.
- No ETag or Last-Modified was seen on ogd_routing [U].
- **TTL:** keep until the stop list or `jYY` changes; revalidate at most weekly.

### 6. Rate limits and terms
- **Realtime OGD:** keyless, CC BY 4.0, "Datenquelle: Stadt Wien – data.wien.gv.at". Fair use asks for polls ≥ 15 s
  apart; abuse gets an IP block (adapter header) [V doc].
- **`ogd_routing`:** keyless, served by `serverID VOR-OGD02-PR` (VOR's EFA) [V]. No documented quota found [U].
  Wiener Linien documented an EFA routing service under OGD (`data.wien.gv.at/pdf/wiener-linien-routing.pdf`,
  referenced in 2016 forum posts; could not open) [U].
  - Treat it as CC BY 4.0, same credit line [U].
  - Latency is high and variable: 1.5–9.8 s, and one request timed out with no response.
  - Drawing CC BY geometry is allowed with attribution.
- **GTFS:** same OGD licence [U].

### 7. Proxy changes
None. Keyless, and it is not routed through `functions/src/agencies.ts`.

### 8. Offline source (fallback, for the pfaedle/offline agent)
- **URL:** `https://www.wienerlinien.at/ogd_realtime/doku/ogd/gtfs/gtfs.zip`.
  - Content-Length 95,840,377 B (**95.8 MB**), zip64, `Range` ignored. [V]
  - Server throttled to ~210 KB/s. The first attempt hit our 300 s timeout at 63 MB; the two retries returned nothing
    (status 000). The pipeline needs a long timeout and retries.
- **Has `shapes.txt`** [V]: 73.2 MB raw / 11.9 MB compressed, 6,348 shapes, with `shape_dist_traveled`.
  `stop_times.txt` is 747 MB raw.
- **Ids:**
  - `route_id = "<2-digit mode>-<line>-j26-<n>"` (e.g. `23-13A-j26-1`; `22-6-j26-5` is the "ESC" event variant).
  - `shape_id = "<route_id>.<k>.<H|R>"`, so direction is in the id.
  - `trip_id = "<n>.T0.<shape_id>"`, so the shape is derivable from the trip without `trips.txt`.
  - `stop_id = "at:49:<DIVA−60200000>:0:<platform>"`.
  - Mapping to the adapter: DIVA → `haltepunkte` RBLs; if one DIVA has several RBLs, pick by nearest coordinate.
- **Pipeline:** for each GTFS shape, take its trips' stop sequence (stop_times), convert to RBLs, and publish one
  file per `sha1(RBL list)`. The app looks it up with the CSV pattern's RBL list.
  - Diversion variants in the CSV that are absent from the GTFS (e.g. tram 6 PatternID 20/120/132) get no shape:
    show stops only.

## efa-linz

**Decision:**
- **0 extra calls:** stitch `transportations[0].coords` from the `XML_GEOOBJECT_REQUEST` that `routePattern` already
  downloads.
- **Fallback, 2 calls** (`XML_DM_REQUEST` limit 1 + `XML_STOPSEQCOORD_REQUEST`): when the stitched shape fails
  shapecheck. The trip's `leg.coords` is one ordered polyline with the trip's own stop list.

### 1. How the adapter loads a line today
- `lines(atStop:)`: `XML_SERVINGLINES_REQUEST?type_sl=stopID&name_sl=<DHID>&mode=odv`.
  `TransitLine.id = EFA line id` (e.g. `esg:02027:E:H:f26`), `providerRefs["stop"]` = the rider's DHID.
- `routePattern(for:)`: `XML_GEOOBJECT_REQUEST?line=<id>&outputFormat=rapidJSON&coordOutputFormat=WGS84[dd.ddddd]`
  (base `https://www.linzag.at/linz2/efaAPI/`). Stops are `transportations[].locationSequence`, collapsed by stop
  area.
- If no transportation contains the rider's stop, `tripPattern` runs `XML_DM_REQUEST` (limit 1) and then
  `XML_STOPSEQCOORD_REQUEST?line&tripCode&stopID&date&time&tStOTType=all`, using `leg.stopSequence`.
- Ids in hand: the line id and the stop DHID; the tripCode only on the fallback path.

### 2. Shape recipe
- **0 extra calls** [V]: decode `transportations[0].coords` from the reply `routePattern` already fetched. Linz
  returned exactly one transportation for all 9 lines tried.
- **Fallback, 2 calls** [V]: DM (`limit=1`, `line=<id>`) for the `tripCode` and planned time, then
  `XML_STOPSEQCOORD_REQUEST?line=<id>&tripCode=<tc>&stopID=<parent DHID>&date=YYYYMMDD&time=HHMM&tStOTType=all&outputFormat=rapidJSON&coordOutputFormat=WGS84[dd.ddddd]`.
  - `leg.coords` is a **single ordered** `[[lat,lon]…]` list; `leg.stopSequence` is that trip's stops.
  - It costs 0 extra calls when the adapter already took its `tripPattern` path.
- When the fallback is used, also replace the pattern's stops with `leg.stopSequence` (see §3, merged stop list).

### 3. Format, decoding, and the stitching algorithm
- `coords` = list of pieces, each `[[lat, lon], …]` (6 decimals, lat first). They are unordered, in either
  orientation, and are the **union of the line's variants**:
  - pieces split where variants diverge;
  - detour pieces are present;
  - turn-around stubs after the terminus;
  - occasionally a short missing link (61 m on line 27).
- **Algorithm** (`scripts-c/efa_stitch2.py`, ~60 lines, O(pieces² + stops·points)):
  1. **Clean:** drop pieces with fewer than 2 points, exact duplicates, and reversed duplicates.
  2. **Anchor:** the piece end nearest the first stop starts the chain (reverse that piece if its far end is nearer).
  3. **Chain greedily:** append the unused piece whose nearer end is within GAP = 30 m of the tail, reversed when
     needed, merging the shared vertex.
     - If nothing touches and the tail is within DONE = 60 m of the last stop, stop: the leftovers are spurs or
       turn loops.
     - Otherwise bridge to the nearest piece end and log the gap.
  4. **Splice detours:** for each stop more than 50 m off the chain, take an unused piece within 50 m of that stop.
     Find the chain vertices nearest its two ends (both within 150 m), orient the piece so a < b, and replace
     `chain[a..b]` with the piece.
  5. Drop the remaining pieces, then run shapecheck. FAIL → fallback (§2).
- **Linz geo-object quirk** [V]: `locationSequence` is a **merge of the variants' stop lists**, not one variant.
  - Tram 3 H appends the depot branch "Unionkreuzung … Remise Kleinmünchen" (10 stops) *after* the terminus Trauner
    Kreuzung.
  - Line 19 R lists both Leonding branches (via Turm 9 and via Aichbergstraße) in sequence.
  - Line 27 R appends Hafenportal (a variant-only stop) at the end.
  - The adapter turns these straight into the `RoutePattern`, so those patterns are wrong. **Adapter issue, out of
    scope.** The shape fails there only because no single path visits those stops in that order.

### 4. Live verification (2026-10-19) [V]
**Piggyback: stitched geo `coords` vs the geo's own stop list, exactly as the adapter collapses it**

| line | pieces | stitch notes | shapecheck | gz / raw | latency |
|---|---|---|---|---|---|
| 26 H (fixture) | 2 (reversed order) | — | **PASS** max 12.1 m, median 5.1 m, ratio 1.14 | 4.0 / 16.1 KB | 1.8 s |
| tram 1 H | 1 | — | **PASS** 6.2 m | 5.8 KB gz | 1.8 s |
| tram 4 R | 2 (turn stub dropped) | — | **PASS** 3.8 m | 6.8 KB gz | 1.8 s |
| 11 H | 7 | 1 dropped | **PASS** 32.8 m | 7.2 KB gz | 1.6 s |
| 194 H | 1 | — | **PASS** 8.6 m | 5.6 KB gz | 3.1 s |
| 27 H (detour variant) | 4 | detour piece spliced, 61 m bridge | **PASS** 13.6 m (78.8 m FAIL without the splice) | 7.1 KB gz | 2.3 s |
| tram 3 H (branch) | 2 | — | **FAIL**: merged stop list (depot branch after the terminus) | 7.9 KB gz | 3.9 s |
| 19 R (branch) | 6 | — | **FAIL** at stops 39–41: merged stop list (two branches) | 12.9 KB gz | 2.7 s |
| 27 R | 2 | — | **FAIL** 75.4 m: Hafenportal appended at the end of the merged list | 6.5 KB gz | 8.5 s |

**Fallback: trip `XML_STOPSEQCOORD_REQUEST` `leg.coords` vs `leg.stopSequence`**

| line | result | gz / raw | latency (+ DM) |
|---|---|---|---|
| 27 H | **PASS** 13.6 m, 608 pts | 8.3 KB gz | 2.6 s (+ 3.6 s) |
| 19 R | **PASS** 12.1 m, 1,091 pts, 55 stops | 13.3 / 62.8 KB | 1.5 s (+ 2.2 s) |
| tram 3 H | **PASS** 5.2 m, 583 pts, 24 stops (no depot branch) | 7.0 / 30.0 KB | 2.3 s (+ 1.5 s) |

The trip shape of 27 H is the same path as the stitched geo chain (14,193 m in both).

### 5. Cache key and change detection
- **Key:** `efa-linz/<line id>/<sha1 of the pattern's stop DHIDs>`.
  - The line id carries the timetable period (`…:f26`); reading `f26` as the 2026 period is [U].
  - Do not key by tripCode: it is per trip and per day.
- **Change signal:** the line id suffix changes at the timetable change, or the pattern's stop list changes. No
  ETag or cache headers seen [V].
- **TTL:** keep until the stop list or the suffix changes; revalidate at most weekly.

### 6. Rate limits and terms
- Keyless. LINZ AG publishes its EFA as Open Government Data, CC BY 4.0 (data.linz.gv.at), credit "Datenquelle:
  LINZ AG LINIEN" (adapter comment; worldwide-apis.md §5.7) [U, not re-read today].
- No published quota and no rate-limit headers [V, none seen]. Drawing CC BY geometry is allowed with attribution.
- Latency is slow: 1.6–8.5 s for the geo object, 1.5–3.6 s for DM and STOPSEQCOORD.

### 7. Proxy changes
None. Keyless, and it is not routed through the proxy.

### 8. Offline
Not needed: a live shape exists for every line tested.

### Request log
- efa-linz: ~24 requests.
- wienerlinien: ~20 requests: 3 CSVs, 2 serving-lines, 5 geo objects (1 timed out), 1 stopfinder, catalog/GTFS attempts.
- All ≥ 1 s apart, with UA `BusBus-research/1.0 (you@example.com)`. No 429 or 403.

**Files:**
- Downloads: `/private/tmp/claude-501/-Users-amir-Developer-BusBus/679ea7dd-05fc-4173-ad13-8f8bc473d67a/scratchpad/regions/dl/efa-linz/` and `/private/tmp/claude-501/-Users-amir-Developer-BusBus/679ea7dd-05fc-4173-ad13-8f8bc473d67a/scratchpad/regions/dl/wienerlinien/`
  (`gtfs_partial.zip` holds the complete `shapes.txt` and `routes.txt`).
- Scripts: `/private/tmp/claude-501/-Users-amir-Developer-BusBus/679ea7dd-05fc-4173-ad13-8f8bc473d67a/scratchpad/regions/scripts-c/`
  (`efa_stitch2.py`, `efa_trip.py`, `wl_check.py`, `wl_gtfs_match.py`).

## lpp-ljubljana

1. **How the adapter loads a line today** [V 2026-10-19, code read]
   - `lines(atStop:)` → `GET https://data.lpp.si/api/station/routes-on-station?station-code={ref_id}`.
     `TransitLine.id` = LPP `trip_id` (one sub-route = one direction + variant, e.g. 6 → ČRNUČE);
     `providerRefs["routeId"]` = LPP `route_id` (the route group, e.g. all of line 6), `providerRefs["stationCode"]`.
   - `routePattern(for:)` → `GET /api/route/stations-on-route?trip-id={line.id}` (stops with lat/lon, `order_no`).
     That reply has no geometry (documented fields: name, station_code, station_int_id, order_no, latitude, longitude).
2. **Shape recipe: 1 extra call per cold route group** [V]
   - `GET https://data.lpp.si/api/route/routes?route-id={providerRefs["routeId"]}&shape=1` (documented `shape`
     flag in data.lpp.si/doc `api_data.js`).
   - Returns every sub-route (`trip_id`) of the route group with `geojson_shape`. Pick the entry whose
     `trip_id` equals `line.id` (case-insensitive). One reply covers both directions and every variant
     (incl. "obvoz" detour variants), so cache all of them: the opposite direction is then free.
   - No piggyback: `stations-on-route` has no shape option. `route/active-routes` also takes `shape` but lists
     every route (bigger, not needed).
3. **Format** [V]
   - `geojson_shape` is a real JSON object `{type:"LineString", coordinates:[[lon,lat],…], bbox}` — **lon/lat order**,
     full double precision, already in travel direction (no reversal needed). Dense: median vertex spacing 19 m.
   - Terminal quirk: at Dolgi most P+R the terminus stop sits 68 m from the shape's start/end (the stop is
     placed in the P+R lot, the shape starts on the road). Fix: if the first (last) stop is ≤150 m from the
     shape's first (last) vertex, prepend (append) the stop coordinate. With that fix the line passes (12.7 m).
4. **Live verification** (stops via `stations-on-route` exactly as the adapter, shape via the recipe)
   | line / trip | variant | pts | max / median offset | verdict |
   |---|---|---|---|---|
   | 6 → ČRNUČE (811F5A86) | main | 336 | 68.3 / 10.6 m | FAIL raw (stop 0, P+R terminus) → **PASS 12.7 / 10.4 m** with the terminal fix |
   | 6 → DOLGI MOST P+R (98FC3555) | main, reverse | 366 | 15.5 / 10.0 m | PASS |
   | 6B → BAVARSKI DVOR (BC82663A) | short turn (route has 5 sub-routes incl. 2 "obvoz") | 497 | 18.2 / 9.1 m | PASS |
   | 6B → BEŽIGRAD (9C0B4E6D) | variant | 534 | 18.2 / 9.1 m | PASS |
   | 18L ZOO-BEŽIGRAD (16C027D5) | variant | 341 | 16.5 / 6.2 m | PASS |
   | 18L ZOO-BEŽIGRAD (3BA47DC3) | sibling variant, same headsign | 333 | 13.7 / 6.2 m | PASS |
   - Payload: line 6 (2 sub-routes) 7.9 KB gzip / 28 KB raw; 18L (4) 8.7 / 56 KB; 6B (5) 13.7 / 105 KB.
   - Latency: 0.49 s (line 6), 4.4 s (18L), 6B 21.9 s then 8.7 s and 6.4 s. The server was slow for everything
     at that moment (the same 6B call **without** `shape` took 10.8 s, `stations-on-route` 9.5 s), so the
     shape is not the cost — LPP's backend is just erratic (worldwide-apis.md already notes a 60 s hang).
     Fetch the shape after the stops are shown, with a 30 s timeout.
5. **Cache key + change detection**
   - Key: `lpp-ljubljana/{trip_id}` (store all sub-routes of the reply, each by its trip_id; also index by
     `route_id` so one call fills the group).
   - No cheap change signal: the reply has no ETag / Last-Modified [V]. Whether LPP keeps `trip_id`s across
     timetable changes is [U].
   - Recommend: keep until the `stations-on-route` stop list (fetched anyway for the pattern) changes; re-validate
     at most weekly.
6. **Limits / terms**: none published (no licence, no rate limit; worldwide-apis.md §6.11) [V docs read]. Region
   is behind the experimental switch; keep the existing credit "Podatki: LPP d.o.o. (data.lpp.si)". Drawing the
   geometry: no terms either way [U].
7. **Proxy**: none — keyless, called direct.
8. n/a (live shape works). For the record, `GET /api/gtfs/feed.zip` 302-redirects to `avl.lpp.si/transit/api/gtfs`
   (not fetched).

## Pikas cities (tallinn, vilnius, kaunas) — common block

1. **How the adapter loads a line today** [V code read]
   - Once per session and city: `{dataURL}stops.txt` + `{dataURL}routes.txt`. Everything (stops, lines at a stop,
     pattern) is computed locally; `routePattern(for:)` makes **no network call**.
   - `TransitLine.id` = `"{transport}:{num}:{routeType}"` (e.g. `bus:9:a-b`); `shortName` = raw `RouteNum`
     (e.g. `43P (10.22)`); `providerRefs` = `family`, `num` (live number, date suffix stripped), `group`,
     `transport` (raw `Transport` column, e.g. `expressbus`), `type` (raw `RouteType`).
   - The adapter does **not** download the map file today.
2. **Shape recipe: 1 extra call per cold route number** (covers every direction and variant of that number) [V]
   - `GET {dataURL}{file}` where `file = ascii(city + "_" + transport + "_" + num) + ".txt"`, as in the sites'
     own `pg.loadPolyline` (planner.js): lowercase, strip diacritics, delete spaces, `*`→`@`.
     - `city` = the routes.txt `City` column, constant per installation: **`tallinna-linn`**, **`vilnius`**,
       **`kaunas`** (not the adapter's city id — Tallinn's file is `tallinna-linn_bus_9.txt`; `tallinn_bus_9.txt`
       is 404 [V]). Simplest: add a `mapCity` field to `PikasProvider.City`.
     - `transport` = `providerRefs["transport"]` with planner remaps: Tallinn `nightbus`/`eventbus`→`bus`;
       Kaunas `expressbus`→`bus`; Vilnius `commercialbus`/`autonomous`→`bus`, `festalbus`→`bus` + num `201`
       (none of these remapped values occur in today's routes.txt except as noted; Vilnius `expressbus` and
       `nightbus` keep their own names — `vilnius_expressbus_3g.txt`, `vilnius_nightbus_n1.txt` [V]).
     - `num` = `line.shortName` (raw RouteNum, **with** the date suffix: `kaunas_bus_43p(10.22).txt` [V]).
   - Examples: `https://transport.tallinn.ee/data/tallinna-linn_bus_9.txt`,
     `https://www.stops.lt/vilnius/vilnius/vilnius_trol_7.txt`, `https://www.stops.lt/kaunas/kaunas/kaunas_bus_23.txt`.
3. **Format** [V]
   - Text, records of 3 lines: `routeType` / Google encoded polyline / a per-vertex flag string (all `B`, same
     length as the vertex count; ignored by the site's renderer except for drawing).
   - Polyline: standard Google algorithm, **precision 5, lat then lon** (the site's `splitEncodedPolyline`).
     Already in travel direction.
   - Pick the record whose `routeType` equals `providerRefs["type"]` (compare case-insensitively). Every variant
     sampled had a record — 44 of 44 routeTypes across 9 files, including `a-b_67`, `a1-a-b`, depot runs and
     date-specific variants. No duplicate `(transport, num, routeType)` exists in any of the 3 routes.txt files,
     so the adapter's `#2` line-id suffix never collides with the map key [V].
   - The geometry is road-following with each stop as a vertex (stop offsets are exactly 0 m), median vertex
     spacing 25–58 m; long straight stretches are single segments (max 373–629 m), so curves on fast roads are
     slightly generalised [V by spacing; fidelity on those stretches U].
   - The site splits a file at the boarding stop for a leg (`splitEncodedPolyline` with start/end coords); we
     want the whole variant, so no split.
4. **Live verification**: see per-city tables. Stops = `routes.txt` RouteStops resolved through `stops.txt`
   (coords /1e5, `e`/`x` prefixes dropped), exactly as `PikasIndex`.
5. **Cache key + change detection**
   - Key: `{cityId}/{transport}/{num}/{routeType}` (one file → all variants of the number; cache the whole file).
   - Cheap signals, both already in hand: the variant's `RouteStops` string from routes.txt (downloaded every
     session — invalidate when it changes), and the routes.txt header version (`Pikas2026.9.12`).
     HTTP: stops.lt honours `If-None-Match` → **304** [V]; transport.tallinn.ee answered 200 to a conditional
     GET [V] (files are ~1–3 KB on the wire, so it does not matter).
   - Recommend: keep until RouteStops changes; re-validate weekly (Vilnius' Last-Modified moves daily even when
     content does not, so don't use it as a change signal).
6. **Limits / terms**: no published rate limit on either host (Cloudflare in front). These are the cities'
   own planner files, not a documented API. Tallinn: Tallinn open data, CC BY 4.0 assumed [U]; Vilnius: JUDU
   open-data terms (github.com/vilnius/transportas README asks re-users to refresh when stops.lt changes) [U for
   geometry specifically]; Kaunas: no terms found [U]. Keep the existing attribution strings.
7. **Proxy**: none — keyless, direct.
8. n/a.

## tallinn

- Base `https://transport.tallinn.ee/data/`, city slug `tallinna-linn` (routes.txt has only that city; transports
  `bus`, `trol`, `tram`).
- Verification [V 2026-10-19]:
  | file | variants checked | pts | max / median offset | ratio | verdict |
  |---|---|---|---|---|---|
  | bus 9 (fixture line) | a-b, b-a, a-b1, b1-a (short turns) | 224–237 | 0 / 0 m | 1.11–1.13 | 4× PASS |
  | bus 61 | a-b, b-a, a-c, c-a (branch to Väike-Õismäe) | 55–174 | 0 / 0 m | 1.23–1.48 | 4× PASS |
  | bus 33 | a-b, a1-b, b-a, b1-a, b-c | 89–234 | 0 / 0 m | 1.06–1.09 | 5× PASS |
  | trol 72 | a-b, b-a | 148–165 | 0 / 0 m | 1.04–1.05 | 2× PASS |
- Size: 0.85–1.46 KB gzip on the wire / 1.4–4.2 KB raw. Latency 0.8–2.5 s.
- `ETag` `"1039-…-gzip"`, `Last-Modified` 14 Oct 2026 (= stops.txt export date); conditional GET still 200.

## vilnius

- Base `https://www.stops.lt/vilnius/vilnius/`, city slug `vilnius` (transports `bus`, `trol`, `expressbus`,
  `nightbus`, `ferry`). stops.txt answered Cloudflare **522 after 21 s** once, then 200 on retry 5 s later — the
  known origin flakiness; the map files themselves answered every time.
- Verification [V 2026-10-19]:
  | file | variants checked | pts | max / median offset | ratio | verdict |
  |---|---|---|---|---|---|
  | bus 17 (fixture line) | a-b, b-a, a-d, d-a, d-b (depot runs) | 55–136 | 0 / 0 m | 1.05–1.63* | 5× PASS |
  | trol 7 | a-b, b-a, a-d, b-d, d-a, d-b | 88–218 | 0 / 0 m | 1.09–1.42 | 6× PASS |
  | expressbus 3G | 6 variants incl. depot runs | 145–246 | 0 / 0 m | 1.13–1.42 | 6× PASS |
  | nightbus N1 | a-b, b-a, b-d, d-a | 110–160 | 0 / 0 m | 1.07–1.52* | 4× PASS |
  \* >1.5 only on short depot runs (17 a-d 3.0 km vs 1.9 km chords), within the +500 m slack; depot runs are
  hidden by the adapter anyway.
- Size: 1.0–1.9 KB gzip / 2.1–4.6 KB raw. Latency 1.5–3.5 s. Weak ETag; `If-None-Match` → 304 [V].

## kaunas

- Base `https://www.stops.lt/kaunas/kaunas/`, city slug `kaunas` (transports `bus`, `trol`). The fixture has no
  line; lines at stop 576 include 23, 43, 46, 57, trol 4 and date-specific `43P (10.22)`.
- Verification [V 2026-10-19]:
  | file | variants checked | pts | max / median offset | ratio | verdict |
  |---|---|---|---|---|---|
  | bus 23 | all 20 (a-b, a-b_67 weekend, a1-a-b, branches to c/c1/c2…) | 125–599 | 0 / 0 m | 1.04–1.14 | 20× PASS |
  | trol 4 | a-b, b-a, e-b | 283–340 | 0 / 0 m | 1.11–1.16 | 3× PASS |
  | bus 43P (10.22) | c-a, c1-b (date-specific number) | 210–294 | 0 / 0 m | 1.12–1.15 | 2× PASS |
- Size: 1.2–3.3 KB gzip / 2.1–29 KB raw (bus 23 carries 20 variants). Latency 3.3–3.8 s.
- Note: the adapter drops `43P (10.22)`-style variants only when a plain `43P` exists; their file name keeps the
  suffix, so use `shortName`, not `providerRefs["num"]`.

## iett

**Result: a per-direction shape is available live, one call per direction, and it passed on 6 of 7 directions [V 2026-10-19].** The source is the İETT website's own map endpoint, `iett.istanbul/tr/RouteStation/GetRoutePinV2`. The 257 MB bulk GeoJSON is now only the offline fallback.

### 1. How the adapter loads the line today [V]
- **`routePattern(for:)`:** SOAP `POST https://api.ibb.gov.tr/iett/ibb/ibb.asmx`, op `DurakDetay_GYY`, `<hat_kodu>{line}</hat_kodu>`.
  - Returns both directions (~20 KB XML).
  - Columns: `HATKODU, YON (G|D), SIRANO, DURAKKODU, DURAKADI, XKOORDINATI (lon), YKOORDINATI (lat), DURAKTIPI, ISLETMEBOLGE, ISLETMEALTBOLGE, ILCEADI`.
  - There is no route-variant column.
- **`lines(atStop:)`:** the same op with an empty `hat_kodu`, which dumps the whole network.
- **Ids already in hand:**
  - `TransitLine.id = "<line>_<G|D>"`.
  - `providerRefs = ["line": "<line>", "direction": "G"|"D"]`.
  - The vehicle feed's `guzergahkodu` (`500T_G_D0`) uses the same id scheme as the shape endpoint.

### 2. Shape recipe: 1 extra call per direction, no piggyback possible
```
GET https://iett.istanbul/tr/RouteStation/GetRoutePinV2?q={line}_{G|D}_D0
```
- **Building the id:** `q` is the route code (`GUZERGAH_KODU`): `{providerRefs.line}_{providerRefs.direction}_D0`.
  - `D0` is the main route of that direction. `D<n>` codes are departure-specific variants, e.g. `28_G_D2605`, a Topkapı loop; they also work [V].
  - Percent-encode Turkish letters (`11%C3%9CS`) [V].
- **No piggyback:** the SOAP services (`HatDurakGuzergah.asmx`: `GetDurak/GetGaraj/GetHat` in `_csv/_json/_XML`; `ibb.asmx`: `DurakDetay_GYY`, `DurakDetay_GYY_wYonAdi`, `HatServisi_GYY`) return no geometry [V, from the WSDLs and calls].
  - `GetHat_json` gives `HAT_UZUNLUGU` (km), which is useful as a sanity check: line 28 is 12.05 km, and its decoded shape is 12.09 km [V].
- **Variant list (optional):** `GET https://iett.istanbul/tr/RouteStation/GetAllRoute?rcode={line}` [V].
  - It returns `GUZERGAH_GUZERGAH_KODU` + `GUZERGAH_ADI`.
  - For 28 it listed only the non-main variant `28_G_D2605`. Not needed for our patterns.
- **Discarded options:**
  - The site's map widget (`sehirharitasiapi.ibb.gov.tr`, with an embedded API key) only draws what `GetRoutePinV2` returns, so it isn't needed.
  - Mobiett / `ntcapi.iett.istanbul` needs OAuth2, so it was not usable.

### 3. Format and decoding [V]
- **Reply shape:** a JSON array of one object: `{lineIcon, lineColor, line, stationPlaces[]}`.
- **`line`:** WKT `LINESTRING (lon lat, lon lat, …)` pieces joined with `|`. Coordinates are **lon lat**, CRS84.
- **One piece per stop-to-stop leg, already in order.** For every line tested, pieces = stops − 1: 20/21, 23/24, 33/34, 43/44, 35/36, 63/64, 54/55.
  - Concatenate the pieces in order and drop the joint point when it repeats the previous end.
  - Gaps at the joints are 0–45 m (stop-pin snapping). They are not mis-ordered and need no reversing or stitching.
- **`stationPlaces[]`:** `{stationName, stationCity, lat, lng}` as strings, with no stop codes.
  - Names and coordinates were identical to the adapter's `DurakDetay_GYY` stops for that direction in all 7 directions.
  - So the shape matches our pattern by construction; compare the names and the count as a check.
- **Precision:** about 13 decimals; reduce to 1e-5 when caching.
- **Unknown code:** HTTP 200 with `[{"line":"","stationPlaces":[]}]` or `[]`. Treat either as "no shape".
- **Size:** no gzip (the server ignores `Accept-Encoding`). It is WKT text, 17–48 KB raw per direction; re-encoded as a polyline it is about 3–6 KB.
- **Terminal caveat:** off-street terminals put the end stop's pin inside the bus station, away from the road.
  - EM1 (a ring line from Eminönü): the first and last stop are 62.6 m from where the shape starts and ends.
  - **Fix:** in the app's check, allow first and last stops up to ~100 m, or add the stop point at each end as a short terminal stub. Both variants PASS (max 12.5 m).

### 4. Live verification [V 2026-10-19]
Stops were fetched with `DurakDetay_GYY` exactly as the adapter does; shapes were fetched per §2.

| route code | kind | pts | shape / chord | ratio | max / median offset | verdict | wire size | latency |
|---|---|---|---|---|---|---|---|---|
| 28_G_D0 | urban | 421 | 12,092 / 9,372 m | 1.29 | 11.3 / 6.8 m | PASS | 17.7 KB | 1.8 s |
| 28_D_D0 | urban, return | 403 | 13,204 / 10,353 m | 1.28 | 13.2 / 6.2 m | PASS | 17.4 KB | 2.8 s |
| 336_G_D0 | 25 variants on the line | 1,178 | 34,630 / 31,024 m | 1.12 | 18.2 / 7.1 m | PASS | 47.4 KB | 8.7 s |
| 336_D_D0 | | 945 | 33,959 / 29,139 m | 1.17 | 18.0 / 8.1 m | PASS | 38.0 KB | 1.4 s |
| 500T_G_D0 | 57 km, crosses the Bosphorus | 1,132 | 57,006 / 53,174 m | 1.07 | 21.7 / 5.3 m | PASS | 48.5 KB | 4.6 s |
| 11ÜS_G_D0 | Turkish letter in the code | 1,066 | 34,759 / 31,331 m | 1.11 | 18.3 / 4.9 m | PASS | 45.4 KB | 2.5 s |
| EM1_G_D0 | ring/loop | 663 | 15,183 / 13,134 m | 1.16 | 62.6 / 7.4 m | **FAIL** (stops 0 and 33 = terminal pin) | 28.2 KB | 3.2 s |

- **EM1 after the terminal fix:** PASS, max 12.5 m.
- **Latency:** 1.4–8.7 s; one earlier call took 21.6 s. The site is slow, so fetch in the background and cache.

### 5. Cache key and change detection
- **Key:** `iett:{line}_{dir}_D0` plus a hash of the ordered `DURAKKODU` list from `DurakDetay_GYY`, which we fetch anyway.
  - Because the pieces map 1:1 to stop pairs, a changed stop list means a changed shape: refetch then.
- **No cheap change signal on the endpoint:** it sends `Cache-Control: private`, no ETag and no Last-Modified [V].
- **TTL:** keep until the stop list changes, and re-validate at most every 30 days.
- **Bulk-file signal:** the file has an ETag and Last-Modified (`Wed, 18 Mar 2026 10:40:05 GMT`) [V], and CKAN `metadata_modified` = 2026-03-18. It is updated a few times a year, so the routes change slowly.

### 6. Rate limits and terms
- **`GetRoutePinV2`:** an undocumented, website-internal endpoint, not part of the İBB open-data API.
  - No published quota. No 429 in 10 calls [V].
  - It can change without notice. `robots.txt` doesn't disallow `/tr/RouteStation/` [V].
  - Explicit terms for third-party use: none found [U].
- **The same geometry is published as open data:** dataset `iett-hat-guzergahlari`, under the İBB Open Data Licence (CC BY 4.0-compatible).
  - The bulk `336_G/D_D0` features match the live endpoint (34,608 vs 34,682 m and 34,403 vs 33,970 m), and both PASS shapecheck [V].
  - So drawing the geometry is licensed. Attribution: the adapter's existing "Kaynak: İETT, İBB Açık Veri Portalı… CC BY 4.0" string covers it.
- **Don't add load to the SOAP quota:** the position service is limited to 100 calls an hour, and this recipe uses none of it.

### 7. Proxy changes
None. The endpoint is keyless and called directly from the phone; `functions/src/agencies.ts` has no İETT entry.

### 8. Offline fallback: the bulk GeoJSON [V]
- **URL:** `https://data.ibb.gov.tr/dataset/b48d2095-851c-413c-8d36-87d2310a22b5/resource/4ccb4d29-c2b6-414a-b324-d2c9962b18e2/download/iett-hat-guzergahlar-verisi.geojson`
- **Size:** 257,253,099 bytes, `application/geo+json`.
  - It is not in the CKAN datastore, so it can't be queried per line.
  - A `Range` request was answered `200` with the whole body (ranges not honoured). I got a 59 MB partial by accident and then deleted it.
- **One feature per route code.** Properties: `GUZERGAH_KODU` (e.g. `133P_D_D1854`, the same id as the live endpoint and the vehicle feed), `HAT_KODU`, `YON` (`GİDİŞ`/`DÖNÜŞ` = G/D), `DEPAR_NO` (0 = main route), `UZUNLUK` (m, decimal comma), `RING_MI`, `DURUM`, plus `LineString` geometry (lon, lat).
  - In the first 1,677 features: 179 lines, up to 32 variants per line (133P). Ring lines have a G direction only (e.g. EM1, 30M, U1).
- **Mapping:** feature `GUZERGAH_KODU == "{line}_{G|D}_D0"`. The offline job can split the file into per-route-code polylines.
- **İETT GTFS** (`iett-gtfs-verisi`, CSVs updated 2026-03-17): **no `shapes.txt`**.
- **"Public Transport GTFS Data"** (`public-transport-gtfs-data`): has `shapes.csv` (7.5 MB, dated 2023-03-01), but it covers minibuses, ferries, Marmaray and metro, not İETT buses.
- **Recommendation:** use the live endpoint. Use the bulk file only to pre-split shapes if the website endpoint disappears.

## Summary

| provider | extra calls per cold line | piggyback? | format | verified lines PASS/FAIL | max offset | size | latency | cache key | notes |
|---|---|---|---|---|---|---|---|---|---|
| entur | 0 | yes — `pointsOnLink { points }` in the existing `line{journeyPatterns}` query | Google polyline p5 | Skyss 4 (+variant), Skyss 11 (+short), Ruter 20 (+variant): all PASS on quay coords | 11.6 m (quay) | +2–5 KB gz on the line reply | no added latency (query 1.1–2 s) | journeyPatternId + quay-id hash | check against quays: parent stop-place centroid gave a 75 m FAIL at an Oslo interchange |
| foli | 1 (`/gtfs/v0/{ds}/shapes/{shape_id}`) | no | JSON `{lat,lon,traveled}` | line 1 ×2 dirs, line 6 ×4 variants: all PASS | 15.2 m | 23–60 KB gz (92–241 KB raw) | 2–7 s | dataset + shape_id | shape_id already in providerRefs; heavy and slow, re-encode and simplify |
| tampere | 1 (`/routes/{routeId}?exclude-fields=journeys,journeyPatterns`) | routeId already in the pattern reply (`routeUrl`) | `geographicCoordinateProjection` delta string, ×1e5, deltas **subtracted** | line 4 ×4 patterns, tram 3 ×3: all PASS | 15.3 m | 0.6–1.7 KB gz | 0.5–4 s (outlier 16 s) | routeId (content hash) | change detection free via routeUrl; server erratic |
| ztm-poznan | 0 to ZTM; 1 static file from our host | no (offline) | GTFS shapes.txt → our precision-5 polyline | GTFS stops: 4 PASS / 1 FAIL (loop terminus 60 m); PEKA stop list: 2 PASS (clean lines), 3 FAIL (merged variants) | 15.7 m (clean); 60 m loop | ~1–2 KB | static GET | line + PEKA direction name (+ sha1 of stop codes) | No live geometry. **PEKA `getBollardsByLine` merges variants with restarting orderNo → zig-zag stop lists on ~half the lines (adapter bug)**; ship GTFS stop order with the shape. GTFS 11.2 MB, 268 s download. |
| ztm-gdansk | 1 | parallel with stopsInTrip (same date/route/trip) | GeoJSON LineString, lon,lat, 5 dp | 3 PASS / 0 FAIL (MAIN, SIDE short-turn, REMONT diversion) | 14.2 m | 14.5–18.6 KB, no gzip | 0.56–1.5 s | routeId/tripId/activationDate (from trips?date=, already fetched) | Official: listed in the operator's "Lista przebiegów tras" resource. |
| mpk-krakow | 1 (pathinfo/trip?id=) | parallel with tripPassages (same trip id) | JSON wayPoints, int milliarcseconds | Live: 0 (host 503 from IL all session); format on Kiel TTSS: 1 FAIL (stop-area coords 64–112 m); offline GTFS: 16/16 PASS (179×2, 144, 125×13) | GTFS 17.5 m; Kiel 112 m | Kiel: 54 KB raw / 7.4 KB gz | Kiel 1.6 s | route/direction/sha1(stop list) | **Blocker: ttss.mpk.krakow.pl returns 503 block page by day** — re-test from EU. Fallback: ZTP GTFS has shapes.txt. |
| wienerlinien | 1 (2 if the derived EFA line id fails → serving-lines at DIVA) | no (the adapter calls no EFA today) | EFA geo object: unordered `[lat,lon]` pieces, stitched | EFA: 13A H, 2A H, 6 R PASS; 6 H FAIL (terminus 65 m; adapter's stale longest variant FAILs everywhere) | 7.3–11.4 m PASS; 65 m FAIL | 1.4–3.7 KB gz (13–17 KB raw) | 1.5–9.8 s, one timeout | EFA id incl. `jYY` + sha1(RBLs) | ogd_routing = VOR EFA, terms [U]; fallback: offline GTFS 95.8 MB with shapes.txt (6,348 shapes, `<route>.<k>.<H/R>`, DIVA-based stop ids); adapter's "longest variant" picks diversions |
| efa-linz | 0 (fallback 2: DM + STOPSEQCOORD) | yes, `coords` in the `routePattern` geo reply | `[lat,lon]` pieces, unordered, union of variants → stitch + splice; fallback is one ordered list | geo: 6 PASS / 3 FAIL (merged-variant stop lists); trip fallback 3/3 PASS | 3.8–32.8 m PASS (trip: 5.2–13.6 m) | geo 4–13 KB gz; trip 7–13 KB gz / 30–63 KB raw | geo 1.6–8.5 s; trip 1.5–2.6 s + DM 1.5–3.6 s | line id (`…:f26`) + sha1(stop DHIDs) | stitcher verified; the adapter's geo `locationSequence` merges variants (tram 3, 19, 27 R patterns wrong) |
| lpp-ljubljana | 1 per route group (`route/routes?route-id=&shape=1`; covers both directions + all variants) | no (stations-on-route has no shape) | GeoJSON LineString object, [lon,lat] | 6 sub-routes of 3 lines: 5 PASS, 1 FAIL→PASS with terminal fix | 18.2 m (68 m raw at a P+R terminus) | 7.9–13.7 KB gz (28–105 KB raw) | 0.5–22 s (server erratic for every endpoint) | trip_id (= line.id), grouped by route_id | prepend/append terminus stop if ≤150 m from shape end; no ETag |
| tallinn | 1 per route number (`data/tallinna-linn_{transport}_{num}.txt`) | no (adapter never fetches it; routePattern is offline) | 3-line records: routeType / Google polyline p5 lat,lon / flags | 4 lines, 15 variants: 15 PASS | 0 m (stops are vertices) | 0.85–1.46 KB gz | 0.8–2.5 s | tallinn/transport/num/routeType; invalidate on RouteStops change | city slug is `tallinna-linn`, not `tallinn` |
| vilnius | 1 per route number (`vilnius/vilnius/vilnius_{transport}_{num}.txt`) | no | same | 4 lines, 21 variants: 21 PASS | 0 m | 1.0–1.9 KB gz | 1.5–3.5 s | vilnius/transport/num/routeType | 304 on If-None-Match; stops.txt 522 flake once |
| kaunas | 1 per route number (`kaunas/kaunas/kaunas_{transport}_{num}.txt`) | no | same | 3 lines, 25 variants: 25 PASS | 0 m | 1.2–3.3 KB gz (≤29 KB raw) | 3.3–3.8 s | kaunas/transport/num/routeType | num keeps date suffix, e.g. `43p(10.22)` |
| iett | 1 per direction (`iett.istanbul/tr/RouteStation/GetRoutePinV2?q={line}_{G\|D}_D0`) | no (SOAP has no geometry) | WKT LINESTRING pieces (lon lat) joined by `\|`, one per stop pair, already ordered: just concatenate | 6 PASS / 1 FAIL (EM1 ring: off-street terminal pin, 62.6 m; PASS with end-stop tolerance or terminal stubs) | 21.7 m (62.6 m terminal) | 17–48 KB raw, no gzip | 1.4–8.7 s (one 21.6 s) | `{line}_{dir}_D0` + hash of `DURAKKODU` list | Undocumented website endpoint; same geometry is CC BY open data (257 MB bulk GeoJSON as fallback); stationPlaces equal adapter stops 1:1 |
