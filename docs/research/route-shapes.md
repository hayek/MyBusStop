# A line's route on the map — research, 2026-10-19

Goal: tapping a line's "i" icon (search results, a stop's lines, the board) opens a modal with a map of the
line's real route (following the roads, never straight stop-to-stop segments) and its stops. Each line's shape is
fetched once and cached; API calls are kept to the minimum so no provider's rate limit is ever at risk.

**Result.** Every region we ship can draw a real route:
Of the 38 providers in `TransitProviders.all`:
- **13 cost 0 extra calls.** The shape rides on a reply the adapter already fetches, needs one more field or
  parameter, or (Adelaide) comes from the GTFS index the app already builds.
- **18 cost 1 extra call per line, once.**
- **7 have no shape from their API** (Switzerland, Nürnberg, Brussels, Luxembourg, Poznań, Minneapolis,
  Adelaide), nor do 22 of MTR Bus's 26 routes and Vienna's Badner Bahn. Precomputed files were built and tested
  (§5), then dropped on 2026-10-19 to keep the app free of a hosted pipeline: those lines get no map button.
- **Kraków is unresolved:** its server blocked every request, for the whole provider, not just shapes.

Per-region detail, with live measurements, exact URLs and decoding notes, is in `route-shapes/`:
- [israel](route-shapes/israel.md)
- [north-america](route-shapes/north-america.md)
- [west-europe](route-shapes/west-europe.md)
- [central-east-europe](route-shapes/central-east-europe.md)
- [asia-oceania](route-shapes/asia-oceania.md)
- [offline](route-shapes/offline.md) (researched and tested, not used: §5)

Every recipe was run on real lines on 2026-10-19 and judged by `route-shapes/shapecheck.py`: stops are matched in
order along the shape, so loops and repeated streets are handled.

## 1. Why not infer the shape from the stops

Google Maps does not compute bus shapes. Agencies send `shapes.txt` in their GTFS, and where a feed has none,
tools map-match the stops onto OpenStreetMap offline (pfaedle, MOTIS/Transitous).

Measured on 30 Israeli lines against the Ministry of Transport (MOT) shapes. Each method got only the ordered stop
coordinates and was scored on:
- **recall:** the share of the true route the method drew (within 15 m);
- **precision:** the share of the drawn line that lies on the true route;
- **length:** drawn length divided by true length.

| method | median recall | median precision | length |
|---|---|---|---|
| straight stop-to-stop | 36% | 42% | 0.86 |
| car routing through the stops (OSRM, the same kind as Apple's directions) | 97% | 87% | 1.19 |
| Valhalla bus map-matching | 97% | 95% | 1.00 |
| **pfaedle** (offline HMM map-matching) | **99%** | **99%** | **1.00** |
| our pfaedle-style HMM prototype | 98.7% | 98.8% | 0.99 |

- **Routing between stops is the "semi-correct" result.** It loops around blocks to reach stops, detours at
  interchanges, and can't use bus-only roads.
- **Map matching is right, but only offline.** On the phone, the road data is the problem, not the
  algorithm:
  - free vector tiles cost 4–5 MB per line and carry no bus access;
  - Overpass is slow and forbids app traffic.
- **No open-source transit app matches on the phone.** That is why the shapeless regions get precomputed files
  (§5).

## 2. The design every provider plugs into

### Model
```swift
nonisolated struct RouteShape: Codable, Hashable, Sendable {
    /// One polyline per branch. Usually one; several when the pattern's stop list merges variants
    /// (MTA/OBA directions, Metro Transit, Citybus), so every stop sits on some branch.
    var branches: [[GeoPoint]]
    /// Platform positions when the source has better ones than the provider's stop-area centres
    /// (stop-area centres can be up to 250 m off the road).
    var stopPositions: [String: GeoPoint]?
    /// What the shape was built for, to notice when the pattern changes (see Caching).
    var stopsFingerprint: String
    /// The provider's own version signal when it has one (shape_id, dc:date, datedebutversion…).
    var version: String?
}
```
- **On disk:** store each branch as a Google encoded polyline at precision 6. That loses nothing and is about 4×
  smaller than JSON points; the bus.gov.il line 112 shape goes from 20.7 KB to 4.7 KB.
- **On screen:** simplify with Douglas–Peucker at about 3 m, off the main actor.

### Provider API
- Add `func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape` and a
  `.routeShape` capability. The default throws `unsupported`.
- **"0 extra calls" providers.** Their shape arrives in the reply `routePattern` already fetches, so `routePattern`
  hands the decoded shape to the shape cache while parsing. A later `routeShape` call then costs nothing.
  Pass shapes around the cache, never inside `RoutePattern`: patterns are cached daily and copied to the widget
  and watch, which don't need the geometry.
- **One shared cache key across providers** where the ids are the same. In Israel, Stride's line ref equals
  bus.gov.il's routeId, so one cached shape serves both providers.

### Call budget and caching
- **When to fetch:** only when the modal opens, or for free inside `routePattern` (above). Never at launch, never
  in the background, never for a widget.
- **Key:** `shape/<datasetID>/<line.id>`, in `TransitCache`, on disk (Application Support), with the existing
  in-flight de-duplication.
- **Lifetime: keep indefinitely.** Refetch only when:
  1. the pattern's stops fingerprint changes. The fingerprint is the SHA-1 of the ordered stop codes with
     consecutive duplicates collapsed. Patterns already refresh daily, so this costs no extra call.
  2. the provider's free version signal changes. Examples:
     - Carris: the `shape_id` plan prefix;
     - Toei: `dc:date`;
     - STAR Rennes: `datedebutversion`;
     - Gdańsk: `activationDate`;
     - Tampere: a new route id;
  3. it is older than 30 days, and the modal is opened. The stale copy is drawn at once while the refresh runs.
- **If the refresh fails:** keep drawing the stale shape, exactly like stale patterns today.
- **Worst case per rider:** one request per line opened, then roughly one a month for lines they keep opening.
  The only multi-request recipe is VAG's fallback when its exact key misses (up to 3).

### Checking a shape before drawing it
Run once when a shape is fetched; the result is cached with it.
1. **Stops in order along the shape.** Use dynamic programming, as `route-shapes/shapecheck.py` does, so loops
   work.
2. **Distance limits:**
   - intermediate stops within 50 m;
   - the first and last stop within 150 m (terminals and bus stations sit off the road: Entur, Vienna, Ljubljana,
     Istanbul EM1, Poznań);
   - stop-area-centre providers within 150–200 m (Luxembourg, VBB station centres, Swiss/VGN API coordinates when
     the file has no platform position).
3. **Merged-variant patterns** (MTA, OBA, Metro Transit, Citybus): check each stop against the union of branches.
4. **Reject geometry that is really straight lines:**
   - fewer than 1.5 points per stop, or
   - more than half the points sitting on stops.

   Real shapes had 0.2–8% of their points on stops.
5. **Length ratio is a warning, not a rejection.** Real Peak, alpine and express routes run 2–2.4× the stop
   chords.
6. **On failure:** draw the stops only, with no line (never straight segments), and log one Crashlytics non-fatal
   per provider and version, so a broken feed shows up.

### Rendering in the modal
- SwiftUI `Map` with one `MapPolyline` per branch in the line's colour, and stop annotations: first and last stop
  emphasised, the rider's stop highlighted.
- Camera fits the shape's bounding rect.
- Credits row: the provider's `attribution` (Hong Kong's names the CSDI Portal its route lines come from).
- `StopCardView` is the model to copy: a sheet with `.presentationDetents([.medium, .large])`.
- Entry points for the line "i":
  - `StopCardView` line rows;
  - `ConfirmStopPanel` line rows;
  - the search and nearby rows in `SetupComponents`;
  - the board.

## 3. Per-provider recipes

Notation:
- **extra calls:** requests per line beyond what the adapter already makes for that line;
- **0\*:** the shape is in a reply we fetch, or needs one added field or parameter;
- **none:** no shape from the API; the line has no ⓘ and no map (§5).

Every row was verified live (shapecheck PASS on the lines named in the region report) unless the Verified column
says otherwise.

| provider | extra calls | where the shape comes from | format | verified | cache / change signal |
|---|---|---|---|---|---|
| bus.gov.il | 0\* (or 1, from the modal) | `Routes/GetRouteFullData?routeId=` → `data.polyline` + stops | HERE flexible polyline (6 real decimals) | 4/4: loop, Saturday-only variant, intercity; max 5.1 m | routeId (stable since 2025) + fingerprint |
| stride | 0 (borrows bus.gov.il) | same key | — | 2/2 | shared Israeli key |
| transitous | 0\* | `legs[0].legGeometry` in `/api/v6/trip` | polyline precision 6 | 6/6 | route + direction + fingerprint |
| mbta | 0\* | `route_patterns/{id}` + `include=representative_trip.shape` & `fields[shape]=polyline` | polyline 5 | 4/4 | shape id; `If-Modified-Since` → 304 |
| mta-bustime | 1 | `stops-for-route` with `includePolylines=true`, asked only when the card opens (the shared setup call stays without, to keep stop search light) | polyline pieces → branches | 8/8 as branches | route + direction + fingerprint |
| oba-pugetsound | 1 | same | same | 6/6 as branches | same |
| oba-tampa | 1 | same | same | [V] live 2026-10-19 (9 branches, worst stop 108 m) | same |
| umo-ttc | 1 | `routeConfig` without `terse`; segments `<dirTag>_<seq>_…` sorted by seq | point lists | 9/9, 0 m | route + dirTag + fingerprint (49–143 KB, slow) |
| metrotransit | none | GTFS `shapes.txt` (`nextrip/shape` returns HTTP 500); GTFS ids = NexTrip ids | file | 5/5 + branches | GTFS ETag |
| tfl | 0\* | `lineStrings` in `Route/Sequence/{dir}`: dedupe, then take the shortest piece that passes; never join | JSON coords | 6 PASS / 1 variant without geometry | line + dir + fingerprint |
| star-rennes | 1 | `parcours` field, `where=id="{parcours}"` (20k calls/day/IP) | GeoJSON | 2 PASS / 1 short trace | parcours id + `datedebutversion` |
| carrismetropolitana | 1 | `/v2/shapes/{shape_id}` (id already in the pattern) | GeoJSON | 3/3 | `shape_id` |
| bizkaibus | 1 | `GetRutaParadas_JSON` with `sSentido`; reverse if the shape starts nearer the last stop | Esri paths | 4/4 | line + dir + fingerprint |
| stib | none | STIB GTFS `shapes.txt` (stop_id = adapter id; line = `route_short_name`) | file | 127 of 148 (most fails are works diversions) | GTFS version |
| mobiliteit-lu | none | national GTFS `shapes.txt` (stop id = HAFAS id zero-padded to 12) | file | 93 of 125 at 50 m, 96% at 100 m | GTFS version; 200 m tolerance |
| vbb | 0\* | `journeyDetail` + `poly=1` (proxy: add `poly`, `polyEnc`) | polyline | [U] on the real API; shape matched GTFS within 6.5 m via the community mirror | line + dir + fingerprint |
| entur | 0\* | `pointsOnLink { points }` added to the journeyPatterns query | polyline 5 | all PASS vs kerb-side quays | journey pattern id |
| foli | 1 | `/gtfs/v0/{ds}/shapes/{shape_id}` (id in `providerRefs`) | JSON points | 6/6 | `shape_id` |
| tampere | 1 | `/journeys/api/1/routes/{id}` (from `routeUrl`); **subtract** the deltas | delta string | 7/7 | route id changes when the shape changes |
| ztm-gdansk | 1 (parallel with the stops call) | `ckan2…/shapes?date=&routeId=&tripId=` | GeoJSON lon/lat | 3/3 | `activationDate` |
| ztm-poznan | none | ZTM GTFS `shapes.txt` (ids match PEKA) + GTFS stop order | file | 4 PASS / 1 terminus loop | GTFS version |
| mpk-krakow | 1, if unblocked | `pathinfo/trip?id=` | wayPoints | **blocked (503 block page)**; GTFS shapes 16/16 but stop ids don't map | — |
| wienerlinien | 1 (2 if the derived id misses) | `ogd_routing` pieces per direction, stitched | GeoJSON | 3 PASS / 1 terminus at 65 m | line + dir + fingerprint |
| efa-linz | 0\* | `coords` pieces in the reply `routePattern` already downloads; chain, reverse, splice (`efa_stitch2.py`) | lat/lon pieces | 6/9 (the 3 fails are adapter stop-list bugs); 2-call fallback 3/3 | line + dir + fingerprint |
| lpp-ljubljana | 1 per route group | `routes?route-id=&shape=1` | GeoJSON | 5 PASS / 1 P+R terminus at 68 m | route id + fingerprint |
| tallinn / vilnius / kaunas | 1 per route number | operator map file `{city}_{transport}_{num}.txt` | polyline 5, per variant | 61/61, 0 m | file name + fingerprint |
| iett | 1 per direction | `iett.istanbul/tr/RouteStation/GetRoutePinV2?q={line}_{G\|D}_D0` (unofficial) | WKT pieces | 6 PASS / 1 ring terminal at 63 m | line + dir; fallback: CC BY bulk file |
| hk-kmb / citybus / nlb | 1 per route number | CSDI bus-route layer, `where=ROUTE_NAMEE='{route}' AND <company filter>`; pick the feature all stops fit, trim to the first and last stop | GeoJSON | 4/4, 3/3 (1 stop tolerated), 2/2 | 30 days or a fingerprint change |
| hk-gmb | 1 | the GMB layer, `ROUTE_ID` + `ROUTE_SEQ` (ids match directly) | GeoJSON | 2/2 (one only on the length warning) | route_id + seq |
| hk-mtrbus | 1 (K12/K14/K17/K18) / none (22 routes) | CSDI layer (other routes have no ⓘ) | GeoJSON / file | K12 2/2 | REFERENCE_ID:dir |
| odpt-toei | 0\* | `ug:region` in `odpt:BusroutePattern` (reverse 5 that are stored backwards) | GeoJSON | 704 of 748 patterns | pattern id + `dc:date` |
| adelaide-metro | 0 (weekly index build) | stream `shapes.txt` in the existing GTFS index job (+8.6 MB once) | file | 6/6 | feed version |
| ch-opendata | none | pfaedle over opentransportdata.swiss GTFS (no shapes) | file | 93.4% of 26,132 shapes; 5/5 live lines matched | SHA-1 of collapsed didok sequence |
| vag-nuernberg | none | pfaedle over VGN GTFS (no shapes) | file | 99.4% core, 90.3% rural; 3/3 live | SHA-1 of collapsed VGNKennung sequence |

**Proxy changes** (`functions/src/agencies.ts`):
- **vbb `journeyDetail`:** add `poly: /^[01]$/` and `polyEnc: /^(GPA|DLT|N)$/`.
- **Optional:** OBA/MTA `where/shape/{id}.json`, for an exact single-trip shape.
- **Not needed:** MTA/OBA `includePolylines` is already allowed.

## 4. Bugs found in today's adapters (independent of shapes)
- **Transitous:** `/api/v6/trip` joins interlined trips by default. A Zürich tram 4 request came back labelled as
  line 13, with its stops. Send `joinInterlinedLegs=false` and take the leg containing the boarding stop.
- **Poznań:** PEKA merges every variant of a direction, and each variant restarts its stop numbering. Sorting by
  it interleaves variants, so lines 12, 16, 174 and 5 zig-zag.
- **Linz:** the stop list mixes a line's variants (trams 3, 19, 27).
- **Vienna:** "longest variant" picks variants that aren't in the current timetable (tram 6 to Zentralfriedhof).
  The lowest-numbered variant matched on 3 of 3 lines.
- **TfL:** line 19 inbound drops about 10 stops whose ids are missing from `stopPointSequences`.
- **Kraków:** `ttss.mpk.krakow.pl` answers 503 with a block page, day and night. It may be blocking us, which
  would break the whole provider. Re-test from an EU connection.

## 5. Offline pipeline: built, tested, not used

For the feeds without shapes, a weekly job was built: it map-matched each region's GTFS onto OpenStreetMap with
pfaedle (or took its `shapes.txt`) and served one ~1 KB file per stop pattern from Firebase Hosting. It worked
(93–100% of patterns published, 1 request per card; measurements in route-shapes/offline.md), but it needed a
hosted site, a deploy key and ~1.7 GB of third-party downloads a week. On 2026-10-19 it was dropped to keep the
app light: those providers do not claim `.routeShape`, `hasRouteShape(for:)` is false for their lines, and the
app offers no ⓘ or map for them. A provider that gains shapes in its own API later gets the card by
implementing `routeShape`.

## 6. Implemented (branch `route-shapes`, 2026-10-19)

- **Core:** `BusBus/Transit/Shapes/` (model, polylines, check, shared EFA and Hong Kong helpers),
  `TransitCache.shape`, `TransitProvider.routeShape` / `routePatternWithShape`. A line with no path is kept as a
  rejection and asked again after a week.
- **UI:** `BusBus/Board/LineCardView.swift`, opened from the ⓘ on the confirm step's line rows, the badges in the
  stop card and the full route, and the tapped-bus card.
- **Only where a route can be drawn:** `TransitProvider.hasRouteShape(for:)` decides whether a line gets the ⓘ
  (the confirm step, the stop card's badges, the tapped bus, the full route's badges).
- **Live checks:** `scripts/live-probe.sh` prints a `routeShape` line per provider, and
  `LiveAPITests.routeShape` passes when one of the stop's first three lines passes.

### Request audit (2026-10-19)

`scripts/request-audit/audit.sh` counts every request per phase, for all 37 fixtures and up to four lines each:
this branch against `main`. (The seven offline regions were measured against a local site before they were dropped.)

- **Setup, the board's pattern and a poll:** the same number of requests as on `main` for every provider.
  Runs that differed had seen different live lines.
- **First line-card opening:** at most 1 request. Luxembourg's onward-only patterns cost 2, because they go
  through the index. 13 providers cost 0: the shape comes with the pattern.
- **Re-opening a card:** 0 everywhere. A day-later pattern refresh fetches no shape (0).
- **The other direction's card:** 0 for Toronto, Ljubljana and Tallinn/Vilnius/Kaunas (10-minute memos), and
  for New York, OneBusAway and Hong Kong (session caches).
- **Stored instead of asked again:**
  - a line with no path, or an answer that won't change, is kept for a week;
  - "no trip tonight" (`tryLater`) is asked again next time.
- **Shapes:** 111 of 118 lines pass. The 7 that don't are data problems, and their cards show the stops only:
  - Poznań's merged variants (3 lines);
  - Luxembourg 7;
  - TfL 88 (a misplaced stop);
  - Vienna N71;
  - NLB 11A, which the Transport Department has not drawn.

## 7. Decisions and open items
- **Verify when keys are in hand:**
  - VBB `poly=1` field names, and whether stop coordinates are platforms or station centres (decides 50 m vs
    150 m);
  - Luxembourg having no trip-detail call;
  - OBA Tampa.
- **Not tested on a real Saturday:** bus.gov.il `GetRouteFullData`. The Saturday-only variant worked on a Monday.
- **Slow sources:** bus.gov.il was slow during this morning's peak (3.6–9 s, one 38.7 s) against 0.3 s at night.
  TTC, CSDI and Ljubljana are slow or erratic too. The modal should show the stops and map at once and add the line
  when it arrives.
- **Unofficial endpoints with no published terms:** IETT `GetRoutePinV2`, Poznań's map service, Vienna
  `ogd_routing`, Gdańsk `ckan2`. Each has a documented fallback in its region report.
- **Transitous** terms want an open-source, non-commercial client, so it stays switched off in shipping builds.
  Its shape support is ready if that changes.
