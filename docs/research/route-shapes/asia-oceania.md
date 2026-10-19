# Route shapes — group "asia-oceania" (verified 2026-10-19)

Providers: hk-kmb, hk-citybus, hk-gmb, hk-nlb, hk-mtrbus, odpt-toei, adelaide-metro.
[V] = verified live 2026-10-19; [U] = unverified. All providers in this group are keyless, so **no
proxy (functions/src/agencies.ts) changes are needed for any of them.**

Scripts: `scratchpad/regions/asia-scripts/` (hkmatch.py = HK candidate picker, trim.py, perstop.py,
toeisweep.py, adl.py, adlsize.py). Downloads: `scratchpad/regions/dl/{hk,hk-kmb,hk-citybus,hk-gmb,hk-nlb,hk-mtrbus,odpt-toei,adelaide-metro,hkbus-db}`.

---

## Hong Kong: the shared source (KMB, Citybus, NLB, MTR Bus partly; GMB has its own layer)

**Layers (Transport Department, served by the CSDI portal's ArcGIS server)** [V]
- Franchised bus: `https://portal.csdi.gov.hk/server/rest/services/common/td_rcd_1638844988873_41214/MapServer/0`
  (layer `FB_ROUTE_LINE`, "Bus routes of franchised buses"). Fields: `ROUTE_ID` (TD route id, one per
  variant), `ROUTE_SEQ` (1/2), `COMPANY_CODE` (`KMB`, `LWB`, `CTB`, `NLB`, `KMB+CTB`, `LWB+CTB`),
  `ROUTE_NAMEE` (route number), `ST_/ED_STOP_ID` (TD stop ids, *not* operator ids), `ST_/ED_STOP_NAMEE/C/S`,
  `Shape_Length`. 2,246 features, 1,538 ROUTE_IDs. ISO metadata: maintenance "monthly", last revision 2026-09-25.
- GMB: `.../td_rcd_1697082463580_57453/MapServer/0` (layer `GMB_ROUTE_LINE`, the one `GMBProvider`
  already queries for termini). Same fields, `ROUTE_NAME` instead of `ROUTE_NAMEE`; here `ROUTE_ID` **is**
  the GMB API `route_id`, `ROUTE_SEQ` **is** `route_seq`, and `ST_/ED_STOP_ID` **are** GMB API stop ids
  (20000080 etc.) [V].
- Native SR is HK1980 Grid (wkid 2326); `outSR=4326` returns WGS84 [V]. `maxRecordCount` 3000; formats
  JSON / geoJSON / PBF.
- Other official datasets checked: `static.data.gov.hk/td/routes-fares-geojson/JSON_BUS.json` is 78 MB of
  **Point** features (one per route-stop: `routeId`, `routeSeq`, `stopSeq`, `stopId`, coordinates) — no
  line geometry [V]. The CSDI full GeoJSON download of the bus layer is 1.5 GB [V]. TD's GTFS
  (`static.data.gov.hk/td/pt-headway-en/gtfs.zip`, 13.7 MB) has **no shapes.txt** [V]. So the per-route
  query on the CSDI layer is the only practical live source.

**Geometry quality** [V]: not simplified — dense (KMB 1A outbound: 725 vertices over 14.9 km, ~20 m spacing;
Citybus 11 loop: 3,217 vertices). Bus-layer features are `MultiLineString`s with one piece per stop-to-stop
link (17–47 pieces), **already in travel order with 0 m gaps** on every feature tested — just concatenate,
dropping the duplicated joint vertex. GMB features are single `LineString`s. Stop offsets of 7–40 m are the
kerb-vs-centreline distance, not errors.

**Server-side reduction** [V]: `geometryPrecision=5` + `maxAllowableOffset=0.00003` (degrees ≈ 3 m, with
`outSR=4326`) cut NLB 3M (6 features) from 34.1 KB gz / 167 KB raw to **3.6 KB gz / 34.6 KB raw**, and
KMB 8A from 514 to 145 vertices (1.17 KB gz), with stop offsets unchanged (8A 30.0 → 30.0 m, 3M 22.3 → 23.1 m).
Simplification is per piece, so piece joints survive. Recommended for every HK query.

**The query** (one call per route number, returns every variant and direction of it):
```
GET https://portal.csdi.gov.hk/server/rest/services/common/td_rcd_1638844988873_41214/MapServer/0/query
    ?where=ROUTE_NAMEE='{route}' AND {company filter}
    &outFields=ROUTE_ID,ROUTE_SEQ,COMPANY_CODE
    &returnGeometry=true&outSR=4326&geometryPrecision=5&maxAllowableOffset=0.00003&f=geojson
```
Company filters [V]: KMB/LWB `COMPANY_CODE <> 'CTB' AND COMPANY_CODE <> 'NLB'` (returns KMB, LWB, KMB+CTB,
LWB+CTB); Citybus `COMPANY_CODE LIKE '%CTB%'`; NLB `COMPANY_CODE = 'NLB'`. Without a filter shared numbers
hurt: route "11" returned 23 features from KMB, CTB and NLB, 521 KB.

**WAF gotcha** [V]: the CSDI front door answers HTTP 403 "The request is blocked." to a `where` containing
`IN ('1A','1',…)` (a SQL-injection rule). `=`, `AND`, `LIKE '%…%'`, `NOT LIKE`, `<>` all pass.

**Id mapping: there is none to compute** [V]. The operator APIs never expose TD's ROUTE_ID, and ROUTE_SEQ is
not a reliable direction: KMB 11 service_type 2 inbound is ROUTE_ID 1000707 **seq 1**; NLB 3M Tung Chung →
Mui Wo is seq **2**; KMB 1A outbound is seq 1. (The hkbus.app crawler's `gtfsId` for KMB 1A/8A/11 equals the
ROUTE_IDs I matched — 1053, 1390, 1000706, 1016, 1000707 — so the mapping is right; they get it by stop
matching too.) **Pick by fit:** for each returned feature, stitch it, project the pattern's stops in order
(the `RouteGeometry`/shapecheck test) and keep the feature with every stop within 50 m and the lowest max
offset. Then trim it to the stretch between the first and the last stop (needed for Citybus loop halves).
This runs on data already in hand (the stop coordinates from `routePattern`).

**Latency / reliability** [V]: 1.8–7.6 s per query (median ≈ 4.5 s); 3 of ~30 CSDI requests timed out or
reset (curl 000) and succeeded on retry. ETag changes on every response (load-balanced), and
`Cache-Control: no-cache` → no conditional GET. Retry once after a few seconds. No documented rate limit [U].

**Licence** [V via search of the portal's T&C page]: CSDI Portal Terms and Conditions of Use
(https://portal.csdi.gov.hk/csdi-webpage/doc/TNC): free browse/download/distribute/reproduce for commercial
or non-commercial use, on condition that you "identify clearly the Government and the CSDI Portal as the
source of the Data" and acknowledge IP ownership; indemnity clause. Drawing it is allowed. Suggested credit
line for the map modal: "Route lines: Transport Department, HKSAR Government / CSDI Portal". (Exact wording
of the T&C beyond those clauses [U].)

**Cache key / change detection (all HK)**: cache by the adapter's line id plus the operator's stop-id list
hash: `{provider}|{line.id}|{sha1(stop ids)}` → stored `{ROUTE_ID, ROUTE_SEQ, polyline}`. No cheap change
signal (no lastEditDate in layer JSON, no stable ETag). The layer is maintained monthly → **TTL 30 days**, and
re-fetch immediately when the stop list from `routePattern` changes. One query also yields all directions/
variants of the route number, so cache them all from one response.

---

## hk-kmb

1. **Today** [V]: `routePattern` = `GET data.etabus.gov.hk/v1/transport/kmb/route-stop/{route}/{outbound|inbound}/{service_type}`
   + the session `/stop` dump (6.7k stops, 325 KB gz) for coordinates. `lines(atStop:)` from the `/route-stop` +
   `/route` dumps (fallback `/stop-eta/{stop}`). `TransitLine.id` = `"route|bound|service_type"`,
   `providerRefs` route/bound/serviceType. No TD id anywhere.
2. **Recipe: 1 extra call per route number** (covers both directions and every service type): the HK query
   above with `where=ROUTE_NAMEE='{route}' AND COMPANY_CODE <> 'CTB' AND COMPANY_CODE <> 'NLB'`, pick by fit,
   trim. No piggyback possible (different host).
3. **Format**: GeoJSON MultiLineString, `[lon, lat]`, pieces in order (concatenate). Several variants per
   route (11: ROUTE_IDs 1000706 seq 1/2, 1016, 1000707) — choose by fit, never by seq.
4. **Live** [V]:

   | line | stops | chosen feature | max / median offset | ratio | verdict |
   |---|---|---|---|---|---|
   | 1A outbound st1 (fixture, Sau Mau Ping → Star Ferry) | 35 | 1053 seq 1 | 23.4 / 9.0 m | 1.14 | PASS |
   | 8A outbound st1 (Whampoa, **circular**) | 19 | 1390 seq 1 | 30.0 / 7.7 m | 1.31 | PASS |
   | 11 outbound st2 (special variant from Diamond Hill) | 18 | 1016 seq 1 | 27.3 / 9.0 m | 1.40 | PASS |
   | 11 outbound st1 | 26 | 1000706 seq 1 | 27.3 / 7.8 m | 1.29 | PASS |

   The wrong candidates fail clearly (e.g. 1000706 seq 2 for 11 O: every stop far), so the fit picks
   unambiguously. Size: 1A both directions full precision 20.9 KB gz / 56.7 KB raw; with the recommended
   precision/offset ≈ 1–4 KB gz. Latency: 2.9–5.5 s (CSDI); the KMB route-stop calls 1.5–5.7 s, one timed out
   at 18 s and passed on retry.
5. Cache: see HK common. 6. Licence: see HK common (KMB data itself: data.gov.hk T&C). 7. Proxy: none.

## hk-citybus

1. **Today** [V]: `routePattern` = `GET rt.data.gov.hk/v2/transport/citybus/route-stop/ctb/{route}/{outbound|inbound}`
   + one `/stop/{id}` per stop. `TransitLine.id` = `"route|O"` / `"route|I"`; no service types exist in the API.
2. **Recipe: 1 extra call per route number**: HK query with `COMPANY_CODE LIKE '%CTB%'`, pick by fit,
   **trim to first..last stop** (essential here).
3. **Citybus specifics** [V]:
   - The Citybus API's stop list for a direction is the **union of TD's variants**: 1 outbound has 20 stops,
     TD variant 1480 has 18 (via Chater Road), 1000326 has 19 (via Des Voeux Road Central); stop 5 (Chater
     Garden) is only on 1000326 and stop 6 (Statue Square) only on 1480. No single shape can pass.
   - A Citybus "circular" route is split in the API into outbound and inbound halves, while TD has one
     loop feature (11: ROUTE_ID 1495 / 1000276, Central → Jardine's Lookout → Central). Trimming the loop to
     the first and last stop gives the half.
   - **Fix**: after choosing the best-fitting feature, ignore at most 1–2 stops that are > 50 m from it
     (still draw them as markers); fail only if more stops miss.
4. **Live** [V] (stop coordinates from hkbus.app's crawled DB, which uses Citybus' own `/stop` values —
   spot-checked 001044 and 002528 against the API, identical to 1e-5°, to stay under the request budget):

   | line | stops | chosen | max / median | ratio | verdict |
   |---|---|---|---|---|---|
   | 11 outbound (loop half), trimmed | 31 | 1495 seq 1 | 8.8 / 3.4 m | 1.22 | PASS |
   | 1 outbound (fixture direction) raw | 20 | 1480 seq 1 | 125.6 m (stops 5, 6) | 1.07 | FAIL — union of 2 variants |
   | 1 outbound, alternate-variant stop dropped | 19 | 1000326 seq 1 | 7.3 / 1.6 m | 1.12 | PASS |
   | 11 inbound raw, trimmed | 31 | 1495 seq 1 | 130.9 m (stop 28) | 1.08 | FAIL — stop 28 "Alexandra House, Ice House Street" lies only on the loop's outbound side; TD has no inbound variant via Ice House St |
   | 11 inbound, stop 28 dropped | 30 | 1495 | 42.7 / 4.8 m | 1.11 | PASS |

   Size: CTB 1 (3 features, precision 6, unsimplified) 11.2 KB gz / 65 KB raw; CTB 11 (5 dense loop
   features) 54.7 KB gz / 319 KB raw → use the simplification params. Latency 4.6–5.8 s.
5–7. As HK common; proxy none.

## hk-gmb

1. **Today** [V]: `routePattern` = `GET data.etagmb.gov.hk/route-stop/{route_id}/{route_seq}` + one `/stop/{id}`
   per stop. `TransitLine.id` = LineRef(routeID, seq) id; `providerRefs` region/route/routeID/routeSeq. The adapter
   already calls the GMB CSDI layer (`termini()`, `returnGeometry=false`, all routes, once per session).
2. **Recipe: 1 extra call, direct id match** (no fitting needed):
   ```
   GET https://portal.csdi.gov.hk/server/rest/services/common/td_rcd_1697082463580_57453/MapServer/0/query
       ?where=ROUTE_ID={route_id} AND ROUTE_SEQ={route_seq}&outFields=ROUTE_ID,ROUTE_SEQ
       &returnGeometry=true&outSR=4326&geometryPrecision=5&maxAllowableOffset=0.00003&f=geojson
   ```
   Piggybacking on `termini()` is not worth it (geometry for all 1,162 directions would be MBs).
3. **Format**: one GeoJSON `LineString`, `[lon, lat]`, already in travel order.
4. **Live** [V]: HKI 12 (route_id 2002285 seq 1, **circular**, 21 stops) **PASS** 9.1 / 5.8 m, ratio 1.38,
   2.3 KB gz / 9.4 KB raw (full precision 6), 4.5 s. HKI 1 (2006408 seq 1, The Peak → Central, 6 stops):
   every stop within 15.2 m (median 7.5) but **FAIL on length ratio 2.34** — 6 stops over a winding 8.2 km
   mountain road vs 3.5 km of chords. Not a data error: the 1.5× length rule rejects sparse stops on winding
   roads; suggest applying the ratio test only when the offsets fail, or scaling it per chord (e.g. allow
   3× for chords > 1 km). 9.3 KB gz / 41.6 KB raw (both seqs), 4.8 s (first attempt timed out). The GMB
   ETA API itself took 21–24 s for `/route/HKI/{code}` today.
5. Cache key `hk-gmb|{route_id}|{route_seq}`; TTL 30 days, re-fetch when stops change. 6–7 as HK common.

## hk-nlb

1. **Today** [V]: whole network once per session: `route.php?action=list` + `stop.php?action=list&routeId=` per
   route (stops with coordinates, in order). `TransitLine.id` = NLB `routeId` (one direction of one variant);
   `providerRefs` route (number).
2. **Recipe: 1 extra call per route number**: HK query with `COMPANY_CODE = 'NLB'`, pick by fit, trim.
3. Format as KMB. NLB route ids ≠ TD ROUTE_IDs; seq is not direction (3M Tung Chung → Mui Wo is 8571 seq **2**).
4. **Live** [V]:
   - 3M Tung Chung → Mui Wo (routeId 6, 34 stops): 8571 seq 2 **PASS** 22.3 / 13.9 m, ratio 1.24
     (simplified query: 23.1 m, 325 vertices). 3.6 KB gz / 34.6 KB raw simplified (34.1 KB gz full). 4.0–6.3 s.
   - 38 Yat Tung Estate **circular** (routeId 30, 9 stops): 1731 seq 1 **PASS** 21.1 / 13.9 m, ratio 1.62
     (within the +500 m allowance). 1.7 KB gz / 6.7 KB raw, 3.9 s.
5–7. As HK common.

## hk-mtrbus

1. **Today** [V]: static CSVs `opendata.mtr.com.hk/data/mtr_bus_stops.csv` (stops per route/direction with
   coordinates) and `mtr_bus_routes.csv`; `TransitLine.id` = `"{REFERENCE_ID}:{DIRECTION}"`, providerRefs
   routeName/lineRef.
2. **Live shape: only 4 of 26 routes.** The CSDI bus layer contains K12, K14, K17, K18 (the Tai Po feeders),
   **coded `COMPANY_CODE='KMB'`** (KMB's own API has no such routes) [V]. For those: 1 call,
   `where=ROUTE_NAMEE='K12'` (no company filter), pick by fit. K12 O (3 stops) → 1424 seq 2 **PASS** 39.2 m;
   K12 I (4 stops) → 1424 seq 1 **PASS** 35.5 m; 6.6 KB raw. The other 22 (506, K51…K76S, Tuen Mun / Yuen
   Long) have no geometry anywhere official.
8. **Offline for the rest**: TD GTFS `https://static.data.gov.hk/td/pt-headway-en/gtfs.zip` (13.7 MB,
   Last-Modified 2026-10-14) has agency `LRTFeeder` = MTR Bus with 32 routes (e.g. `1862,LRTFeeder,506,…`),
   stops and stop_times, **no shapes.txt** → pfaedle. Map TD → adapter by `route_short_name` = `ROUTE_ID`
   column of the MTR CSV, plus direction by matching the ordered stop coordinates (TD stop ids differ from
   MTR's `K12-U010`). Or key the hosted files by the hash of the MTR stop-id sequence, as the main plan says.
   Licence of the TD GTFS: data.gov.hk T&C (attribution to the Government / TD / DATA.GOV.HK).

---

## odpt-toei

1. **Today** [V]: `routePattern` → `patterns([line.id])` = `GET https://api-public.odpt.org/api/v4/odpt:BusroutePattern?owl:sameAs={ids, ≤10}`
   (session-cached), then `odpt:BusstopPole?owl:sameAs=` for coordinates. `lines(atStop:)` loads every pattern
   listed on the pole the same way. `TransitLine.id` = the representative pattern's `owl:sameAs`
   (e.g. `odpt.BusroutePattern:Toei.To07.60101.1`); `providerRefs["patterns"]` lists the folded variants.
2. **Recipe: 0 extra calls** [V]. `ug:region` is in the very `odpt:BusroutePattern` reply the adapter already
   decodes; add `ug:region` to `DTO.Pattern` (CodingKey `"ug:region"`, `{type:"LineString", coordinates:[[lon,lat],…]}`).
   Use the shape of `line.id` (the representative pattern), which is the pattern `routePattern` draws.
3. **Format**: GeoJSON LineString, `[lon, lat]`, 6 decimals. Sparse: a vertex per bend only (median 48
   vertices per pattern, To07 60101.1 = 47 vertices for 7.0 km) but road-following — offsets stay ~10–15 m.
   **Some patterns' geometry is reversed** (5 of 748 found): if the in-order check fails, retry with the
   coordinates reversed. 9 of 757 patterns have no `ug:region` (Tan96.1716.*, Shina98.4107.*,
   Shibu88.8208.*, KM01.72815.1, T05-2Shutsunyuu.72416.*).
4. **Live** [V]:
   - To07 60101.1 (fixture, Kinshichō → Monzen-Nakachō, 21 poles): **PASS** 14.3 / 8.3 m, ratio 1.03.
   - To07 60101.2: PASS 14.8 m. Shina91 1009.3 (**loop**, 品川駅港南口, 30 poles): **PASS** 10.6 / 6.2 m.
     I92 1101.3 (loop, 19 poles): PASS 12.9 m.
   - **Whole-network sweep** (all 757 Toei patterns, 1 request + the 3,690-pole list, 1 request):
     **704 / 748 PASS (94%)**, max offset p50 13.5 m, p90 33.3 m, p99 110.7 m. Of the 44 FAILs: 5 are
     reversed geometry (PASS when reversed: Tan96.1712.2, Shuku91.24305.1/.2, Nishiki25.68002.2,
     Shinko21.61102.1); ~30 have exactly one end stop 50–190 m off (the shape starts/ends on the street, the
     pole is inside a terminal or depot — e.g. Higashi43.40408.1 stop 0 at 190 m); a few are partial
     (Haya81.16501.3 loop covers 75% of its stops; Ou78.24102.1, Shina97.24002.2 drift mid-route). Suggest:
     for Toei, tolerate the first/last stop up to ~200 m.
   - Size: the To07 reply (6 patterns, with shapes) **2.4 KB gz / 20.3 KB raw** — that is what the adapter
     already downloads. Latency 25.7 s for that first call today (cold; pole calls 2.3–7.8 s; the whole-network
     pattern list 375 KB gz in 25.8 s).
5. **Cache key**: pattern `owl:sameAs` + `dc:date` (2026-09-03T03:08:13+09:00 on every pattern today) — a free
   change signal in the reply. Static resources carry `Cache-Control: max-age=3600` and weak ETags. Since
   the shape comes with the pattern, just persist it with the pattern; revalidate weekly.
6. **Terms**: no published rate limit; CC BY 4.0, credit "東京都交通局・公共交通オープンデータ協議会" / "Bureau
   of Transportation, Tokyo Metropolitan Government / Association for Open Data of Public Transportation" — the
   adapter's existing `attribution` already covers drawing the line.
7. Proxy: none (api-public host is token-free).

---

## adelaide-metro

1. **Today** [V]: no live pattern API. `AdelaideStore.network()` builds a weekly on-disk index from the GTFS zip
   by HTTP range reads (`GTFSZip`): EOCD from `bytes=-8192`, the central directory, then each entry's local
   header + deflated bytes (`agency`, `routes`, `trips`, `stops`, `stop_times` streamed through
   `PatternCollector`). `routePattern` answers from that index. `TransitLine.id` =
   `"route|direction|fromCode|toCode"`, `providerRefs` route/direction/from/to/via. **`shape_id` is not kept**
   (the trips parse reads only `trip_id, route_id, direction_id, trip_headsign`).
2. **Live shape: none per line.** The feed has it: version 1710 (`/v1/static/latest/version.txt`),
   `google_transit.zip` 15,074,271 B, 12 entries, **`shapes.txt` 8,640,320 B deflated / 35,911,345 B CSV**
   (1,763 shapes, median 349 points, max 4,694), `trips.txt` has a `shape_id` column [V].
   **Can one route's shape be range-read cheaply? No** [V]. shapes.txt *is* grouped by `shape_id` and sorted
   numerically (not lexically), but it is one raw-deflate stream: a byte offset in the middle cannot be
   inflated without the preceding 32 KB window, so reaching shape N means inflating everything before it
   (on average ~4.3 MB of the 8.6 MB). The zip has no per-shape entries.
   **Recommended (on-device, 0 extra calls per line)**: extend the weekly index build — keep `shape_id` per
   trip (column 8), record the most common shape_id per pattern in `PatternCollector`, and stream
   `shapes.txt` (+8.6 MB once a week, on top of today's ~6.5 MB) keeping only the shapes the patterns use
   (all 1,763 are used; none is shared between routes). Douglas–Peucker 3 m + precision-5 polyline: **all 1,763
   shapes = 966 KB on disk (447 KB gzip)**, vs 2.56 MB unsimplified. Alternatively do it lazily, the first
   time any Adelaide line's map is opened.
   **Alternative (offline pipeline)**: the hosted-files job takes `shapes.txt` as-is (no pfaedle needed):
   source URL `https://gtfs.adelaidemetro.com.au/v1/static/{version}/google_transit.zip`, version from
   `/v1/static/latest/version.txt`; key per pattern by the adapter's id `route|direction|from|to` (or the
   stop-id-sequence hash); whole network ≈ 447 KB gz, or ~0.5 KB per pattern file.
3. **Format**: CSV `shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled` (lat, lon;
   distance in km, like stop_times). A stop pattern can carry several shape_ids with identical geometry
   (route 300: 16743 / 18752, both 982 points) — pick the most frequent.
4. **Live** [V] (patterns built exactly like `PatternCollector`, busiest stop sequence per route+direction):

   | line | stops | shape_id | max / median | ratio | verdict |
   |---|---|---|---|---|---|
   | 206 dir 0 (fixture route) | 28 | 12340 | 18.5 / 5.7 m | 1.10 | PASS |
   | 206 dir 1 | 35 | 17933 | 26.3 / 7.0 m | 1.09 | PASS |
   | 300 Suburban Connector dir 1 (**loop**, 64.9 km) | 176 | 16745 / 18755 | 14.4 / 6.1 m | 1.12 | PASS |
   | 300 dir 0 | 177 | 16743 / 18752 | 19.2 / 5.8 m | 1.10 | PASS |
   | 98A City Connector (**loop**) | 32 | 16726 | 15.6 / 7.4 m | 1.20 | PASS |
   | 99C City Connector (**loop**) | 15 | 14921 | 22.0 / 8.9 m | 1.10 | PASS |

   Download: the full zip took 157 s from here (≈ 96 KB/s, CloudFront `RefreshHit`); ranged tail 6.6 s.
5. **Cache key**: `adelaide-metro|{route}|{direction}|{from}|{to}` → polyline, plus the feed version
   (`version.txt`, "1710"; zip ETag `"1de65e8c…-2"`, Last-Modified 2026-10-16) as the cheap change signal —
   one tiny request. Rebuild with the existing weekly index.
6. **Terms**: CC BY (adelaidemetro.com.au/developer-info); credit "Adelaide Metro – Department for
   Infrastructure and Transport, South Australia" (already the adapter's `attribution`). Static files on
   S3/CloudFront, no documented limit for them (SIRI's 4 req/s doesn't apply).
7. Proxy: none.

---

## Summary

| provider | extra calls per cold line | piggyback? | format | verified lines PASS/FAIL | max offset | size | latency | cache key | notes |
|---|---|---|---|---|---|---|---|---|---|
| hk-kmb | 1 per route number (all dirs + service types) | no (CSDI host) | GeoJSON MultiLineString [lon,lat], pieces in order | 1A O, 8A loop, 11 O st1, 11 O st2: 4 PASS | 23–30 m | 1–4 KB gz simplified (21 KB gz full) | 2.9–5.5 s | line id + stop-id hash → ROUTE_ID/SEQ | pick feature by stop fit; seq ≠ direction; WAF blocks `IN (…)` |
| hk-citybus | 1 per route number | no | same | 11 O loop-half PASS; 1 O FAIL→PASS (drop 1 union stop); 11 I FAIL→PASS (drop 1) | 8.8 / 7.3 / 42.7 m | 11–55 KB gz full; use simplification | 4.6–5.8 s | same | API stop lists are the union of TD variants; trim loops to first..last stop |
| hk-gmb | 1 | no (termini call has no geometry) | GeoJSON LineString | HKI 12 loop PASS; HKI 1 FAIL on length ratio only | 9.1 / 15.2 m | 2.3–9.3 KB gz | 4.5–4.8 s | route_id+route_seq (direct match) | ids match the API exactly; Peak road trips the 1.5× rule |
| hk-nlb | 1 per route number | no | MultiLineString | 3M PASS, 38 loop PASS | 22.3 / 21.1 m | 1.7–3.6 KB gz | 3.9–6.3 s | line id + stop hash | seq 2 = TC→MW |
| hk-mtrbus | 1 (K12/K14/K17/K18 only) / offline for 22 routes | no | MultiLineString | K12 O, K12 I PASS | 39.2 / 35.5 m | 6.6 KB raw | ~2 s | REFERENCE_ID:DIR | CSDI codes them `KMB`; rest → TD GTFS (LRTFeeder, no shapes.txt) + pfaedle |
| odpt-toei | **0** | **yes**: `ug:region` in `odpt:BusroutePattern` | GeoJSON LineString [lon,lat], sparse | To07 ×2, Shina91 loop, I92 loop: 4 PASS; sweep 704/748 PASS | 10.6–14.8 m (p90 33 m) | 2.4 KB gz per route (already downloaded) | 0 extra (pattern call 2–26 s) | pattern sameAs + dc:date | reverse if failing (5 patterns); 9 patterns lack shapes; terminal end stops up to 190 m |
| adelaide-metro | 0 after a weekly +8.6 MB stream of shapes.txt (no per-line range read possible) | piggyback on the weekly GTFS index | GTFS shapes.txt CSV lat,lon | 206 ×2, 300 loop ×2, 98A loop, 99C loop: 6 PASS | 14.4–26.3 m | all shapes 966 KB (447 KB gz) after DP 3 m | one-time stream (CDN slow: 157 s for 15 MB here) | route|dir|from|to + feed version | alt: offline file from shapes.txt, no pfaedle needed |

**Blockers / open items**
- No blockers for drawing. No proxy changes. No 429s hit; CSDI returned one WAF 403 (on an `IN (…)` filter,
  avoidable) and 3 timeouts.
- HK needs an on-device "pick the feature by fit, then trim" step; Citybus also needs tolerance for 1–2
  stops that belong to another TD variant.
- The 1.5× length rule rejects real shapes with sparse stops on winding roads (GMB HKI 1, the Peak);
  consider relaxing it.
- MTR Bus: 22 of 26 routes need the offline pipeline (TD GTFS has no shapes).
- CSDI T&C wording beyond the attribution/indemnity clauses was read from a search summary, not the page [U].
