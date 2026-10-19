# Route shapes — group "west-europe" (2026-10-19)

Providers: tfl, star-rennes, stib, carrismetropolitana, bizkaibus, mobiliteit-lu, vbb.
[V] = verified live on 2026-10-19 from this machine; [U] = unverified (docs, inference, or needs a key).
All checks ran `tools/shapecheck.py` (in-order DP match, PASS = every stop within 50 m and shape length
<= 1.5x the stop chords). "gz" = bytes on the wire with `Accept-Encoding: gzip`; "raw" = decoded body.
Scratch: `regions/dl/<provider>/` (downloads, `chk-*.json`), scripts in `regions/we-scripts/`.

---

## tfl

**1. Today.** `lines(atStop:)` → `GET /StopPoint/{naptan}/Route?serviceTypes=Regular,Night`; `TransitLine.id`
= `"{lineId}:{direction}"`, `providerRefs = {lineId, direction, naptanId}`. `routePattern(for:)` →
`GET /Line/{lineId}/Route/Sequence/{direction}?serviceTypes=Regular,Night&excludeCrowding=true` and keeps the
longest `orderedLineRoutes[].naptanIds` that contains the rider's `naptanId`, coordinates from
`stopPointSequences[].stopPoint[]`.

**2. Recipe: 0 extra calls.** The same `Route/Sequence` reply has `lineStrings: [String]` [V]. Add
`var lineStrings: [String]?` to `DTO.RouteSequence` and decode it.

**3. Format and branch choice.**
- Each `lineStrings[i]` is a JSON string of `[[[lon,lat], …], …]`: a list of pieces (**lon/lat order**),
  WGS84 to 6 decimals [V].
- `lineStrings` is **not** one entry per `orderedLineRoute` [V]:
  - h13 inbound: 3 lineStrings, byte-identical, for 2 routes.
  - 63 inbound: 2 identical lineStrings, each holding 2 pieces (230 pts = full route, 112 pts = the short working).
  - 19 inbound: 1 lineString for 2 routes.
- **Pick by fit.** Flatten every piece of every lineString, de-duplicate identical pieces, then run the
  in-order 50 m check of the chosen `naptanIds` stops against each piece. Take the shortest piece that passes.
  If none passes, draw stops only (do not concatenate pieces: the 63 concatenation passes offsets but runs
  2.06x long). Pieces are already in travel order; no reversal was needed on any line.
- **Side finding (19 inbound) [V].** `orderedLineRoutes[0]` (47 ids) contains ~10 NaPTAN ids that are
  absent from `stopPointSequences`, so the adapter silently drops them. `orderedLineRoutes[1]` (45 ids, a
  Highbury Grove routing) is not covered by the only lineString: stops 36–44 are >250 m off. The data
  disagrees with itself; the fit test catches it (no shape is drawn for that variant).

**4. Verification [V].**

| line / dir | variant | pts | max offset | median | ratio | verdict |
|---|---|---|---|---|---|---|
| 88 outbound | only route (49 stops) | 273 | 18.4 m | 6.4 m | 1.14 | PASS |
| h13 inbound | 39-stop route (3 identical lineStrings) | 296 | 23.6 m | 6.7 m | 1.08 | PASS |
| h13 inbound | 40-stop route | 296 | 41.4 m | 6.9 m | 1.07 | PASS |
| 63 inbound | full route, piece 0 | 230 | 11.2 m | 5.5 m | 1.09 | PASS |
| 63 inbound | short working, piece 1 | 112 | 11.2 m | 5.1 m | 1.11 | PASS |
| 19 inbound | route 0 (47) | 235 | 11.2 m | 5.9 m | 1.12 | PASS |
| 19 inbound | route 1 (45, Highbury Grove) | 235 | 9 stops >250 m | | | FAIL (data: no geometry for that variant) |

- Payload is the reply we already download: 88 out was 189 KB raw / 10.5 KB gz; 63 in 182 KB / 9.0 KB;
  h13 159 KB / 10.6 KB.
- Latency: 1.3–5.2 s, with one 11.7 s outlier (63). The varnish edge was a MISS every time; the reply sends
  `Cache-Control: max-age=43200, s-maxage=86400`.

**5. Cache and change detection.**
- Key: `tfl:{lineId}:{direction}:{sha1(chosen naptanIds)}`.
- Signal: the shape comes with the pattern reply, so it can never be staler than the pattern.
  `Line/{id}/Route` and `/Line/Mode/bus/Route` carry `routeSections[].validFrom/validTo` and `modified` [V].
  For example, 88: `validFrom 2026-09-19`, `validTo 2026-12-23`. These are a natural expiry.
- TTL: until `validTo`, or weekly, whichever comes first.

**6. Limits and terms.**
- Keyless: 50 req/min per IP. With a free `app_key`: 500/min (per the adapter docs; no rate-limit headers
  were seen) [U].
- TfL transport data terms allow display. Credit "Powered by TfL Open Data" + "Contains OS data © Crown
  copyright and database rights" (already in the adapter).

**7. Proxy.** None (keyless, direct).

---

## star-rennes

**1. Today.**
- `lines(atStop:)`:
  - `GET …/tco-bus-topologie-dessertes-td/exports/json?where=idarret="{stop}"&select=idparcours,idligne,nomcourtligne`
  - then `GET …/tco-bus-topologie-parcours-td/exports/json?where=id in (…)&select=id,idligne,nomcourtligne,sens,type,…`
- `TransitLine.id` = `"{idligne}-{sens}"`, `providerRefs.parcours` = the parcours id (e.g. `0001-A-2844-3028`).
- `routePattern(for:)`:
  - `GET …/tco-bus-topologie-dessertes-td/exports/json?where=idparcours="{parcours}"&select=idarret,ordre&order_by=ordre`
  - stop coordinates come from the cached `tco-bus-topologie-pointsarret-td` export (1,810 stops).

**2. Recipe: 1 extra call** (the shape lives in a different dataset from the pattern's `dessertes`):
```
GET https://data.explore.star.fr/api/explore/v2.1/catalog/datasets/tco-bus-topologie-parcours-td/records
    ?where=id="{providerRefs.parcours}"&select=id,datedebutversion,longueur,parcours
```
- 0-call alternative: add `parcours` to the `select` that `lines(atStop:)` already sends. That carries the
  geometry of every variant at the stop (16 at République, ~4–8 KB gz each), so it costs bandwidth on every
  stop open. It is not recommended.

**3. Format [V].**
- `results[0].parcours` is a GeoJSON Feature, `geometry.type = "LineString"`, `[lon,lat]`, 6 decimals. One
  piece per parcours; no stitching or reversal needed.
- Each parcours is one variant (`type` `Principal`/`Secondaire`), so the variant is the one the adapter
  already picked. No branch choice.
- Schema also has `longueur` (m), `datedebutversion`, `datefinversion`, `estversionactive`, `route_id`.

**4. Verification [V]** (stop 1242 République):

| parcours | type | pts | max | median | ratio | verdict | gz / raw | latency |
|---|---|---|---|---|---|---|---|---|
| 0001-A-2844-3028 (C1) | Principal | 511 | 14.2 m | 6.0 m | 1.08 | PASS | 3.8 / 12.5 KB | 2.4 s |
| 0011-B-3751-1746 (11) | Principal | 476 | 10.0 m | 6.0 m | 1.12 | PASS | 3.6 / 11.6 KB | 1.5 s |
| 0806-A-1235-4112 (E4) | Secondaire | 980 | last stop 445 m past the end | 5.2 m | 1.11 | FAIL | 7.5 / 23.6 KB | 5.5 s |

**E4 diagnosis.** The geometry stops at stop 4111 (5 m from the shape's end). The variant's terminus 4112
(the id even ends in `-4112`) lies 445 m beyond. The secondary variant's trace is truncated in the data; it
is not reversed and not sparse.

**Fix options:**
- (a) Treat it as a fail and show stops only.
- (b) Relax the check to "all stops except the final one are on the shape", then draw the shape plus the
  stop pins without a connecting segment.
- (c) Fall back to the Principal parcours of the same `idligne`/`sens` when the rider's stop is on it.

I suggest (b) only for a terminal stop within 500 m of the shape's end, else (a).

**5. Cache and change detection.**
- Key: `star:{parcours id}:{datedebutversion}`.
- Free signal: add `datedebutversion` (and `longueur`) to the `select` of the `parcours` query that
  `lines(atStop:)` already makes. If either differs from the cached value, refetch.
- The dataset's `metas.default.data_processed` updates daily (2026-10-18T23:00), so it is not a useful signal.
- TTL: keep while `datedebutversion` matches; revalidate at most weekly.

**6. Limits and terms [V].**
- Headers: `X-RateLimit-Limit: 20000`, `X-RateLimit-Remaining`, `X-RateLimit-Reset: <next 00:00 UTC>`, per
  IP, anonymous. Every call counts, `records` and `exports` alike. This dataset sets no per-dataset limit
  headers (`X-RateLimit-dataset-*` is exposed in CORS but absent).
- The earlier session's quota hit is unlikely to come from shapes: 1 call per cold line against 20k/day.
- ODbL. Credit "Données STAR / Keolis Rennes"; drawing is allowed.

**7. Proxy.** None (keyless).

---

## stib

**1. Today.**
- The whole network comes once per session from the BMC gateway:
  - `…/api/datasets/stibmivb/static/stopDetails` (2,415 poles, 69 KB gz [V])
  - `…/static/stopsByLine` (148 rows = line x `City`/`Suburb`, 22.7 KB gz [V])
- `TransitLine.id` = `"{lineid}-{direction}"`. The pattern is that row's `points[]` (pole ids with letters,
  e.g. `5399F`). There is no per-line call.

**2. No live per-line shape.**
- The gateway catalogue (data.belgianmobility.io/en/data.html?agency=stibmivb) lists, for STIB, only:
  `rt/WaitingTimes`, `rt/VehiclePositions`, `rt/TravellersInformation`, `static/StopDetails`,
  `static/stopsByLine`, `static/shape-files` (network SHP, ~5 MB, weekly), `static/rail`, `static/roads`
  (INSPIRE), plus a GTFS and a NeTEx feed [V].
- No per-line shape API. The `stibmivb` root is a 404.

**8. Offline source: the STIB GTFS, which has `shapes.txt` [V].**
- URL (keyless): `https://api-management-discovery-production.azure-api.net/api/gtfs/feed/stibmivb/static`
- 14.4 MB zip; unzipped 97 MB, of which `shapes.txt` is 9.75 MB.
- Headers: `Last-Modified` and `ETag` (`"0x8DF2DA12B089EAB"`), so a conditional GET or HEAD is a cheap change
  check. "Updated daily".
- `feed_info.feed_version = 2_23_20261012_010701`, valid 2026-10-12 → 2026-11-08.
- The download took 312 s from Israel (slow Azure blob); fine for a backend job.

**Id mapping [V]:**
- GTFS `stop_id` == `stopDetails.id` (letters included, e.g. `0470F`; the same coordinate, 0 m apart).
- GTFS `route_short_name` == `stopsByLine.lineid`. `route_id` is **different**: `route_id 4` is metro 2,
  `route_id 10` is tram 9.
- `trips.direction_id` 0/1 does not name City/Suburb.
- `shape_id` looks like `007t0228` (line, mode letter, serial).

**Matching a stopsByLine row to a shape:**
- Exact stop-sequence equality matches 103/148 rows (+2 on digits only, +10 on the same terminals).
- More robust: for each row, test every distinct `shape_id` of that `route_short_name` with the 50 m in-order
  check and take the shortest PASS. That gives **127/148 PASS** [V]. Ship the result offline as
  `stib/{lineid}-{direction}-{sha1(points)}.json`.

**4. Verification [V]** (stopDetails coordinates exactly as the adapter uses them, GTFS shape):

| pattern | shape | pts | max | median | ratio | verdict |
|---|---|---|---|---|---|---|
| 7-City (tram, fixture line) | 007t0228 | 835 | 4.0 m | 0.5 m | 1.04 | PASS |
| 7-Suburb | 007t0224 | 865 | 35.1 m | 0.5 m | 1.04 | PASS |
| 71-City (bus, 9 shapes on the line) | 071b0286 | 454 | 5.8 m | 2.4 m | 1.15 | PASS |
| 95-Suburb | 095b0169 | 523 | 14.5 m | 1.3 m | 1.12 | PASS |
| 1-City (metro) | 001m0045 | 660 | 9.7 m | 0.0 m | 1.05 | PASS |
| 87-City | 087b0203 | 580 | 5.2 m | 1.0 m | 1.18 | PASS |

**The 21 FAILs, diagnosed:**
- **Ratio false positives (offsets are fine).** 12-City/Suburb (airport express, 9 stops: max 4 m, ratio
  1.9) and 74-City/Suburb (max 4–7 m, ratio 1.7). Few stops on long roads. Relax the ratio rule when the
  stop count is under ~12, or use ratio 2.0.
- **stopsByLine ≠ current service (works or diversions).** Lines 4, 10, 50, 51, 55, 59, 81. Examples:
  - Tram 4 currently runs as two sections: GTFS shapes Stalle→Porte de Hal (004t0130) and
    →Gare du Nord (004t0089). stopsByLine still lists the through route.
  - Tram 10's stops 5219F–0725 lie 0.5–2.9 km from every line-10 shape.
  - The GTFS is right about what runs; stopsByLine is nominal. Do not draw; show stops only.
- **One terminal stop 57–75 m off.** 89-City/Suburb, 38-Suburb.
- The old note "network shapefile in Lambert 72, possibly stale" is moot: the GTFS has proper per-trip
  WGS84 shapes.

**5. Cache.**
- Key: `stib:{lineid}:{direction}:{sha1(points)}`. stopsByLine is fetched each session anyway, so a changed
  stop list changes the key.
- Backend: refetch the GTFS when its ETag changes (daily). The app keeps a shape while its key matches;
  revalidate weekly.

**6. Terms.**
- CC BY 4.0. Credit "Source: STIB-MIVB – Open Data – [date of dataset update]" (terms art. 4).
- Anonymous tier: "100 req/day, 10/min", indicative and not enforced (no rate-limit headers today [V]).
  A once-a-day GTFS pull by a backend is well within it.

**7. Proxy.** None needed for the app. A backend job pulls the GTFS keyless.

---

## carrismetropolitana

**1. Today.**
- `/v2/stops` (12,752 stops, 778 KB gz; it took 56 s on this run) gives each stop's `pattern_ids`.
- `lines(atStop:)` and `routePattern(for:)` call `GET /v2/patterns/{pattern_id}`, which returns an array of
  versions; the adapter picks the version valid today.
- `TransitLine.id` = pattern id (`2605_0_1`).

**2. Recipe: 1 extra call, and the id is already in hand [V].**
- Each pattern version has `shape_id` (e.g. `"[0277F]2605_0_1"`), and the adapter already decodes that reply.
- Then call:
  ```
  GET https://api.carrismetropolitana.pt/v2/shapes/{percent-encoded shape_id}   # [ → %5B, ] → %5D
  ```
- No piggyback: patterns carry no geometry.

**3. Format [V].**
- `{shape_id, extension (m), geojson: Feature<LineString [lon,lat]>, points: [{shape_pt_lat, shape_pt_lon,
  shape_pt_sequence, shape_dist_traveled}]}`. The same geometry appears twice; decode only `geojson`.
- No stitching or reversal. The stops are snapped onto the GTFS shape (median offset 0.1 m).

**4. Verification [V]** (stop 070032):

| pattern | pts | max | median | ratio | verdict | shape gz / raw | latency |
|---|---|---|---|---|---|---|---|
| 2605_0_1 (58 stops) | 1329 | 0.3 m | 0.1 m | 1.22 | PASS | 35.3 / 171 KB | 6.3 s |
| 2754_2_2 (variant 2 of 3 on line 2754) | 1087 | 8.4 m | 0.1 m | 1.22 | PASS | 25.5 KB gz | 10.6 s |
| 2532_0_2 (57 stops, starts at 070032) | 1080 | 6.1 m | 0.1 m | 1.16 | PASS | 29.1 KB gz | 1.7 s |

- Odd behaviour: one HTTP/2 framing error on the first `2532` attempt; the retry was fine. Latency varies
  widely (1.7–10.6 s, Cloudflare MISS then `cmet-cache-status: HIT`).
- No loop pattern was sampled.

**5. Cache and change detection [V].**
- Key: `shape_id` as given. Its `[0277F]` prefix is the GTFS plan/version tag, so a new plan gives a new id.
- The pattern version's `version_id` (sha256) also changes with content. Both come free, since the pattern
  is fetched anyway.
- No ETag; `Last-Modified` is just "now" and `Cache-Control: max-age=3600`, so they are useless as signals.
- Keep a shape while the pattern's `shape_id` is unchanged.

**6. Limits and terms.** No published rate limit. CC BY 4.0, credit "Carris Metropolitana" (already in the
adapter).

**7. Proxy.** None (keyless).

---

## bizkaibus

**1. Today.**
- `lines(atStop:)`: `gfReturn_LineasNew` (by province/municipality/stop), then for each line both directions
  of `gfReturn_Buscar_ItinerariosLinea_Basico?strCODLINEA=&strNUMRUTA=001&strSENTIDO=I|V`.
- `TransitLine.id` = `"{line}|{I|V}"`, `providerRefs = {line, direction}`.
- `routePattern` reuses the cached itinerary (ordered `PR_CODRED` codes). Coordinates come from
  `GetParadasAlfanumericas` (ETRS89 UTM 30N).

**2. Recipe: 1 extra call.**
```
GET https://apli.bizkaia.net/APPS/DANOK/TQWS/TQ.ASMX/GetRutaParadas_JSON
    ?callback=&sCodigoLinea={line}&sNumeroRuta=001&sSentido={I|V}
```
- The reply also lists the route's stops (`CodigoReducidoParada`, x/y in WGS84), but **not in travel order**.
  For both A3224 and A2322 the order matched neither the itinerary nor its reverse [V]. So it cannot replace
  the ordered itinerary call: 1 extra call.

**3. Format [V].**
- JSONP `({'STATUS': 'OK',"Ruta":{"attributes":{…},"geometry":{"paths":[[[lon,lat],…]]}},…})` mixes single
  and double quotes; cut out the `"paths":[[[…]]]` array with a regex, as the adapter already does for the
  passages XML.
- Esri `paths`, **lon/lat** WGS84 with ~15 decimals (round to 6). 1 path in all 4 samples.
- **Reversal is per line and direction, not uniform:**
  - A3224 `I`: stored end→start; PASS only reversed.
  - A3224 `V`, A2322 `I` and A2322 `V`: stored in travel order.
  - The "both directions drawn the same way" premise is false; the I and V geometries are distinct and each
    fits its own stops at ≤17 m.
- **Rule:** if `dist(path.first, lastStop) < dist(path.first, firstStop)`, reverse. On A3224 I the start was
  10 m from the last stop vs 6,955 m from the first.

**4. Verification [V]:**

| line / dir | pts | as stored | after orientation rule | max | median | ratio | gz / raw | latency |
|---|---|---|---|---|---|---|---|---|
| A3224 I (fixture) | 1204 | FAIL | reversed → PASS | 12.1 m | 6.2 m | 1.31 | 29.9 / 53.5 KB | 2.5 s |
| A3224 V | 1211 | PASS | as is | 17.0 m | 7.3 m | 1.36 | 30.1 / 54.0 KB | 1.9 s |
| A2322 I | 1248 | PASS | as is | 15.4 m | 4.7 m | 1.26 | 31.0 / 55.9 KB | 3.9 s |
| A2322 V | 1375 | PASS | as is | 12.4 m | 5.8 m | 1.25 | 33.9 / 61.1 KB | 2.9 s |

- The service is slow and flaky: one itinerary call took 84 s.
- Only route `001` (the main route) is drawn, as for the patterns.

**5. Cache.**
- Key: `bizkaibus:{line}:001:{I|V}:{sha1(itinerary codes)}`. The itinerary is fetched anyway, so its hash is
  the free change signal.
- No version field: `LN_ULDATE` in `gfReturn_LineasNew` is just today's date.
- TTL weekly.

**6. Terms.**
- The web service has no published terms or limits. The GTFS-RT is CC BY 4.0 via data.ctb.eus [U for the
  web service].
- Be gentle: the adapter already batches 4 at a time.

**7. Proxy.** None (keyless).

---

## mobiliteit-lu (HafasProvider `.luxembourg`, keyed via proxy agency `mobiliteit`)

**1. Today.**
- The server answers only `location.nearbystops` and `departureBoard` (no `journeyDetail`, per adapter docs
  and `hasJourneyDetail: false`).
- The pattern is the onward `passlist` stops of the board, plus a board at the line's first stop.
- Ids: station extId (`200405036`), HAFAS line key + `directionFlag`.

**2. No live shape.**
- `departureBoard` has no polyline option in the HAFAS ReST manual [U]. `journeyDetail` (which has `poly`) is
  not enabled for this accessId per the adapter docs [U: needs the key to re-check].
- If ATP ever enables `journeyDetail`, the VBB recipe below applies unchanged, with a new proxy path.

**8. Offline source: the national GTFS has `shapes.txt` [V].**
- data.public.lu dataset `horaires-et-arrets-des-transport-publics-gtfs` (CC BY), weekly. Latest:
  `https://download.data.public.lu/resources/horaires-et-arrets-des-transport-publics-gtfs/20261015-054835/gtfs-20261014-20261212.zip`
  (16.9 MB).
- Contents: `shapes.txt` 41.3 MB unzipped; 715 routes, 28,006 trips, 1,736 shapes; every trip has a
  `shape_id`.
- Find the newest resource through `https://data.public.lu/api/1/datasets/horaires-et-arrets-des-transport-publics-gtfs/`.
- Id mapping [V]:
  - GTFS `stop_id` = the HAFAS extId **zero-padded to 12 digits** (`000200405036` = Gare Centrale routière,
    same coordinates).
  - `route_short_name` = the HAFAS line name (`"22"`, `route_id 270`; 5 shapes).
  - Match a board pattern to a shape by `route_short_name` plus best in-order fit of the stop ids.

**4. Verification (offline, GTFS shape vs the same feed's stops; HAFAS stop coordinates come from the same
data, [U] for exact identity):**
- Line 22: 1 of 5 shapes PASS (1600, max 22 m). The other 4 have one stop 67–77 m off (Hollerich,
  Jean-Baptiste Merkels).
- Random 120 patterns + line 22 (125): 93 PASS at 50 m (74%); ~96% within 100 m; worst 187 m.

**Diagnosis.**
- Luxembourg stops are one coordinate per stop for both directions: 2,806 stops, `location_type 0`, no
  parents/platforms. So stops sit on the opposite kerb or round the corner, 20–190 m from the shape.
- The shape itself follows the road.

**Fix.** For this feed, validate with a 150–200 m tolerance (offset only; keep the ratio test), or let the
offline pipeline snap the stops onto the shape.

**5. Cache.**
- Key: `lu:{line}:{directionFlag}:{sha1(stop extIds)}`.
- The backend refetches when a new dataset resource appears (the API's `last_modified`; weekly).

**6. Terms.** CC BY 4.0, "Administration des transports publics / mobiliteit.lu". Nothing limits the GTFS
download.

**7. Proxy.** None for the offline route.

---

## vbb (HafasProvider `.vbb`, keyed via proxy agency `vbb`)

**1. Today.**
- `routePattern(for:)`: a `departureBoard` at the rider's stop (`passlist=0`), then
  `GET {proxy}/vbb/journeyDetail?id={JourneyDetailRef.ref}&format=json`. The ref looks like
  `1|32480|6|86|19102026`.
- Stops come from `Stops.Stop[] {extId, name, lat, lon, mainMastExtId}`.

**2. Recipe: 0 extra calls.** Add `poly=1` (and optionally `polyEnc=GPA`) to the existing `journeyDetail`
request [U: from the HAFAS ReST manual; no key used here].
- `key-signups.md` records that on 2026-10-01 VBB's `journeyDetail` returned "28 stops, polyline" on the
  test system. So VBB's ReST does serve trip polylines; whether that needed `poly=1` is [U].
- No public HAFAS ReST demo endpoint was found: the ReST manual PDF URLs are 404 or unresolvable today.
- The keyless community proxy `v6.vbb.transport.rest` (hafas-client over VBB's mgate) does answer [V]. It is
  fine for research only: volunteer-run, not for app traffic.

**3. Format.**
- HAFAS ReST trip polylines [U, field names to confirm on the first real reply]:
  - Usually `JourneyDetail.PolylineGroup.polylineDesc[].crd` (flat `[lon,lat,lon,lat…]`, with `delta: true`
    meaning the values after the first pair are deltas, plus `dim: 2`).
  - With `polyEnc=GPA`, a Google-encoded string (`crdEncYX`, lat/lon order, precision 5) instead.
- Decode both defensively; log the first reply.
- The geometry itself [V via transport.rest, the same HAFAS backend]:
  - Road-following but **sparse**: 78 vertices for 11.4 km on line 200, median vertex spacing ~105–128 m,
    max 456–696 m.
  - Fine for drawing: it lies within 6.5 m of the GTFS shape everywhere (see below).
  - One piece per trip; no reversal or branch choice, because it is the trip itself.

**4. Verification.**
- Stops from transport.rest are **station** coordinates (`9001…` ids):

  | trip | pts | max | median | verdict (station coords) |
  |---|---|---|---|---|
  | 200 → Zoo | 78 | 50.7 m | 14.3 m | FAIL |
  | M4 → Falkenberg (tram) | 53 | 85.8 m | 4.8 m | FAIL |
  | 100 → Alexanderplatz | 53 | 62.4 m | 10.4 m | FAIL |

- **Diagnosis: the stop coordinates, not the shape.** The big interchanges (S+U Potsdamer Platz, Leipziger
  Str., Prerower Platz) have their station centroid 110–120 m from the bus road.
- Cross-check [V]: the same 200 trip from Transitous `/api/v5/plan` (VBB GTFS: platform-level stop
  coordinates and a GTFS shape of 322 pts).
  - HAFAS polyline vs the GTFS platform stops: **max 6.5 m, median 1.6 m, PASS**.
  - Every GTFS-shape vertex is within **6.5 m** of the HAFAS polyline (median 0.9 m, p99 5.7 m).
- **Fix:** validate against platform coordinates, or for HAFAS use a 150 m offset tolerance plus the ratio
  test.
- Whether ReST `Stops.Stop[].lat/lon` are platform-level (`extId` vs `mainMastExtId`) is [U]. If they are
  station-level, the 150 m tolerance applies.
- Size and latency (transport.rest trip with stopovers and polyline): 3.2–4.4 KB gz (40–59 KB raw,
  pretty-printed), 1.8–5.8 s. The polyline adds ~2–3 KB gz to `journeyDetail` [U for ReST].

**5. Cache.**
- Key: `vbb:{HAFAS line key}:{directionFlag}:{sha1(stop extIds of the trip)}`.
- `journeyDetail` is fetched for the pattern anyway (proxy-cached 3,600 s), so a changed stop list rekeys
  the shape.
- TTL weekly. A trip's `ref` embeds the date (`…|19102026`), so never key by ref.

**6. Terms.**
- VBB ReST: "efficient requests or the ID may be paused". 0 extra calls is ideal.
- Name VBB as the timetable source. Proxy `upstreamPerMinute: 300`.
- Drawing the polyline is not restricted in the terms on file (`key-signups.md`) [U].
- Offline fallback: the VBB GTFS (`https://www.vbb.de/gtfs` → 66.8 MB zip [V size]; `shapes.txt` presence
  [U], but Transitous serves VBB GTFS shapes).

**7. Proxy changes (`functions/src/agencies.ts`, agency `vbb`, path `journeyDetail`):**
```ts
params: {
  id: { pattern: /^[0-9|]+$/, maxLength: 48, required: true },
  format: JSON_FORMAT,
  poly: { pattern: /^[01]$/, maxLength: 1 },
  polyEnc: { pattern: /^(GPA|DLT|N)$/, maxLength: 3 },   // only if the app sends it
},
```
- Keep `ttlSeconds: STATIC_TTL`. The proxy cache key includes the params, so the poly and no-poly replies
  are cached separately. Better: have the app always send `poly=1` for VBB patterns, so one fetch serves both.
- mobiliteit: no change unless ATP enables `journeyDetail`. Then add the same `journeyDetail` path rule to the
  `mobiliteit` agency (its refs follow the same `\d|…` form [U]).

---

## Summary

| provider | extra calls per cold line | piggyback? | format | verified lines PASS/FAIL | max offset (PASS) | size | latency | cache key | notes |
|---|---|---|---|---|---|---|---|---|---|
| tfl | **0** | yes, `lineStrings` in `Route/Sequence` | JSON-string `[[[lon,lat]]]`, pieces | 6 PASS / 1 FAIL (19 variant: no geometry for it) | 41 m | in the reply (9–11 KB gz total) | 1.3–5 s (11.7 s once) | line:dir:sha1(naptanIds) | dedupe pieces, pick the shortest piece that fits; never concatenate |
| star-rennes | 1 | no (could, but bloats lines-at-stop) | GeoJSON LineString lon/lat | 2 PASS / 1 FAIL (E4 secondary truncated 445 m before terminus) | 14 m | 3.6–7.5 KB gz | 1.5–5.5 s | parcours:datedebutversion | 20k calls/day/IP [V]; free change check by selecting `datedebutversion` in lines-at-stop |
| stib | n/a live; offline GTFS | — | GTFS shapes.txt | 127/148 stopsByLine rows PASS offline; 6 shown | 35 m | 14.4 MB zip (backend) | — | lineid:dir:sha1(points) | stop_id identical; match by route_short_name + fit; fails = express ratio, works (stopsByLine nominal) |
| carrismetropolitana | 1 | id piggybacks (`shape_id` in pattern) | GeoJSON (+duplicate points[]) | 3 PASS | 8 m | 25–35 KB gz | 1.7–10.6 s | shape_id (`[plan]` prefix) | shape_id/version_id change = new plan |
| bizkaibus | 1 | no (ruta stops unordered) | Esri paths lon/lat | 4 PASS (after orientation) | 17 m | 30–34 KB gz | 1.9–3.9 s | line:001:dir:sha1(codes) | orientation varies per line/dir: reverse when path start is nearer the last stop |
| mobiliteit-lu | n/a live; offline GTFS | — | GTFS shapes.txt | line 22 1/5 PASS; 93/125 PASS at 50 m, 96% at 100 m | 187 m worst | 16.9 MB zip (backend) | — | line:dir:sha1(stops) | stop_id = 12-digit padded extId; one coordinate per stop for both directions, so use 150–200 m tolerance |
| vbb | **0** (add `poly=1`) | yes, `journeyDetail` | HAFAS polyline (crd delta / GPA) [U names] | geometry PASS vs GTFS platform stops (6.5 m); 3 FAIL vs station centroids | 6.5 m | +~2–3 KB gz [U] | 1.8–5.8 s (transport.rest) | line:dir:sha1(stop ids) | proxy: allow `poly`, `polyEnc`; sparse vertices (~110 m) but accurate |

**Blockers and open items**
- VBB ReST: the polyline field names and the `poly` parameter are unconfirmed without the key. The first
  call with `poly=1` through the proxy should be logged; the proxy allow-list must gain `poly`/`polyEnc`
  first.
- Whether VBB `Stops.Stop[].lat/lon` are station or platform coordinates decides the validation tolerance
  (50 m vs 150 m).
- mobiliteit.lu: confirm with the key that `journeyDetail` is really unavailable. Otherwise it goes offline
  (GTFS has shapes).
- STIB and Luxembourg need the offline pipeline (a backend fetch of the GTFS, then a fit-select per pattern
  hash); no pfaedle is needed for either, since both feeds carry shapes.
- The shapecheck ratio rule (1.5x) misfires on express lines with few stops (STIB 12/74). Consider 2.0x
  when there are fewer than 12 stops.
- Adapter bug spotted (TfL 19 inbound): `orderedLineRoutes` ids missing from `stopPointSequences` are
  silently dropped from the pattern.
