# Offline shape pipeline (group "offline"): ch-opendata + vag-nuernberg

All results were measured on 2026-10-19 on this Mac (10 cores, 24 GB RAM). [V] means verified live or measured on that date. [U] means unverified.
Scripts are in `/private/tmp/claude-501/-Users-amir-Developer-BusBus/679ea7dd-05fc-4173-ad13-8f8bc473d67a/scratchpad/regions/offline_work/scripts/`.
The built sample site is in `.../regions/offline_work/final/site/`.
The live pattern captures are in `.../regions/offline_work/out/live_*.json`.

## TL;DR

- **The key works.** The key is `sha1(",".join(stop codes in order, consecutive duplicates collapsed))[:16]`. The phone builds it from `RoutePattern.stops[].stop.code`. The pipeline builds it from GTFS, mapping Swiss SLOIDs through the `didok` column and VGN DHIDs to their 3rd field. All 8 of 8 live patterns matched exactly: 5 Swiss lines (Zürich 72, Bern 12, Basel 30, Lugano 3, Lausanne 2) and 3 VAG lines (36 short working, 34, and the 37-stop regional 30 to Erlangen). [V]
  - The line name is not part of the key, so a mismatch between a board's line number and `route_short_name` cannot break it.
  - Collapsing duplicates is required. VGN's GTFS lists `3151,3151` (an arrival and a departure platform). Without the collapse, VAG 30 missed.
- **pfaedle is fast and cheap.**
  - All of Switzerland's buses: 26,132 unique patterns in **103–115 s**, peak RAM **2.0–2.4 GB**.
  - VGN buses inside Mittelfranken: 5,731 patterns in **9–14 s**, 0.53 GB.
  - Extracting patterns from the GTFS: Switzerland 96 s and 1.5 GB RSS (it streams 42.1 M stop_times rows); VGN 3.6 s.
  - A weekly GitHub Actions job runs in about 10–15 min on a standard runner.
- **Quality, with the tuned config** (`routing_station_move_penalty_fac: 0.02`). "Strict" means shapecheck PASS: every stop within 50 m in order, and length at most 1.5× the stop chords.

  | Area | Patterns | Strict PASS | Notes |
  |---|---|---|---|
  | Switzerland, all buses | 26,132 | **93.4%** | **96.0%** when the 675 failures that are only "long", not "off", are left out (alpine switchbacks, rail-replacement buses with 2–4 far-apart stops) |
  | Zürich | 550 | 96.4% | |
  | Nürnberg/Fürth/Erlangen core | 704 | 99.4% | measured with 0.05; 96.2% with the stock config |
  | All Mittelfranken VGN | 5,731 | 90.3% | rural village detours are skipped |
  | Swiss trams | 1,423 | 96.9% | stock config |
  | VAG trams | 57 | 94.7% | stock config |

  Agreement with OSM `route=bus` relations, which are independent hand-mapped routes:
  - Nürnberg lines 36, 65, 34 and 30 in the same direction: 98.9–100%.
  - Zürich lines 80, 72, 32, 69, 31 and 33: 94.8–100% with the stock config.
- **The app must draw the stops from the file, not from the API.** Against the files' own platform coordinates (`sp`), all 8 live patterns PASS (max offset 8.6–23.7 m). Against the APIs' coordinates, 4 of 8 FAIL. Both APIs return stop-area centroids that sit up to 129 m (Bern), 144 m (Basel) and 247 m (Erlangen) from the platforms. So every file carries the platform coordinates in `sp`.
- **Size.** About 1.06 KB raw (0.75 KB gzip) per Swiss pattern and 1.56 KB raw (1.1 KB gzip) per rural VGN pattern.
  - Switzerland: 27.8 MB raw (19.7 MB gzip) in 26,132 files, plus an 11,902-file fallback index (5.5 MB).
  - Whole VGN, estimated: about 20 MB plus about 2.3 MB of index. [U]
  - **Hosting recommendation:** a second Firebase Hosting site in the `busbus-ios` project. A cold line costs one CDN-cached request.

## 1. Sources

| | Switzerland (ch-opendata) | VGN / VAG Nürnberg (vag-nuernberg) |
|---|---|---|
| GTFS URL | `https://data.opentransportdata.swiss/en/dataset/timetable-2026-gtfs2020/permalink` (302 to a signed R2 URL, `gtfs_fp2026_20261014.zip`) [V] | `https://www.vgn.de/opendata/GTFS.zip` [V] |
| Size | 290 MB zip, 4.57 GB unzipped (stop_times.txt is 3.7 GB). Download took 57 s. Stream it from the zip; never unzip it. [V] | 15 MB zip, 157 MB unzipped [V] |
| shapes.txt | **None.** The files are agency, routes, trips, stops, calendar, calendar_dates, transfers, feed_info, frequencies, stop_times. [V] | **None.** The files are agency, routes, trips, stops, calendar, calendar_dates, transfers, stop_times. [V] |
| Validity / updates | feed_version 20261014, valid 2025-12-14 to 2026-12-12. Published several times per timetable year (a new file each week or so). [V] | Valid 2026-06-24 to 2026-12-12. Last-Modified 2026-06-24. Updated "ca. vierteljährlich" (about quarterly). [V] |
| Licence | opentransportdata.swiss terms. "The URL opentransportdata.swiss must be cited as the source". Processed data may be published but must name the data user as author. Data must be updated as often as the raw data. [V, terms page] | CC BY 3.0 DE. Attribution: "VGN – Verkehrsverbund Großraum Nürnberg GmbH". [V, vgn.de/web-entwickler/open-data] |
| OSM extract | Geofabrik `switzerland-latest.osm.pbf` (redirects to `switzerland-261018.osm.pbf`), 549 MB [V] | Geofabrik `mittelfranken-latest.osm.pbf`, 96 MB [V]. The VGN feed also covers parts of Oberfranken and Oberpfalz (Bamberg, Amberg and others): only 5,731 of 12,492 bus patterns fall inside a Mittelfranken box. Production should use `bayern-latest.osm.pbf`. [U on size and time] |

Geofabrik was slow today: about 50–500 KB/s per connection. The 549 MB file took about 45 min, while the general link was about 1 MB/s. CI on GitHub runners is normally much faster. [U]

## 2. How the app's ids map to GTFS

### ch-opendata (SwissTransportProvider)

How the adapter gets a line:
- **`lines(atStop:)`:** one `/v1/stationboard?id=<didok>&transportations[]=bus&transportations[]=tram`. The line is `TransitLine.id = "<number>><to>"` with `providerRefs = {stop, number, to, type}`.
- **`routePattern(for:)`:** a board at the rider's stop gives that trip's onward `passList`. A second board at the origin of the opposite trip then gives the whole `passList`. When no opposite trip is found, it falls back to the onward stops only.
- **Stop codes:** DIDOK numbers such as `8591105`.

How GTFS names the same stops [V]:
- stop_times use **SLOIDs**, e.g. `ch:1:sloid:91105::1` (a quay) or `ch:1:sloid:88776:1:3`.
- stops.txt has a **`didok` column** (`8591105`) on every SLOID row, so the mapping is a direct lookup. It is not string surgery.
- Non-Swiss stops keep their own number (e.g. `1401824`, which is in France).

### vag-nuernberg (VAGProvider)

How the adapter gets a line:
- **`lines(atStop:)`:** one `/dm/api/v1/abfahrten/VGN/<vgnId>?product=Bus,Tram&limitcount=40`. The line is `TransitLine.id = "Bus:36:Richtung2"` with `providerRefs = {stop, product, name, direction, headsign, trip, day}`.
- **`routePattern(for:)`:** `/abfahrten/VGN/<stop>/<line>`, then `/fahrten/<product>/<day>/<trip>`. That returns `Fahrtverlauf`, the whole live trip.
- **Stop codes:** `VGNKennung` (e.g. `704`).

How GTFS names the same stops [V]:
- stop_ids are DHIDs, e.g. `de:09564:704:2:3`. The **3rd field is the VGNKennung.**
- 1,479 of 12,010 DHID numbers occur in two districts (e.g. `20210` in districts 09461 and 08127). This is harmless for a whole ordered sequence, and those districts are mostly outside PULS. A rare collision would only map two identical-looking sequences to one file.

### Key, and what was rejected

**Key (both providers):** `h = sha1(codes.joined(",")).hex.prefix(16)` over the collapsed stop codes.
- The phone already has these codes in `RoutePattern.stops`.
- One file per unique key. When several platform-level GTFS sequences map to one key (Zürich 72 had 3), keep the one with the most trips.

**Rejected as the primary key:** `route_short_name + first/last stop + count`. It depends on line-name normalisation, and the hash already matched 8 of 8. The fallback index below still uses line + last stop.

**Fallback for a miss:** for example, when the Swiss adapter could only build the onward stops, or a live diversion changed the stop list.
- `l/<line>/<lastCode>.json` lists the variants of that line ending at that stop: `{h, stops, trips}`.
- The phone picks the variant that contains its stop list as a contiguous run, fetches that `s/` file, and trims the shape with `at`.

### Live verification of the key [V]

Requests used: 22 to transport.opendata.ch and about 27 to start.vag.de. All requests were ≥1.2 s apart, with the User-Agent from the brief.

| Live pattern (fetched exactly as the adapter does) | Stops | Exact hash hit | GTFS trips/yr with that sequence |
|---|---|---|---|
| ch 72 → Zürich, Milchbuck (from Bucheggplatz) | 23 | yes (3 platform variants) | 1,271 |
| ch 12 → Bern, Zentrum Paul Klee (from Zytglogge) | 17 | yes | 651 |
| ch 30 → Basel, Badischer Bahnhof (from Spalentor) | 14 | yes | 1,854 |
| ch 3 → Breganzona, Posta (from Lugano, Centro) | 24 | yes | 1,465 |
| ch 2 → Maladière-Lac (Lausanne, Bel-Air) | 25 | yes | 2,088 |
| VAG Bus 36 Richtung2 → Plärrer (morning short working from Meistersingerhalle) | 19 | yes. The variant runs 1 trip/yr per route version, and the live trip was exactly it. | 1 |
| VAG Bus 34 Richtung1 → Frd.-Ebert-Platz | 9 | yes | 191 |
| VAG Bus 30 → Erlangen (regional, 37 stops) | 37 | yes, **only after collapsing** GTFS's `3151,3151` | 52 |

Other API observations:
- `start.vag.de` was flaky: two calls timed out at 30 s and 90 s, and other calls took 1–10 s.
- The Swiss boards took 1–8 s. [V]

## 3. Recipe, and the tests that were run

```
# 1. patterns: stream GTFS zip -> bus(+tram) trips -> unique stop sequences, + reduced GTFS (1 trip per sequence)
python -I gtfs_patterns.py FEED.zip OUT --norm ch|vgn --types bus,tram
# 2. pfaedle input: bus only, dedup by phone key (keep max trips), optional bbox; parent_station is stripped
python -I subset.py OUT/patterns.json OUT/gtfs SUB [--bbox ...]
# 3. map-match (cfg = stock pfaedle.cfg + override section below)
pfaedle -c a.cfg -D -m bus -x region.osm.pbf -o PF SUB       # trams: -m tram with the stock cfg
# 4. package + score every shape (shapecheck vs GTFS platform coords), write s/ and l/ files
python -I package.py SUB/sel.json PF SITE --region ch --feed <feed_version> --tools <dir with shapecheck.py>
```

Config override, appended to `pfaedle.cfg` (file `offline_work/cfg/a.cfg`):
```
[bus, coach]
routing_station_move_penalty_fac: 0.02
```

The stock penalty (0.0039) lets pfaedle "move" a stop up to `osm_max_station_cand_distance` (200 m) away. That lets it skip short village or forecourt detours. The table shows the effect.

### Test runs

| Run | Patterns | pfaedle time / peak RAM | Strict PASS | max-offset p95 | Length ratio median / p99 | U-turn spikes |
|---|---|---|---|---|---|---|
| Nürnberg core, stock | 704 | 7.6 s / 0.25 GB | 96.2% | 43 m | 1.12 / 1.5 | – |
| Nürnberg core, 0.05 | 704 | ~8 s | 99.4% | 21 m | 1.13 / 1.6 | – |
| Mittelfranken VGN, stock | 5,731 | 14.1 s / 0.53 GB | 77.4% | 126 m | 1.17 / 1.65 | 9.7% of shapes |
| Mittelfranken VGN, **0.02** | 5,731 | 9.4 s | **90.3%** | 64 m | 1.17 / 1.67 | 10.8% |
| Mittelfranken VGN, 0.05 / 0.1 | 5,731 | 10–12 s | 91.7% / 91.9% | 59 / 57 m | 1.18 / 1.7 | 11.2% / 11.5% |
| Zürich, stock | 550 | 22.6 s / 0.33 GB (mostly reading the 549 MB pbf) | 88.4% | 65 m | 1.12 / 1.73 | 0.2% |
| Zürich, **0.02** | 550 | ~23 s | **96.4%** | – | – | – |
| Zürich, 0.05 | 550 | 22.8 s / 0.35 GB | 96.4% | 30 m | 1.17 / 1.98 | 0.9% |
| **All Switzerland buses, 0.02** | **26,132** | **115 s / 2.0 GB** (103 s / 2.36 GB peak with 0.05) | **93.4%** | 39.5 m (median 7.8) | 1.12 / 1.96 | 5.8% |
| Swiss trams, stock, `-m tram` | 1,423 | 14 s | 96.9% | 39 m | 1.05 | – |
| VAG trams, stock | 57 | <5 s | 94.7% | 55 m | 1.06 | – |

**Extrapolation:** none is needed. The whole region was run.
- Switzerland end to end: extract 96 s, pfaedle about 2 min, package and score 56 s. That is about 4 min plus downloads.
- The whole of VGN would be about 12.5k patterns on a Bayern extract. Estimate: under 1 min of pfaedle and 1.5–3 GB, dominated by reading the pbf. [U]

### Checks without ground truth

**A. Agreement with OSM `route=bus` relations** (`osm_compare.py`). This is the share of the pfaedle line lying within 20 m of the best-matching relation's ways, and the reverse.
- **Nürnberg, stock config:**
  - 36 → Doku-Zentrum 100% / 100%
  - 65 both directions 100% / 100%
  - 34 → Plärrer 100% / 100%
  - 30 → Nordostbahnhof 98.9% / 98.1%
  - 43 → Passauer Str. 100% (OSM maps only one direction)
  - Aggregate over 219 patterns: median 100% for both the stock config and 0.05.
- **Zürich, stock config:**
  - 80 100% / 98.8%
  - 72 → Milchbuck 99.4% / 100%
  - 32 100% / 100%
  - 69 100% / 96.6–100%
  - 31 99.6–99.9%
  - 33 99.3–100%
  - 72 → Morgental 95.9% / 94.6%
- **Zürich aggregate over 269 patterns (median pfaedle-on-OSM):** stock 98.9%, 0.02 97.7%, 0.05 96.3%.
- **Trade-off:** a higher stop penalty raises strict PASS but can add loops around blocks. 72 → Morgental drops to 79% with 0.05: it adds 2.2 km of loops, length ratio 1.42, yet still passes shapecheck. That is why **0.02**, not 0.05, is recommended. It gets the same Zürich PASS rate as 0.05 and a smaller loss of OSM agreement.

**B. Failure diagnosis** (`diag_fails.py`). This compares the worst stop with the nearest drivable OSM road.
- **VGN, stock config:** 1,155 of 1,231 failures were stops that lie on a road while the shape runs along a parallel or main road (a skipped village detour). 75 were stop coordinates more than 40 m from any road. With 0.05, 284 + 80 remain.
- **Switzerland, 0.02, 1,720 failures:**
  - 675 fail on length ratio alone (offset ≤50 m, median chord 4.9 km). A sample showed real alpine switchbacks (Verbier, Feldis, Bürchen, Guarda, Lenzerheide) and EV rail-replacement buses with 2–4 stops. These are false alarms of shapecheck's 1.5× rule.
  - 709 have offsets of 50–100 m, and 336 have offsets of 100 m or more.
  - Of the failures checked, 435 are station-centroid stop coordinates off the road and 610 are skipped detours.
  - Cross-border stops (Vétraz-Monthoux in France, Waldshut in Germany) fall outside the Swiss extract. Use an extract with a border buffer, or add neighbouring countries' extracts.
- **Spikes:** 5.8% (Switzerland) and about 10% (rural VGN) of shapes contain at least one U-turn of 30 m or more. Many are real dead-end runs (Stichfahrten) into villages and turning loops.

**C. Phone-side simulation** (`live_check.py`). This computes the key from the live pattern, opens the built file and runs shapecheck.

| Live pattern | Against the file's `sp` (GTFS platform) coords | Against the API's stop coords |
|---|---|---|
| ch 72 | PASS, max 20.1 m | PASS, max 20.1 m |
| ch 12 | PASS, max 7.9 m | FAIL, 123 m (Hirschengraben centroid) |
| ch 30 | PASS, max 11.5 m | FAIL, 148 m (Basel Universität) |
| ch 3 | PASS, max 8.6 m | PASS, max 49.6 m |
| ch 2 | PASS, max 11.7 m | FAIL, 57 m |
| VAG 36 | PASS, max 23.7 m | PASS, max 13 m |
| VAG 34 | PASS, max 10.9 m | PASS, max 17 m |
| VAG 30 | PASS, max 13.8 m | FAIL, 163 m (Erlangen Neuer Markt: the API point is 247 m from the platform) |

So the modal should draw stop markers from `sp`, and use the API's points only as a fallback.

## 4. Output format, hosting and the weekly job

### File format

One file per unique key: `/<v1>/<provider>/s/<h[0:2]>/<h>.json`. Sample (VAG 34, 334 B raw / 290 B gzip):
```json
{"v":1,"feed":"20260624","line":"34","stops":["704","754",…,"232"],
 "poly":"o{xlHcbpbA_@KIBMF…",          // Google encoded polyline, precision 5, lat/lon order
 "sp":"_|xlHacpbAgJlh@…",              // platform coordinates of the stops, same encoding (draw markers from this)
 "at":[1,23,27,38,44,51,59,61,64]}      // shape vertex index nearest each stop (monotone) -> trim to a sub-range
```

Fallback index: `/<v1>/<provider>/l/<line>/<lastCode>.json` = `{"v":1,"feed":…,"variants":[{"h":…,"stops":[…],"trips":N}]}`.

### Measured totals (tuned config)

| | Shape files | Raw / gzip | Avg raw / gzip | Index files (raw) |
|---|---|---|---|---|
| Switzerland, buses | 26,132 | 27.8 MB / 19.7 MB | 1,063 / 753 B | 11,902 (5.5 MB) |
| VGN in Mittelfranken | 5,731 | 9.0 MB / 6.4 MB | 1,562 / 1,115 B | 2,226 (1.0 MB) |
| Whole VGN, estimated | ~12.5k | ~20 MB [U] | – | ~2.3 MB [U] |
| Trams, estimated | +1.5k | +~1.5 MB [U] | – | – |

All in, the site is under 60 MB and roughly 60k small files.

### Phone flow

1. Build `h` with CryptoKit `Insecure.SHA1`.
2. `GET {base}/v1/ch/s/ab/abcdef0123456789.json`. This is one request per cold line, and it hit 8 of 8 in the live test.
3. Cache it on disk under `(provider, h)` forever, and revalidate at most weekly with `If-None-Match`. Firebase sends ETags, so the revalidation is a 304.
4. On a 404, `GET l/<line>/<last>.json`, pick the variant that contains the rider's stops contiguously, `GET` its `s/` file, and trim with `at`. That is 3 requests in the worst case.
5. If that also fails, fall back to drawing straight stop-to-stop lines. The brief does not allow those as the "real shape", so better to show no route line at all.

### Hosting recommendation: Firebase Hosting

Use a second Hosting site (multi-site) in the existing `busbus-ios` project, e.g. `busbus-shapes.web.app`.
- Global CDN with automatic gzip/brotli.
- `Cache-Control` set in `firebase.json`: `s/**` and `l/**` get `public, max-age=86400, s-maxage=604800`.
- A deploy uploads only files whose content hash changed, so a weekly re-match that changes 2% of shapes uploads about 2%.
- No new vendor, and the same Google account as the existing Firebase functions.
- Free Spark quota: 10 GB storage and 360 MB/day transfer, about 450k cold-line fetches a day at about 0.8 KB each. Blaze is pay-as-you-go beyond that. [U: current Firebase pricing; check before launch]
- Set version retention to a few versions so the stored history stays small.

Alternatives considered:
- **GitHub Pages:** 1 GB site limit, soft 100 GB/month, and a public repo is required. Fine technically. But Pages' terms discourage using it as a backend for a commercial app, and the URL would tie into a GitHub account. [U]
- **Cloud Storage public bucket:** works, but it has no CDN without a load balancer and Cloud CDN (about $18/mo minimum), and it pays egress. It brings no benefit at this size.

### Weekly GitHub Actions job

Suggested as `.github/workflows/shapes.yml`, cron weekly, Monday 03:00 UTC.

1. **Restore the pfaedle binary from the actions cache** (key = pfaedle commit). A cold build is a cmake build of about 5 min. [U]
2. **Switzerland:**
   - `curl -L` the permalink, about 290 MB, about 1 min.
   - Skip the region when `feed_info.feed_version` is unchanged and the last OSM run is younger than 4 weeks.
   - Geofabrik `switzerland-latest.osm.pbf`, 549 MB.
   - `gtfs_patterns.py` (96 s, 1.5 GB) → `subset.py` → `pfaedle` (about 2 min, 2.4 GB peak) → `package.py` (about 1 min).
3. **VGN:**
   - `GTFS.zip`, 15 MB. Skip if its Last-Modified is unchanged and OSM is younger than 4 weeks.
   - Geofabrik `bayern-latest.osm.pbf` [U on size], then the same steps (estimated under 3 min).
4. **Gates and deploy:**
   - Deploy only if the PASS rate is no more than 2 points below last week's, and the file count is within ±10%.
   - Then `firebase deploy --config build/shapes/firebase.json --only hosting` (as built, see `.github/workflows/shapes.yml`), authenticated with a service account (a GitHub secret or Workload Identity Federation).
   - Write `fails.json` and a summary as a workflow artifact.
5. **Resources:**
   - Runtime about 10–15 min.
   - Peak RAM about 2.5 GB. That fits both the 16 GB public-repo runner and the 7 GB private-repo runner. [U on the private runner spec]
   - Disk under 3 GB: zips are streamed and never unzipped.
   - Be polite to Geofabrik: one download per region per week.

### Licence and attribution

- **OSM:** the shape geometry is derived from OpenStreetMap, so the hosted shape files are a Derivative Database under **ODbL 1.0**.
  - Publish `/v1/LICENSE.txt` at the site root, stating ODbL and "© OpenStreetMap contributors".
  - Show "Route © OpenStreetMap contributors" in the line-map modal. The app's map is a Produced Work, so it needs the attribution notice.
  - pfaedle writes the same notice into `attributions.txt`.
  - Share-alike is satisfied because the files are public.
- **Switzerland:** "Timetable data: opentransportdata.swiss" in the modal and in the LICENSE. The weekly refresh meets the "update as often as the raw data" rule.
- **VGN:** "Fahrplandaten: VGN – Verkehrsverbund Großraum Nürnberg GmbH, CC BY 3.0 DE". This sits alongside the existing VAG CC BY 4.0 API credit.

## 5. Design for the GTFS-only providers

For wienerlinien, iett, stib, mobiliteit-lu, adelaide-metro and metrotransit, the agency GTFS already has `shapes.txt` (per `docs/research/route-shapes.md` §2; [U] here).

- Same steps 1, 2 and 4.
- **No pfaedle.** `package.py` reads `trips.shape_id` and `shapes.txt` straight from the agency feed. Optionally trim to the first and last stop using `shape_dist_traveled`.
- Then the same key, file format and hosting under `/v1/<provider>/`.

Each provider needs its own normaliser from the adapter's stop code to the GTFS stop_id, and each must be verified live like the two above. Examples of what has to be mapped:

| Provider | App stop code | Needs mapping to | Status |
|---|---|---|---|
| wienerlinien | RBL number | GTFS `at:49:…` ids (probably via the OGD haltepunkte CSV) | [U] |
| stib | Point id | GTFS stop_id with a letter suffix | [U] |
| iett | DURAKKODU | GTFS stop_id | [U] |
| metrotransit | site id | GTFS stop_id, likely the same | [U] |
| adelaide-metro | stop code | GTFS stop_code or stop_id | [U] |
| mobiliteit-lu (Hafas) | HAFAS extId | GTFS id | [U] |

Use pfaedle as the fallback only for trips whose shape is missing. These providers have far fewer patterns than Switzerland, so the job adds minutes, not hours.

## 6. Risks

- **The VGN feed goes stale.** It is quarterly, and the current file ends on 2026-12-12. Around a timetable change, live trips stop matching. Those requests fall to the fallback index or to no shape, so the app has to cope with "no shape". Keep the previous site's files deployed until the new feed appears.
- **The VGN area is wider than Mittelfranken.** Use a Bayern extract, or merge the regional extracts. Patterns outside the extract come out sparse or off.
- **Swiss onward-only patterns.** When no opposite trip is found, the exact hash misses. The fallback index handles it with 2 extra requests. Not seen in the 5 Swiss live samples.
- **Live diversions or Ersatzverkehr** change the stop list, so the hash misses and the fallback index or no shape takes over.
- **Shape quality.** Rural village detours and station-forecourt detours are sometimes skipped (VGN rural 90%). The tuned penalty can add block loops; keep 0.02 and watch the OSM-agreement metric in CI. shapecheck's ratio rule flags real alpine routes, so gate on offset, not on ratio, in mountainous regions.
- **The API's stop coordinates are centroids.** Draw stops from `sp`. Otherwise markers sit off the line by up to 250 m.
- **Cross-border Swiss lines** need neighbouring OSM data.
- **Operational.** Geofabrik speed varies. Firebase multi-site deploys of about 60k files: the first deploy is slow, later ones are incremental. ODbL notices are required in the app and in the files.

## Summary table

| provider | extra calls per cold line | piggyback? | format | verified lines PASS/FAIL | max offset | size | latency | cache key | notes |
|---|---|---|---|---|---|---|---|---|---|
| ch-opendata | 1 (exact hash file); 3 on a miss (index → file) | no. The API has no geometry. The file comes from our CDN. | JSON: encoded polyline p5 (lat,lon) + `sp` platform stops + `at` indices | 5/5 PASS against file `sp` (72, 12, 30 Basel, 3 Lugano, 2 Lausanne); 2/5 pass against API centroids. Region: 93.4% strict / 96.0% ignoring ratio-only, over 26,132 patterns | 20.1 m (live); region p95 39.5 m | avg 1.06 KB raw / 0.75 KB gzip; whole region 27.8 MB + 5.5 MB index | CDN, one small GET (not measured on Firebase) | sha1 of collapsed DIDOK sequence (16 hex); revalidate weekly with ETag | GTFS has no shapes.txt; `didok` column maps SLOID→code; pfaedle 115 s / 2.0 GB for all of Switzerland; key 5/5 exact |
| vag-nuernberg | 1; 3 on a miss | no (same) | same | 3/3 PASS against file `sp` (36 short working, 34, 30 Erlangen); 2/3 against API coords. Nürnberg core 99.4% (0.05), Mittelfranken 90.3% (0.02) | 23.7 m (live); region p95 64 m | avg 1.56 KB raw / 1.1 KB gzip; Mittelfranken 9.0 MB + 1.0 MB index; whole VGN ~20 MB [U] | same | sha1 of collapsed VGNKennung sequence (DHID 3rd field) | GTFS has no shapes.txt, quarterly, ends 2026-12-12; collapse duplicate consecutive stops (`3151,3151`); production needs a Bayern OSM extract |

**Blockers.** None technical.
- **To decide:** the Firebase multi-site name and deploy credentials, which need the user's consent.
- **VGN timetable change:** on 2026-12-13 VGN may publish its next feed late.
- **Per-provider id normalisers** for the GTFS-only providers are still unverified.
