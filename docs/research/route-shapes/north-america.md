# Route shapes: north-america group

Group: mbta, metrotransit, mta-bustime, oba-pugetsound, oba-tampa, umo-ttc.
Every live test ran on 2026-10-19, between 08:40 and 09:05 Israel time (late evening in the US). [V] means
verified live that day. [U] means unverified. Raw replies and check files are in
`scratchpad/regions/dl/<provider>/`. Helper scripts are in `scratchpad/regions/na_tools/`: `get.py`,
`poly.py`, `oba_pieces.py`, `stitch.py`, `union_check.py`, `ttc_conv.py`, `mt_check.py`.

**The main finding for the OBA-style adapters.** This covers mta-bustime, oba-* and, in practice,
metrotransit. Their `routePattern` stop list is the **union of every variant in the direction**: OBA's
`stopGroups[dir].stopIds`, or Metro Transit's timetable `stoplist`. When a direction has two origins or two
terminals, no single real trip visits all of those stops in order. In that case any single shape FAILs
`shapecheck` on the branch-only stops, and that is not a geometry error. The fix:

- draw the direction's shape **pieces** as several `MapPolyline`s; every stop then lies on a piece
  (`union_check.py`: worst stop at most 20 m on all 18 directions tested);
- for the in-order check and for `RouteGeometry`, use the single stitched or main path, and accept that
  branch-only stops fall off it.

Alternatively, change those adapters to return one real trip pattern instead of the union. That is an
adapter design decision for later.

---

## mbta

**1. How the adapter loads a line today**
- `lines(atStop:)` makes one call:
  `GET /route_patterns?filter[stop]=…&include=route,representative_trip.stops&…`.
- `TransitLine.id` is the **route-pattern id** (`1-_-0`, `39-Y-0`).
  `providerRefs = {route, direction, trip: <representative trip id>}`.
- `routePattern(for:)` makes one call:
  `GET https://api-v3.mbta.com/route_patterns/{line.id}?include=representative_trip.stops&fields[route_pattern]=direction_id&fields[trip]=headsign,stops&fields[stop]=name,latitude,longitude,municipality,address,on_street,at_street`.

**2. Recipe: 0 extra calls, piggybacked on the `routePattern` call [V]**
```
GET https://api-v3.mbta.com/route_patterns/{line.id}
    ?include=representative_trip.stops,representative_trip.shape
    &fields[route_pattern]=direction_id
    &fields[trip]=headsign,stops,shape          ← add "shape" (the relationship)
    &fields[shape]=polyline                     ← new
    &fields[stop]=name,latitude,longitude,municipality,address,on_street,at_street
```
Read the shape from `data.relationships.representative_trip.data.id`, then
`included["trip:<id>"].relationships.shape.data.id`, then `included["shape:<id>"].attributes.polyline`.

**3. Format**
- Google encoded polyline, precision 5, lat/lon order.
- One shape per pattern. The pattern is exactly one representative trip, so its stop list and its shape
  belong to the same trip: no stitching, no reversing, no choice between variants.
- The DTO needs a `polyline` attribute.

**4. Live checks [V 2026-10-19]**

| pattern | kind | stops | pts | max / median offset | ratio | verdict |
|---|---|---|---|---|---|---|
| 1-_-0 | main (fixture line 1) | 24 | 187 | 11.3 / 7.6 m | 1.02 | PASS |
| 39-Y-0 | short-turn variant (typicality 3) | 18 | 194 | 10.6 / 6.1 m | 1.14 | PASS |
| 36-C-1 | "Charles River Loop" variant | 30 | 219 | 10.4 / 5.5 m | 1.03 | PASS |
| 34E-4-0 | long, 22 km | 82 | 591 | 11.9 / 5.7 m | 1.02 | PASS |

Payload, compressed (gzip) then raw, for the current call against the piggybacked one:
- 1-_-0: 1,491 B / 11.5 KB today, 2,025 B / 12.2 KB with the shape (**+0.5 KB** gzipped).
- 34E: 3.9 KB, then 5.4 KB (+1.4 KB).
- Latency: 0.9–2.7 s with or without the shape (no difference).

**5. Cache key and change detection**
- Key: `mbta/<pattern id>`. Also store the shape id (`010154`, `34E0283`): it changes with each service
  rating.
- Responses carry `Last-Modified`. Sending `If-Modified-Since` returned **HTTP 304 with an empty body** [V].
  Revalidate weekly, or when the pattern's stop ids change.

**6. Limits and terms**
- 20 requests per minute keyless (`x-ratelimit-limit: 20` [V]); 1,000 per minute with a free key.
- The piggyback adds no request.
- MassDOT Developers License Agreement: credit MassDOT; the app already shows "Data provided by MassDOT".
  Nothing seen restricts drawing the geometry [U].

**7. Proxy changes:** none (keyless, called direct).

---

## mta-bustime

**1. How the adapter loads a line today**
- One `GET /where/stops-for-route/{route}.json?includePolylines=false&version=2`, cached per route for the
  session, serves `lines(atStop:)`, `stopsNearby` and `routePattern`.
- Line id `MTA NYCT_M15|0`, with `providerRefs {route, direction}`.
- The pattern is `stopGroupings[type=direction].stopGroups[id==dir].stopIds`, which is the union of the
  direction's variants.
- Live data brings a shape id the adapter doesn't read yet: SIRI `MonitoredVehicleJourney.JourneyPatternRef`
  (`MTA_M150066`, `MTA_SBS530061`) [V].

**2. Recipe**
- **(A) Primary: 0 extra calls.** Flip the existing call to `includePolylines=true`:
  ```
  GET https://bustime.mta.info/api/where/stops-for-route/MTA%20NYCT_M15.json?includePolylines=true&version=2
  ```
  Read `data.entry.stopGroupings[type=direction].stopGroups[id==direction].polylines[]`.
- **(B) Exact single shape: 1 call**, only when a shape id is already in hand from a live bus. This is
  optional:
  ```
  GET https://bustime.mta.info/api/where/shape/{JourneyPatternRef}.json   (e.g. MTA_M150066)
  ```
  It returns `data.entry.points`.

**3. Format and decoding** (the same applies to every OBA server)
- `polylines[]` entries are `{points, length, levels:""}`. `points` is a Google polyline, precision 5,
  lat/lon. `length` is the point count.
- Ignore `entry.polylines`: it is the union over both directions.
- Each direction's pieces are its trip shapes, merged and cut where variants diverge or rejoin.
  - They are **unordered**, but each piece is already oriented in travel order. They never needed
    reversing.
  - A single-shape direction gives one piece, identical to `where/shape` point for point
    (E Line direction 1, 405 points) [V].
  - A direction with branches gives several pieces: M15 2, B46 3, Q58 3, M4 26 (mostly short stubs).
- **To draw:** one `MapPolyline` per piece. Every union stop is then on the drawing.
- **To get one path** (for the in-order check and progress), `stitch.py`:
  - join two pieces, within 3 m, in one of two ways:
    - *merge*: a piece's end touches any vertex of another; continue on the other from that vertex;
    - *fork*: another piece's start touches a vertex of the current one; cut the current piece there.
  - try every start and every join (depth-first; a direction has at most about 26 pieces, so this is
    trivial);
  - keep the path with the fewest stops more than 50 m away, then the shortest.
  - On M15 direction 0 the stitched path **equals `where/shape/MTA_M150066` exactly** (334 identical
    points) [V].

**4. Live checks [V 2026-10-19]** (`key=TEST` works on MTA's where API and SIRI)

| route / dir | pieces | single path (stitched) | union of pieces: max / median | note |
|---|---|---|---|---|
| M15 d1 (fixture line) | 2 | PASS, 13.7 / 6.0 m, ratio 1.02 | 13.7 / 6.0 m | |
| M15 d0 | 2 | FAIL: stops 8 and 9 off (207 m) | **12.7 / 4.6 m** | stop 8 belongs to a variant starting further up; without it, PASS 12.7 m. `where/shape` is identical |
| B46 d1 | 3 | PASS, 10.3 / 7.8 m | 10.3 / 7.8 m | three pieces chained end to start |
| B46 d0 | 3 | FAIL: stops 1 and 2 | 16.9 / 8.7 m | two origins (Kings Plaza and a second start), merged |
| Q58 d0 / d1 | 3 / 2 | PASS, 14.1 m / PASS, 10.4 m | 7.5 / 10.4 m | |
| M4 d1 / d0 | 22 / 26 | PASS, 19.5 m / FAIL: last 2 stops | 19.2 / 15.1 m | d0 has two terminals |

All the FAILs are branch-only stops in the union stop list. None is a geometry error.

Payload, compressed / raw, with latency:

| call | M15 | B46 | Q58 | M4 |
|---|---|---|---|---|
| `stops-for-route`, `includePolylines=false` (today) | 6.3 KB / 29.8 KB, 4.5 s | | | |
| `stops-for-route`, `includePolylines=true` | 8.5 KB / 34.9 KB, 7.7 s | 8.4 KB / 33.6 KB, 4.8 s | 7.0 KB / 23 KB, 7.2 s | 11.9 KB / 55.7 KB, 7.6 s |
| `where/shape` | 1.1 KB / 1.3 KB, 3.3 s | | | |

So the piggyback adds about **2 KB gzipped (+35%) per route**. bustime.mta.info is slow (2–8 s) whatever
is asked.

**5. Cache key and change detection**
- Key: `mta-bustime/<route id>|<direction id>`.
- Change detection costs 0 calls: a hash of the direction's `stopIds`, which every `route()` call returns
  anyway.
- No ETag. The reply says `Cache-Control: private, max-age=60`.
- Shape ids (`MTA_M150066`) are stable within a GTFS pick.
- TTL: keep while the stop-id hash matches; revalidate weekly.

**6. Limits and terms**
- No numeric limit is published for the where API. The key is revoked for whole-system VehicleMonitoring
  faster than every 30 s, which does not apply here.
- MTA terms: credit allowed, no implied endorsement. Shapes come from MTA's public GTFS, and nothing
  restricts drawing them [U].

**7. Proxy (`functions/src/agencies.ts`, `mta`)**
- Recipe A needs **no change**. `where-stops-for-route` already allows
  `includePolylines: /^(true|false)$/`. The cache key differs from the `false` variant; TTL is 1 h.
- Recipe B needs one new row in `AGENCIES.mta.paths`:
  ```ts
  {
    name: "where-shape",
    pattern: /^\/where\/shape\/([^/]+)\.json$/,
    segment: /^MTA_[A-Za-z0-9]{1,24}$/,   // MTA_M150066, MTA_SBS530061
    params: {},
    ttlSeconds: STATIC_TTL,
  },
  ```

---

## oba-pugetsound

**1. How the adapter loads a line today**
- Identical to MTA: one `GET /where/stops-for-route/{route}.json?includePolylines=false&version=2` per route,
  cached for the session.
- Line id `1_102615|0`, with `providerRefs {route, direction}`.
- The pattern is the direction's `stopGroup`, which is the union of its variants.
- Shape ids already arrive in replies the adapter downloads but does not decode yet:
  - `trips-for-route` (vehicles) has `references.trips[].shapeId`;
  - `arrivals-and-departures-for-stop` has the same.
  - Filter by `routeId`: references include interlined trips of other routes [V].

**2. Recipe**
- **(A) 0 extra calls:** `includePolylines=true` on the existing `stops-for-route` call, then pieces per
  direction, as for MTA.
- **(B) 1 call (optional):** `GET /where/shape/{shapeId}.json`, with `shapeId` taken from trip references
  already fetched. It only exists while trips run, so it can't be the primary.

**3. Format:** as for MTA (the same OBA server). Polylines are precision 5, lat/lon, already oriented.

**4. Live checks [V 2026-10-19, key=TEST]**

| route / dir | pieces | single path | union max / median | note |
|---|---|---|---|---|
| E Line 1_102615 d0 (fixture) | 1 | PASS 9.2 / 7.9 m, ratio 1.02 | 9.2 m | |
| E Line d1 | 2 | FAIL stop 34 (91 m) | **8.5 / 7.3 m** | main piece == `where/shape/1_20675017` (405 identical points); without stop 34 PASS 8.5 m. Stop 34 is a 3-point terminal stub |
| 44 (1_100224) d0 / d1 | 1 / 1 | PASS 9.2 m / PASS 8.2 m | | |
| D Line (1_102581) d0 | 1 | PASS 8.8 m | | |
| D Line d1 | 2 | FAIL 1 stop (two terminals) | 8.6 / 7.5 m | fork stub at the downtown end |

Payload, compressed / raw, with latency:
- E Line `stops-for-route`: 4.1 KB / 33.7 KB, 1.65 s today; **6.0 KB / 39.1 KB, 0.88 s** with polylines.
- D Line with polylines: 5.6 KB / 35 KB. Route 44 with polylines: 4.4 KB / 25 KB.
- `where/shape`: 0.95 KB / 1.3 KB, 0.6 s.
- `trips-for-route`: 5.4 KB / 42.7 KB, 5.4 s.

**5. Cache key:** `oba-pugetsound/<route>|<dir>`, with the stop-id hash as the change signal (0 calls). No ETag.
King County Metro's shape ids (`1_20675017`) change at service changes, twice a year. Keep while the hash
matches; revalidate weekly.

**6. Limits and terms**
- The real key's limit is not published. **`key=TEST` is heavily throttled.** 4 of 11 calls got HTTP 429
  (`"rate limit exceeded"`), including the first call of the session, and it recovered after 1–5 minutes.
  The proxy holds `upstreamPerMinute: 300`.
- Sound Transit Transit Data Terms: free use, data "AS IS", no agency mark in the app name. Shapes are part
  of the data, so drawing them is allowed [U explicit].

**7. Proxy (`OBA_PATHS`, shared by pugetsound and tampa)**
- Recipe A needs **no change**: `includePolylines: BOOL` is already allowed.
- Recipe B needs one row in `OBA_PATHS`:
  ```ts
  {
    name: "where-shape",
    pattern: /^\/where\/shape\/([^/]+)\.json$/,
    segment: OBA_ID,          // matches "1_20675017"
    params: {},
    ttlSeconds: STATIC_TTL,
  },
  ```

---

## oba-tampa

- **1–3. Load path and recipe:** the same adapter and the same recipe as oba-pugetsound: `includePolylines=true`
  on `stops-for-route`, with `where/shape` as the option. The server is OneBusAway (onebusawaycloud).
- **4. Live checks: not possible.** `key=TEST` gets **HTTP 401 "permission denied"** [V]. I did not use the
  production key, per the brief.
  - Offline evidence that the shapes it would serve are good: HART's GTFS
    (`https://www.gohart.org/google/google_transit.zip`, 1.87 MB, Last-Modified 2026-09-30, **has
    shapes.txt**, 349 KB compressed / 1.37 MB raw) [V].
  - The routes serving the fixture stop 4234 were checked against their own GTFS stop sequences:
    - route 8 d1: PASS, 27.9 m;
    - route 9 d1: PASS, 18.8 m;
    - 360LX d0: FAIL by a hair, one stop at 50.4 m (stop 48, a single off-road stop, probably a terminal
      bay; the median is 7.8 m).
  - So the OBA polylines for Tampa should behave like Puget Sound's [U live].
  - The download ignored the range header and returned the whole zip (HTTP 200).
- **5. Cache key:** as for Puget Sound.
- **6. Limits:** the key was granted by OTSF with no terms beyond it. Credit HART.
- **7. Proxy:** `OBA_PATHS` is shared, so the same (optional) `where-shape` row covers Tampa.

---

## umo-ttc

**1. How the adapter loads a line today**
- `config(route:)` makes one call:
  `GET https://retro.umoiq.com/service/publicJSONFeed?command=routeConfig&a=ttc&r={route}&terse=true&verbose=true`.
  It is cached for the session and fetched for every route at a stop and for up to 6 routes per name search.
- Line id `29|29_0_29Ccon`: route tag | **direction (variant) tag**, with `providerRefs {route, direction, way}`.
- `routePattern` returns that one variant's `direction.stop[]`. It is a real single variant, not a union.

**2. Recipe: 1 extra call per cold line** (0 if that call also replaces the config fetch)

Drop `terse=true`:
```
GET https://retro.umoiq.com/service/publicJSONFeed?command=routeConfig&a=ttc&r=29&verbose=true
```
- The same reply carries `stop[]`, `direction[]` and `path[]`, so it can also serve as the line's config.
- I don't recommend piggybacking by dropping `terse` in `config()` for every route: it costs 2.7–8× the
  bytes, the server sends no gzip, and searches fan out. The feed's own cap is 2 MB per 20 s per IP.

**3. Selecting and ordering segments [V]**
- `route.path[]` holds `{tag: [{id}...], point: [{lat, lon}...]}`. Values are strings with 7 decimals.
  `tag` and `point` are object-or-array (the XML translation).
- Each path tag id is `<dirTag>_<seq>_<fromStopTag>_<toStopTag>`, for example `29_0_29Ccon_16_12902_10415_ar`.
  - Stop tags can contain `_` (`10415_ar`), so split the remainder at the `_` where both sides are known stop
    tags.
  - Direction tags can contain `_` or `*`, so match by the **prefix `<dirTag>_`**.
  - One segment can carry tags of several variants; it is shared.
- **Select** the paths whose tag starts with the line's direction tag.
- **Order** them by `seq` (even numbers: 2, 4, 6…). Each segment's from/to stops are consecutive
  timepoints of the direction's stop list ((0,10), (10,18) …), and the joints meet at 0.0 m.
- **Concatenate**, dropping the duplicate joint point. No reversing is needed. Variants are explicit: a short
  turn like `29_1_DLWI` has its own single segment.

**4. Live checks [V 2026-10-19]**

| direction tag | stops | segments | pts | max / median | ratio | verdict |
|---|---|---|---|---|---|---|
| 29_0_29Ccon (fixture route 29, UI south) | 48 | 8 | 317 | 0.0 / 0.0 m | 1.05 | PASS |
| 29_1_29Ccon (UI north) | 48 | 8 | 317 | 0.0 / 0.0 m | 1.05 | PASS |
| 29_1_DLWI (short turn) | 10 | 1 | 61 | 0.0 m | 1.11 | PASS |
| 29_0_TREX, 29_0_DLEX (variants) | 45 / 35 | 7 / 6 | 211 / 169 | 0.0 m | 1.03 | PASS |
| 52_1_52B (52 Lawrence W, 30 variants) | 78 | 17 | 358 | 0.0 m | 1.04 | PASS |
| 52_0_52A / 52_1_52G / 52_1_LWT1* | 58 / 43 / 58 | 13 / 13 / 14 | 353 / 267 / 402 | 0.0 m | 1.07 / 1.04 / 1.13 | PASS |

Offsets are 0 m because NextBus draws its paths through the stop positions: stops lie on the lines, though
not on vertices. With about 1 point per 60–70 m and ratios of 1.03–1.13, the paths follow the roads.

Payload (no gzip is offered, even with `--compressed` [V]):

| route | terse config (today) | full config | latency |
|---|---|---|---|
| 29 | 18.0 KB, 4.0 s | 49.1 KB | 3.1–5.0 s |
| 52 | | 142.6 KB | **33.6 s** |

The retro feed is slow and variable.

**5. Cache key and change detection**
- Key: `umo-ttc/<route>|<dirTag>`. No ETag or Last-Modified.
- Change detection costs 0 calls: a hash of the direction's stop tags from the terse config the adapter
  fetches anyway.
- TTC board periods change about every 6 weeks. Revalidate weekly, or when the hash changes.

**6. Limits and terms:** rev 1.24 caps each IP at about 2 MB per 20 s and asks for polls no faster than
every 10 s. Keep the copyright notice (already done). Umo may end the feed at any time.
- Backup source: TTC's open GTFS (open.toronto.ca), which has shapes.txt [U].

**7. Proxy:** none (keyless).

---

## metrotransit

**1. How the adapter loads a line today**
- `lines(atStop:)` makes one call, `GET /nextrip/{stop}`. Its departures carry `trip_id`, `route_id`,
  `direction_id` and `terminal` (the branch letter).
- Line id `5-0`, with `providerRefs {route, direction}`.
- `routePattern` takes three calls:
  1. `/schedule/routes`, cached;
  2. `/schedule/routedetails/{param}`;
  3. `/schedule/stoplist/{route}/{schedule_number}`.

  Stop positions come from GTFS `stops.txt`, fetched by range request.
- The stop list is the **union of every trip in that day-type timetable**. Route 5 weekday NB includes a
  school-trip deviation stop; route 18 includes branches C, D and E.

**2. No live shape [V]**
- `GET https://svc.metrotransit.org/nextrip/shape/{route_id}` is still in the NexTrip v2 OpenAPI and should
  return a GeoJSON FeatureCollection. It answered **HTTP 500 with an empty body** for routes 5, 21 and 921,
  with and without `Accept: application/json`.
- None of the other published APIs (schedule, tripplanner, alerts) has a shape endpoint.

**8. Offline / GTFS source (for the pfaedle/offline agent) [V]**
- `https://svc.metrotransit.org/mtgtfs/gtfs.zip` is 23.1 MB (ETag `"94c2f2afc65cdd1:0"`, Last-Modified
  2026-10-15, updated weekly) and **has shapes.txt**: 4.07 MB compressed / 15.4 MB raw. No map-matching is
  needed.
- trips.txt is 229 KB / 1.69 MB, with columns `route_id, direction_id, trip_id, shape_id, branch_letter`.
- **Id mapping:**
  - NexTrip `trip_id` equals the GTFS `trip_id` (vehicles `1369061` and `1371821` were found in trips.txt) [V];
  - NexTrip `route_id` and `direction_id` equal GTFS's;
  - stoplist `stop_id` equals the GTFS `stop_id` and `stop_code`.
- **Ranged download is slow:** about 36 KB/s (shapes.txt alone took 112 s). Range requests work (206).
- **Recommended:** precompute one file per `(route_id, direction_id)` holding every distinct shape of it
  (route 5 NB has 2 distinct geometries; route 18 SB has 7), plus a `shape_id` index by `trip_id` /
  `branch_letter`. The app fetches that file: **1 call per cold line from our static host**.

**4. Offline checks** (GTFS shapes against the adapter's own stoplist, mapped through GTFS stops) [V]

| route / dir | single main shape | union of the direction's shapes |
|---|---|---|
| 5 SB (d1, 80 stops) | 650005006 (72 trips): **PASS 11.4 / 6.2 m**, ratio 1.07 | |
| 5 NB (d0, 83 stops) | 650005003: FAIL, 1 stop ("North Community High School", 461 m: a school-trip deviation in the union stop list); **PASS 9.9 m** without it | **9.9 / 6.0 m**, the deviation covered by shape 650005001 |
| 18 SB (d1, 86 stops, branches C, D, E) | best single shape (E) FAILs on 6 branch-only stops | **16.8 / 8.0 m**, all 86 stops |

**5. Cache key:** `metrotransit/<route>-<dir>`, holding the shape set and the shape id per trip.
- Change signal: the GTFS zip's `ETag` / `Last-Modified`. One `HEAD` per week is done by the offline job,
  not the app. The app compares the stoplist hash.

**6. Limits and terms:** none published for NexTrip. The GTFS licence was not re-checked [U].

**7. Proxy:** none.

---

## Summary

| provider | extra calls per cold line | piggyback? | format | verified lines PASS/FAIL | max offset | size (gz) | latency | cache key | notes |
|---|---|---|---|---|---|---|---|---|---|
| mbta | **0** | yes: `include=representative_trip.shape` + `fields[shape]=polyline` on `route_patterns/{id}` | Google polyline p5, one per pattern | 4/4 PASS (main, short turn, loop, 22 km) | 11.9 m | +0.5–1.4 KB | same as today, 0.9–2.7 s | pattern id + shape id | 304 on `If-Modified-Since` [V]; 20/min keyless |
| mta-bustime | **0** (A) / 1 `where/shape` (B, optional) | yes: `includePolylines=true` on `stops-for-route` | per-direction pieces, Google p5, unordered, already oriented | single path 5/8 PASS; **pieces 8/8** (all stops ≤ 19.2 m) | 19.5 m (path), 19.2 m (pieces) | +2 KB (6.3 → 8.5 KB) | 2–8 s (slow host) | route\|dir + stopIds hash | stitched path == `where/shape` exactly; FAILs are union-pattern branch stops |
| oba-pugetsound | **0** (A) / 1 (B) | yes, same as MTA | same | single path 4/6 PASS; **pieces 6/6** | 9.2 m | +2 KB (4.1 → 6.0 KB) | 0.9–14 s (TEST key throttled) | route\|dir + stopIds hash | `key=TEST` gave 429 on 4/11 calls |
| oba-tampa | 0 (A) / 1 (B) | same | same | not live: TEST → 401; GTFS shapes 2/3 PASS (3rd at 50.4 m) | – | – | – | route\|dir + hash | HART GTFS has shapes.txt (1.4 MB raw) |
| umo-ttc | **1** (non-terse `routeConfig`; can double as the config) | possible but not advised (+31–125 KB, no gzip) | `path[]` point lists; select by `<dirTag>_` prefix, order by seq | 9/9 PASS (routes 29 and 52, with short turns) | 0.0 m | 49–143 KB raw | 3–34 s | route\|dirTag + stop-tags hash | feed slow; 2 MB/20 s per-IP cap |
| metrotransit | 1 (our static file) | no live shape | GTFS shapes.txt | 5 SB PASS; 5 NB, 18 SB pass as union | 11.4 m single, 16.8 m union | n/a | n/a | route-dir + GTFS ETag | `nextrip/shape` still HTTP 500 [V]; GTFS 23 MB, shapes 4 MB compressed; trip_id maps 1:1 |

**Proxy changes:**
- **None are needed** for the recommended recipes. `agencies.ts` already allows `includePolylines=true` on
  `where/stops-for-route` for `mta` and for `OBA_PATHS` (pugetsound, tampa).
- For the optional exact-shape call, add a `where-shape` row:
  - `OBA_PATHS`: `pattern: /^\/where\/shape\/([^/]+)\.json$/`, `segment: OBA_ID`.
  - `mta`: the same pattern, with `segment: /^MTA_[A-Za-z0-9]{1,24}$/`.
  - Both `params: {}` and `ttlSeconds: STATIC_TTL`.

**Blockers and caveats:**
- OBA Tampa can't be verified live without the production key (TEST gets 401).
- The Puget Sound TEST key is rate-limited hard.
- Metro Transit has no live shape: it needs the offline GTFS file.
- TTC's retro feed can take 30 s or more for a big route.
- MTA, OBA and Metro Transit return union stop lists, so the modal should draw every piece of the
  direction, not one path.
