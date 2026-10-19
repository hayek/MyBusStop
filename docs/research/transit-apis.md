# BusBus — Transit data source research

Research date: 2026-09-16 (all live calls made 17:57–18:50 UTC that day). Research only; no app code.

Feature the data must support: user picks a **stop** + **line**; app shows a **progress bar** of the next bus of that line moving toward that stop. Needs (1) stop search + lines per stop, (2) ordered stop sequence / shape for the correct direction, (3) real-time vehicle GPS with position along the route, (4) ideally ETA predictions at the stop.

Confidence legend used throughout: **[V]** verified from official docs or a live call made during this research; **[I]** inferred / from memory / partially verified; **[U]** could not verify.

---

## 1. Executive summary

_(filled in at the end — see section 1 at the bottom of the file, "Executive summary (final)".)_

---

## 3. Detailed per-service sections

### 3.1 Israel

#### 3.1.1 Israel MOT static GTFS (gtfs.mot.gov.il) — [V]

- **What**: the national GTFS for all Israeli operators (Egged, Dan, Metropoline, Kavim, Superbus, Nateev Express, Electra Afikim, Tnufa, Israel Railways, Carmelit, light rail). Gives stops (with `stop_code` = the number on the sign), routes (`route_desc` = `"<route_mkt>-<direction>-<alternative>"`, e.g. `13112-2-#` for Haifa 112 direction 2), trips, stop_times (with `shape_dist_traveled`), shapes. Also `TripIdToDate.zip` (trip_id → date mapping used for SIRI matching), `ClusterToLine.zip`, `Tariff.zip`, `zones`.
- **Live check** (2026-09-16 17:57Z): directory listing at `https://gtfs.mot.gov.il/gtfsfiles/` is public; `israel-public-transportation.zip` = 212,170,602 bytes, last modified 15 Sep 2026 20:36 (updated daily, no auth, supports HTTP range requests, `Cache-Control: no-store`). `Gtfs_10_days.zip` = 248 MB (10-day horizon). No login, no key.
- **Does NOT give**: any real-time data. Israel publishes **no public GTFS-RT feed** — the Mobility Database catalog (feeds_v2.csv, downloaded this session) lists exactly 2 IL rows, both `gtfs` static (one active pointing to the URL above, one deprecated); zero `gtfs_rt` rows for IL. [V]
- **Cost/limits**: free. It is a 212 MB daily zip — must be processed on a backend (or a nightly job) and never downloaded by the phone. Route/stop identifiers churn daily (trip_ids are regenerated; `stop_code` and `route_mkt`/`route_desc` are the stable keys). [V]
- **ToS**: gov.il open data ("Other (Open)" licence on data.gov.il; the MOT GTFS Developer Information PDF is the reference). gov.il itself is behind Cloudflare and blocked curl/WebFetch during this session, so the exact licence text was not re-read. [I]
- **iOS-direct?** No (size). Backend/nightly ETL only.

#### 3.1.2 Israel MOT SIRI (SM / VM real-time) — official source — [I]/[U]

- **What**: the Ministry's SIRI 2.8 service (Stop Monitoring; historically Vehicle Monitoring). It is the upstream for everything real-time in Israel (Moovit, bus.gov.il, Stride, curlbus).
- **Access**: application to MOT via the gov.il "real-time information (SIRI)" page; you receive a key and must supply a **static IP for whitelisting**. Evidence: hasadna's requester config needs `OPEN_BUS_MOT_KEY` plus an **SSH tunnel to a proxy server "which is authorized to access MOT servers"** (raw config.py read live) [V]; curlbus README: "the API access requires your IP to be added to the whitelist, which means you have to have a static IP. Not great for cloud deployments" [V]. The gov.il page itself returned Cloudflare 403 / "blocked" to both curl and WebFetch in this session, so the current form, approval time and 2026 status were **not verified** [U]. Approval has historically taken days–weeks and is granted to organisations, not anonymous individuals [I].
- **Format**: SIRI 2.8 SOAP/XML (SM = per-stop arrival predictions with vehicle location; hasadna polls a full-network snapshot ~every 60 s and gets ~5,000–5,600 vehicle positions per snapshot — see 3.1.3). [V for the snapshot sizes]
- **Cost**: free. **Limits**: unknown/unpublished; whitelisted-IP model implies one server, not per-user devices. [U]
- **iOS-direct?** **Impossible** by design (IP whitelisting). Requires our own backend with a static IP.
- **Status 2026**: still the live upstream (Stride snapshots at 18:26Z today were loading fine), so it is active. [V indirectly]

#### 3.1.3 Open Bus Stride API (Hasadna) — `https://open-bus-stride-api.hasadna.org.il` — [V]

- **What**: free REST/JSON (FastAPI, OpenAPI at `/openapi.json`, docs at `/docs`) over a Postgres DB that hasadna fills from (a) the daily MOT GTFS and (b) SIRI SM snapshots polled ~every 60 s. Endpoints: `gtfs_stops`, `gtfs_routes`, `gtfs_rides`, `gtfs_ride_stops`, `gtfs_agencies`, `siri_routes`, `siri_rides`, `siri_stops`, `siri_ride_stops`, `siri_vehicle_locations`, `siri_snapshots`, plus use-case endpoints `route_timetable`, `stop_arrivals`, `rides_execution`, `siri_velocity_aggregation`. No key, CORS open, ~0.5–4.4 s per call in this session.
- **Live calls made today (Haifa line 112)**:
  - `GET /gtfs_routes/list?date_from=2026-09-16&date_to=2026-09-16&route_short_name=112&limit=50` → 13 routes nationally named "112"; the Haifa ones are agency **אגד (operator_ref 3)**: `id 9591740, line_ref 13387, route_direction 1, route_mkt 13112` (חוף הכרמל → נשר) and `id 9591741, line_ref 13389, route_direction 2` (נשר → ת. מרכזית חוף הכרמל/הורדה). Filter by `operator_refs`/`agency_name` or by route_long_name to pick the city; there is no "city" filter on routes.
  - `GET /gtfs_stops/list?date_from=…&city=חיפה&limit=…` (haifa_stops.json, 1,217 stops) → 24 stops with "אלנבי" in the name. The Allenby stops on line 112 direction 2 (ride 157002677, `gtfs_ride_stops/list?gtfs_ride_ids=157002677&arrival_time_from=…&arrival_time_to=…&order_by=stop_sequence asc`, 67 stops):
    - seq 35 code **41572** אלנבי/בן גוריון (shape_dist 14,265 m), 36 **41573** אלנבי/רוטשילד, 37 **41119** אלנבי/דרור, 38 **41120** אלנבי א, 39 **41121** אלנבי ב, **40 → 41122 "אלנבי ג" (shape_dist_traveled 15,794 m of 23,840 m)**, 41 **42606** דרך אלנבי/סלבדור, 42 **43139** המוזיאון הימי/דרך אלנבי, 43 **47410** אלנבי.
    - Direction 1 has the mirrored stops 41114–41117 ("אלנבי א/ב/ג" on the other side of the road, codes 41115, 41116, 41117). So "Allenby G" = stop code **41122** (dir 2, toward Hof HaCarmel) or **41117** (dir 1, toward Nesher). `stop_code` is stable; `gtfs_stop.id` changes daily (e.g. 48444732 today).
  - `GET /siri_vehicle_locations/list?siri_routes__line_ref=13389&recorded_at_time_from=<now-30m>&order_by=recorded_at_time desc&limit=5` → response shape (one element):
    ```json
    {"id":8624798718,"siri_snapshot_id":2403756,"siri_ride_stop_id":3791098604,
     "recorded_at_time":"2026-09-16T17:39:12+00:00","lon":34.983521,"lat":32.820313,
     "bearing":298,"velocity":0,"distance_from_journey_start":14737,
     "distance_from_siri_ride_stop_meters":null,"siri_snapshot__snapshot_id":"2026/09/16/17/39",
     "siri_route__id":1502,"siri_route__line_ref":13389,"siri_route__operator_ref":3,
     "siri_ride__id":148235804,"siri_ride__journey_ref":"2026-09-16-12304458",
     "siri_ride__scheduled_start_time":"2026-09-16T17:00:00+00:00","siri_ride__vehicle_ref":"23338002",
     "siri_ride__gtfs_ride_id":null}
    ```
    `distance_from_journey_start` (metres along the route, computed by hasadna) is directly usable for the progress bar; `siri_ride_stop_id` → `order` (SIRI stop order in the ride) is the "current/next stop" pointer. `siri_ride__gtfs_ride_id` was **null** for today's live rides (GTFS↔SIRI matching runs later), so match to GTFS via `journey_ref` ("2026-09-16-12304458" ↔ GTFS trip `12304458_160926`) or via `line_ref` + `scheduled_start_time`.
  - **Freshness (the key finding)**: at **17:57:22Z** the newest point for line 13389 was recorded **17:39:12Z → 18.2 minutes old**. At **18:44:51Z** the newest was **18:32:40Z → 12.2 minutes old**. `siri_snapshots/list?snapshot_id_prefix=2026/09/16/18` showed snapshot `2026/09/16/18/24` finishing ETL at 18:37:03Z and `18/25` at 18:38:21Z, i.e. **the ETL runs ~12–13 minutes behind the SIRI clock and each 1-minute snapshot takes ~75 s to load** (5,234–5,643 vehicle locations per snapshot). So Stride is a **near-real-time-minus-10-to-20-minutes** source. Good for history/analytics and for building the route model; **not good enough on its own to animate a bus that is 3 minutes away**.
- **Coverage**: all of Israel, all operators (whatever MOT SIRI returns).
- **Auth/cost**: none, free. **Limits**: no documented rate limit; default 100 rows/query, max 500,000; the docs ask you to "set appropriate query parameters to reduce load on our DB". No SLA — it is a volunteer/NGO project on a single Kubernetes cluster (created_by `siri-etl-…` pods). Occasional ETL stalls happen (the openapi doc is versioned by git hash). [V]
- **ToS**: no formal terms published; project is open source (MIT-style repos). Attribution to "Open Bus / Hasadna" is expected good practice. Calling it from thousands of phones every 10 s would be abusive and could get the project throttled — use a backend cache or contact hasadna first. [I]
- **iOS-direct?** Technically yes (no key, CORS open, JSON). Practically: latency + shared community DB → use only for stop/route/shape lookups (cached) and as a fallback for positions.
- **Status 2026**: active, data flowing today. [V]
- **Quirks (from open-source clients)** — checked live 2026-09-28 ~15:15–15:25Z:
  - `gtfs_ride_stops/list` is slow unless it also carries the GTFS dates: hasadna's maintainer asks callers to "always add gtfs date ranges" (`gtfs_stop__date_from/to`, `gtfs_route__date_from/to`) ([open-bus-stride-api#26](https://github.com/hasadna/open-bus-stride-api/issues/26)). Measured: lines-at-stop 6.4–6.8 s → 0.4–0.5 s, arrivals 1.3–2.1 s → 0.2–0.3 s, identical rows (apart from the previous service day's after-midnight rides, which the date filter drops). **Fixed in `StrideProvider`**; arrivals span yesterday's date through the date the 3-hour window ends in, so rides past midnight still show.
  - `siri_vehicle_locations/list` by `siri_routes__line_ref` + a 40-min `recorded_at_time` window took 13–36 s on a cold line; adding `siri_rides__scheduled_start_time_from/to` (−12 h … +1 h) returned the same bytes in 5–11 s. **Fixed in `StrideProvider`**. The endpoint times out outright for some dates/boxes ([open-bus-stride-api#67](https://github.com/hasadna/open-bus-stride-api/issues/67)); our 60 s timeout stays. The old misspelled `siri_rides__schedualed_start_time_*` parameter still exists beside the correct one ([#22](https://github.com/hasadna/open-bus-stride-api/issues/22)).
  - Freshness unchanged from 2026-09-16: newest point 13–15 min old ([V], this session).
  - Every time filter needs an explicit offset; a naive datetime is a 500 "tzinfo is required" ([open-bus-map-search#1773](https://github.com/hasadna/open-bus-map-search/issues/1773)). We send `Z` (ISO8601DateFormatter). GTFS `date` fields are the Israeli service date while timestamps are UTC; hasadna's own `rides_execution` once cut days at UTC midnight ([open-bus-stride-api#54](https://github.com/hasadna/open-bus-stride-api/issues/54)) — we build day windows in Asia/Jerusalem.
  - Silent default page sizes (100 on most lists) and a hard cap around 15–20k rows (500 above it) ([open-bus-map-search#1772](https://github.com/hasadna/open-bus-map-search/issues/1772)); `siri_vehicle_locations/list` takes one `line_ref` only. Our calls all pass an explicit `limit`; the busiest stop checked (26656) had 195 ride-stops/day, far under our 1,000.
  - Repeated location rows (same ride, time and position, ~10% of rows) and duplicate `siri_ride` rows for one `journey_ref` when the scheduled start drifts ([open-bus-map-search#1776](https://github.com/hasadna/open-bus-map-search/issues/1776)). We keep the newest row per `siri_ride__id`, which absorbs the first; the second would show one bus twice — none seen on six lines today, so not handled [I]. `journey_ref` can also be a placeholder like `"2022-03-06-0"` ([#16](https://github.com/hasadna/open-bus-stride-api/issues/16)).
  - Frozen vehicles: line 23397 returned 18 rows over 36 min, all one identical ping — a bus whose SIRI position stopped updating stays in the feed ([V], this session).
  - Some lines at a stop are absent from Stride's GTFS: at 41122 Stride lists 112 and 110, bus.gov.il also 148 ([V], this session; cause unknown).
  - Clients studied: [hasadna/open-bus-map-search](https://github.com/hasadna/open-bus-map-search) (`src/api/gtfsService.ts`, `siriService.ts`: ±1-day `start_time` windows, one ride as the pattern representative, dedupe stops by code), [skills-il/mcps openbus-mcp](https://github.com/skills-il/mcps/tree/main/openbus-mcp) (self-imposed 1 request/s, 30 s timeout), [NoamGaash/open-bus-mcp](https://github.com/NoamGaash/open-bus-mcp) ("the API can be slow… use small datetime ranges"; "if data is missing, try older date ranges"). The daily GTFS moves to the 10-day `Gtfs_10_days.zip` and `route_desc` stops being makat-direction-alternative ([open-bus-pipelines#16](https://github.com/hasadna/open-bus-pipelines/issues/16)) — watch for route-id changes [U: date not given].

#### 3.1.4 bus.gov.il / route.bus.gov.il anonymous API (`api.bus.gov.il/prod/*`) — [V but undocumented]

- **What**: the JSON API behind the National Public Transport Authority's route planner (`route.bus.gov.il`, the *8787 / "Kol Kav" web front). Discovered by reading the SPA's config chunk (`chunk-TG7MNW7S.js`): `schedule_service_url`/`calendar_service_url` = `https://api.bus.gov.il/prod/mot-scheduler-prod/api/`, `route_planning_service_url`/`auto_complete_service_url`/`location_service_url` = `https://api.bus.gov.il/prod/route-planner-prod/api/`. Paths are `{base}/{he|en|ar}/{Controller}/{Action}`. It is an AWS API Gateway (`{"message":"Forbidden"}` on wrong path). **No key, no cookie** — only normal browser headers (`Referer: https://route.bus.gov.il/`, `Accept: application/json`) were sent; whether Referer is enforced was not tested.
- **Endpoints seen in the SPA** (mot-scheduler): `Stops/GetStopByCode`, `Stops/GetStopFullData`, `Stops/GetStopsCloseToLocation`, `Stops/GetclosestStop`, `Stops/RefreshStopTimesAtStop`, `Stops/GetSpecialMessagesByStopAndDay`, `Routes/GetRouteStops`, `Routes/GetRouteFullData`, **`Routes/GetRouteLocations`**, **`Routes/GetNextRouteLocation`**, `Routes/GetTripShapePolyline`, `Routes/GetRoutePolylineByRouteDescStopAndTime`, `Calendar/GetRouteCalendarAtStopsByStopCodes`, `Calendar/GetTripCalendarByRouteDesc`, `Calendar/GetRouteDailyCalendar`; (route-planner): `AutoComplete/SearchStations`, `AutoComplete/SearchLines`, `AutoComplete/SearchLocations`, `RoutePlanning/GetRoutes`.
- **Live calls made today (all HTTP 200, 0.4–0.6 s; RefreshStopTimesAtStop 13 s / 170 KB)**:
  - `GET …/mot-scheduler-prod/api/he/Stops/GetStopByCode?stopcode=41122` → `{"data":{"stopid":2005,"stopcode":41122,"name":{"he":"אלנבי ג","en":null,"ar":null},"lat":32.827033,"lng":34.975622,"cityName":"חיפה","streetName":"דרך אלנבי","streetNumber":"166",…},"success":true}`
  - `GET …/route-planner-prod/api/he/AutoComplete/SearchStations?searchTerm=אלנבי` → list of `{stopid, stopcode, name:"אלנבי ג (41122)", lat, lng, cityName}` across the country (Tel Aviv + Haifa hits). Stop search: solved.
  - `GET …/he/Stops/RefreshStopTimesAtStop?stopCode=41122&day=2026-09-16T21:44:00` → `routesInStop[]`: for each line at the stop: `routeId` (=SIRI line_ref, 13389), `routeName` "112", `routeDesc` "13112-2-#", `agencyName`, `headsign {he,en,ar}`, and **`stops[]` = the full ordered stop list of that route (67 stops, each with `stopSequence`, `stopcode`, lat/lng)**. Lines-per-stop and route stop sequence: solved in one call (but heavy: 170 KB — cache it).
  - `GET …/he/Calendar/GetRouteCalendarAtStopsByStopCodes?stopCodes=41122&routeDesc=13112-2-%23` → per stop: `stopTimes[]` each with `staticTripId` ("12304392_150926"), `staticArrivalTime`, **`arrivalTime` (predicted), `minutesToArrival`, `isRealTime`, `isLate`, `stopOrder` (40 = Allenby G's sequence), and `routeLocation {lat,lng}` = the current GPS of that trip's bus**, plus `routeLocationAtStop`. Non-real-time (future scheduled) entries have `routeLocation: null`.
  - **Freshness**: two calls 46 s apart (18:44:02Z / 18:44:48Z) returned different `routeLocation`s for the same trip (32.7775,35.0301 → 32.7809,35.0246) and the ETA moved 21.0 → 20.1 min, i.e. **positions update at least every ~45 s, apparently straight from MOT SIRI — roughly 12 minutes fresher than Stride for the same line at the same moment**. [V]
- **Coverage**: all of Israel (same upstream as Moovit).
- **Auth/cost**: none / free. **Limits**: unknown, undocumented; the Home-Assistant integration this was reverse-engineered from (gov_api.py in scratchpad) implements HTTP 429 handling, so a rate limit exists. [I]
- **ToS**: **none published for the API; it is an internal API of a government website**, not an offered developer product. Its previous incarnation (`bus.gov.il/WebApi/api/passengerinfo`) was removed when the site was rebuilt — the same can happen again without notice. Legally it is public government information, but there is no licence grant for the API itself. Treat as **"unofficial, may break, do not depend on it as the only source"**.
- **iOS-direct?** Technically yes (no key). Risk: they could add Referer/Origin checks, a key, or Cloudflare bot checks at any time; a backend proxy lets us swap sources without an app update.
- **Status 2026**: live today. [V]
- **Quirks (from open-source clients)** — main reference [ziv-daniel/hass-israel-transportation-integration](https://github.com/ziv-daniel/hass-israel-transportation-integration) (`custom_components/israel_transportation/gov_api.py`, `const.py`, CHANGELOG 1.1.1), the only other public client found (GitHub code search for the host, 2026-09-28; `liorhad97/busnow` names `api.bus.gov.il/v1/buses` but is a placeholder with a fake key). Checked live 2026-09-28 ~15:15Z:
  - **Duplicate arrivals**: `GetRouteCalendarAtStopsByStopCodes` can list a live trip twice — once real-time (`staticTripId`, `staticArrivalTime` 18:49:26, `arrivalTime` 18:48) and again as a bare scheduled entry (`staticTripId`/`staticArrivalTime` null, `arrivalTime` 18:49:26, `isRealTime:false`). Seen on 2 of 3 lines at 41122 (112, 148), none at 21457 or 26656 [V]. **Fixed in `BusGovILProvider`**: a scheduled entry whose `arrivalTime` equals a live entry's `staticArrivalTime` is dropped. The reply holds only 3 entries per route.
  - `minutesToArrival` is counted from the server's own `startTime` (Israel local, 7 decimals) and `arrivalTime` is rounded to the minute, so now + minutes is the better clock; we already prefer it. HA drops negative values; we filter arrivals more than a minute past in `BusProgressService`.
  - Polling: HA defaults to 30 s (min 15 s, max 10 min), 15 s timeout, ≤5 concurrent requests, ≤12 routes per poll at big interchanges ("Tel Aviv Savidor has 53"), and caches routes-at-stop for an hour — but never an empty list, which is usually a night gap or a hiccup. Our 20 s is in range.
  - **Rate limit**: HA treats HTTP 429 with `Retry-After` (default 60 s) as a backoff signal; we have never seen one [U]. No `Cache-Control`/`ETag` on replies; served by CloudFront (`x-cache: Miss`, TLV edge) in front of API Gateway [V].
  - Headers: HA sends a desktop Chrome User-Agent plus `Referer`/`Origin: https://route.bus.gov.il`; bare requests work today [V], but those are the first things to add if the gateway starts refusing us.
  - Removed or wrong endpoints answer **200 with an HTML page** (e.g. `GetStopByCode?stopcode=abc` → Hebrew error page); the old `/WebApi/api/passengerinfo` API now serves the site's SPA shell. HA checks `Content-Type` for "json"; we surface it as a decoding error with the body, which reaches Crashlytics.
  - An unknown stop code is `{"data":null,"success":true}`; HA also treats `success:false` as a failure — never seen it [U]; we would read it as empty.
  - `Stops/RefreshStopTimesAtStop` takes a `day` that must be **Israel local**: a UTC date between 00:00 and 02:00/03:00 asks for yesterday and returns zero routes (HA 1.1.1 fix). We use `GetStopFullData`, which has no date.
  - Stop code (makat, on the sign) ≠ GTFS `stop_id`; they share a numeric range, so mixing them silently picks the wrong stop (HA 1.1.1). Line names match verbatim incl. Hebrew suffixes ("1" vs "1א").

#### 3.1.5 curlbus (`curlbus.app`) — [V]

- Terminal/JSON front-end to MOT SIRI-SM by stop code (`curl https://curlbus.app/41122`). Open source; the public instance is run by one person with his own MOT SIRI credentials. README confirms MOT access needs a whitelisted static IP. Not a platform to build a product on (no SLA, no ToS, single-maintainer), but a good reference implementation of the SIRI-SM request and of GTFS matching. Whether the public instance is currently up was not tested. [U]

#### 3.1.6 data.gov.il — [V]

- CKAN portal. `package_search?q=gtfs` → 2 datasets, both MOT statistics (e.g. `tikufim_station_2022`, ticket validations per station, licence "Other (Open)", contact bidata@mot.gov.il). **No GTFS or SIRI mirror there**; the transport data lives on gtfs.mot.gov.il and the SIRI programme. Not useful for real-time.

#### 3.1.7 Moovit — [V for status, I for terms]

- Moovit has no self-service developer API. `moovitapp.com/developers` is empty; `moovit.com/maas-solutions` lists "Public Transit APIs" as an enterprise MaaS product behind "Get in touch" (sales). No pricing published. Moovit's own Israel data is MOT SIRI + GTFS anyway. Not viable for an indie app.

#### 3.1.8 Transitland coverage of Israel — [V]

- Transitland ingests the MOT GTFS: `transit.land/operators?search=israel` lists Israeli operators (Dan, United Tours, Tevel, Extra, Beit Shemesh Express, Tnufa, Cable Express Haifa, Eilot regional council…). Static only — there is no GTFS-RT for Israel to ingest, so **no Israeli real-time via Transitland**. Static stop/route lookups for Israel would work under the free tier (10k REST queries/month) but the Hebrew names arrive as-is and IDs are Transitland Onestop IDs.

#### 3.1.9 HERE Public Transit — Israel — [V]

- HERE's transit coverage table (here_cov.md, "coverage-transit-source.md") lists Israel with operators Egged (אגד), Electra Afikim, Dan BaDarom, Metropoline, Nateev Express — all marked "Realtime routing" — so HERE has real-time-informed **departures** for Israel. HERE does not expose vehicle GPS. See 3.2.6.

#### 3.1.10 Operator apps (Egged/Dan) — [U]

- Operators' own apps call proprietary/undocumented backends; not researched further (Moovit/MOT SIRI is the sanctioned real-time path). Mark as not viable.


#### 3.1.4-addendum bus.gov.il — vehicle-position endpoints (live, 18:51–18:53Z) — [V]

- `GET …/mot-scheduler-prod/api/he/Routes/GetRouteLocations?routeId=13389` → `{"data":[{"lat":32.804653,"lng":35.005341}],…}` = **current GPS of every bus on that route (routeId = SIRI line_ref)**. Three calls at 18:51:32 / 18:52:15 / 18:52:57Z each returned a moved position (32.8047,35.0053 → 32.8050,35.0032 → 32.8064,35.0021) → **refresh ≤ ~40 s, effectively raw MOT SIRI freshness**. Caveat: bare lat/lng only — no trip id, vehicle id, bearing or timestamp; correlate with `Calendar/GetRouteCalendarAtStopsByStopCodes` (which gives `routeLocation` + `staticTripId` + `stopOrder` per upcoming trip) or snap to the shape.
- `GET …/he/Routes/GetNextRouteLocation?routeDesc=13112-2-%23&stopCode=41122` → `{"data":{"lat":32.806419,"lng":35.00211}}` = **the position of the next bus of that line toward that stop** — the exact single value the progress bar needs (routeId/stopCode variants returned the HTML error page; `routeDesc` + `stopCode` is the working combination).
- `GET …/he/Routes/GetRouteStops?routeId=13389` → `route.stops[]` ordered with `stopSequence`, `stopcode`, trilingual `name {he,en,ar}`, lat/lng (67 stops; 1.0 s). Lighter than `RefreshStopTimesAtStop`.
- `GET …/he/Stops/GetStopsCloseToLocation?lat=32.827&lng=34.975&radius=300` → nearby stops each with `routesInStop[]` (lines serving it, with their full stop lists). Nearby-stop search: solved.
- `GET …/he/Routes/GetTripShapePolyline?routeId=13389` → `"data":""` (empty; needs other params — [U]). Shapes are available from the MOT GTFS `shapes.txt` instead (or interpolate along stop coordinates).
- Header requirements: **none** — the calls succeeded with no Referer, no Origin and an empty User-Agent. English names: `…/api/en/…` returns `name.en` where MOT has it (e.g. "HaShita/Tennis Courts", "Allenby A").
- For the progress bar in Israel: position of next bus (`GetNextRouteLocation`) or all buses (`GetRouteLocations`) → project onto the ordered stop polyline from `GetRouteStops` (or GTFS shape with `shape_dist_traveled`) → progress = dist(bus) / dist(stop 41122 = 15,794 m of 23,840 m). ETA from `GetRouteCalendarAtStopsByStopCodes.minutesToArrival` (`isRealTime:true`).

### 3.2 Worldwide

#### 3.2.1 Transitland v2 (Interline) — [V]

- **Gives**: stops, routes (with geometry), trips, stop_times, **departures with GTFS-RT TripUpdates merged** (`schedule_relationship`, realtime vs scheduled fields), service alerts; feed metadata + download of latest static/RT feed files. **No vehicle-position API**: docs state "Transitland does not use vehicle positions to independently estimate real-time arrivals" and there is no vehicles endpoint (the `/realtime` docs page 404s). Source for positions would be downloading the operator's raw `vehicle_positions.pb` through Transitland, which is metered as REST queries.
- **Coverage**: thousands of feeds worldwide incl. Israel static (3.1.8); RT only where operators publish GTFS-RT (not Israel).
- **Protocol**: REST JSON/GeoJSON, GraphQL (Pro only), vector tiles. **Auth**: `apikey` query/header, instant self-serve signup.
- **Cost** (transit.land/plans-pricing, read today): **Free: 10,000 REST queries/month**, 1,000 routing, 100k tiles, no GraphQL. **Professional: $200/mo (annual) / $250/mo**, 200,000 REST, 25,000 GraphQL, 1M tiles. Rate limit on free is "relatively low" (exact per-second figure not stated) [V]. Attribution: "must link to Transitland Terms". Dataset downloads: commercial use ❌ on free (enterprise licence needed); developer API: standard terms. [V]
- **Client-direct?** Key would be in the app and 10k/month is ~1 user's worth of polling → backend + cache only.
- **Status 2026**: active. Best use for us: feed discovery / static normalisation, not live positions.

#### 3.2.2 Mobility Database (MobilityData) — [V]

- **Gives**: a catalog (not data): 6,475 rows in feeds_v2.csv today = 4,548 GTFS + **1,927 GTFS-RT feeds** (entity types: tu 638, vp 588, sa 425, tu|vp 54, sa|tu|vp 35…). Active GTFS-RT feeds by country: US 751, FR 376, CA 217, JP 119, SE 79, AU 42, ES 28, PL 18, FI 15, IT 14, CZ 12, RO 10, NZ 8, PT 7, BE/BG/DE/HU/DK 6 each, LT 5, AT/CH 4… **IL: 0**. Each row has `urls.direct_download`, `urls.authentication_type` (0 none / 1 header / 2 param), `urls.api_key_parameter_name`, licence URL, bounding box, status.
- **Access**: CSV is a free direct download (no key); the REST API (`/v1/gtfs_feeds`, `/v1/gtfs_rt_feeds`, search) needs a free account + refresh-token → access token. No rate limit or price published [U]. Catalog repo Apache-2.0; catalog data licence not confirmed [U].
- **Use for us**: the authoritative list of raw GTFS-RT feeds to consume ourselves (3.2.15). No Israel entries.

#### 3.2.3 Transit app API (transitapp.com/apis) — [V]

- **Gives** (OpenAPI 4.0.0 read from scratchpad): `nearby_stops`, `nearby_routes`, `search_stops` (by name/stop code), `stop_departures` (real-time), `route_details` (shape + itineraries = ordered stops per direction), `trip_details`, **`GET /v4/vehicles` — "real-time vehicle positions for a given route"**, alerts, plan. Exactly the shape we need.
- **Coverage**: 1,253 cities / 40 countries, "130,000 vehicles tracked in real-time"; the regions page **does not list Israel** (verified today). 
- **Auth/cost**: request form → key; **Free: 5 calls/min and 1,500 calls/month**; more = "contact us" (no public price). [V] Terms page returns 404; commercial-use/attribution/client-key rules not verified [U].
- **Client-direct?** No — 1,500/month is unusable from devices; and key in app.
- **Status 2026**: active. Verdict: excellent data model, unusable quota for a consumer app unless a paid deal is made.

#### 3.2.4 Moovit — see 3.1.7. Enterprise-only, no self-serve. Not viable. [V]

#### 3.2.5 Google Maps Platform — [V]

- Routes API / Directions transit mode returns scheduled transit legs (stops, line, headsign, times); the doc has **no real-time vehicle positions and no real-time arrival predictions** ("transit schedules change frequently… no guarantee for predictions"). Google shows live positions inside Google Maps only; there is **no public vehicle-position or departures API**. Terms (gterms/gsst in scratchpad) also forbid caching/storing most content. Not viable for this feature. [V]

#### 3.2.6 HERE Public Transit API v8 — [I]

- **Gives**: `stations` (search), `departures` (board with real-time where available), transit `routes`. **No vehicle positions.** Israel is covered with real-time departures for Egged, Electra Afikim, Dan BaDarom, Metropoline, Nateev Express (coverage table, [V]).
- **Auth/cost**: apiKey; HERE Base Plan freemium — commonly 250k transactions/month free then pay-per-1k; the exact Public Transit line item could not be read (pricing page is JS-rendered) [U]. Terms restrict caching beyond 30 days and require HERE attribution [I]. Keys can be restricted to bundle ID, so client-direct is allowed by HERE [I].
- Verdict: possible **ETA-only fallback**, no positions → cannot drive the progress bar alone.

#### 3.2.7 Navitia / Hove (api.navitia.io) — [I]

- **Gives**: coverage regions (mostly France + some EU/others), stop_areas/points, lines/routes with stop order, `departures`/`stop_schedules` with real-time (`data_freshness=realtime`), `vehicle_journeys`, disruptions. **No vehicle positions** in the public API. Auth: free token from navitia.io (401 "no token. You can get one at navitia.io" verified today). Free plan historically ~90k requests/month (exact 2026 quota unverified, site returned 403) [U]. Israel: not covered [I]. Verdict: EU ETA source, not positions.

#### 3.2.8 OneBusAway (OBA) deployments — [V]

- REST API: `stops-for-location`, `arrivals-and-departures-for-stop` (predictions + `tripStatus` with `position`, `distanceAlongTrip`, `closestStop`), `vehicles-for-agency`, `trip-details`. Per-deployment API key (many regions accept `TEST` or hand out keys by email). Regions API (regions-v3.json) lists **7 active public regions**: Puget Sound, Tampa Bay, MTA New York (bustime), Washington DC (WMATA), San Diego MTS, Adelaide Metro, Davis CA (experimental). Free, no SLA; each region's own terms. Client-direct is normal for OBA (the official apps do it). Data model is very close to ours (distanceAlongTrip). Only relevant for those US/AU metros.

#### 3.2.9 OpenTripPlanner public instances — Entur (Norway) & Digitransit (Finland) — [V]/[I]

- **Entur**: Journey Planner v3 GraphQL (stops, quays, lines, journey patterns, estimated calls = real-time ETAs) + **Realtime Vehicles v2 GraphQL/WebSocket** (`api.entur.io/realtime/v2/vehicles/graphql`; fields lastUpdated, location, delay, line, serviceJourney, progress) + SIRI ET/VM/SX + GTFS-RT updated every 15 s. **Auth: only an `ET-Client-Name: company-app` header** (verified live today, HTTP 200). Licence NLOD (open, commercial OK, attribution). Rate limiting applied to unidentified clients. Client-direct: allowed. Norway only.
- **Digitransit (HSL/Waltti/Finland)**: OTP GraphQL + MQTT vehicle positions; **requires a free subscription key** (401 "missing subscription key" verified; registration page behind Cloudflare, quota unverified [U]). Finland only.

#### 3.2.10 Citymapper — discontinued for self-serve since 23 June 2023 (enterprise only). Not viable. [V]

#### 3.2.11 TfL Unified API (London) — [V]

- **Gives**: StopPoint search, `StopPoint/{id}/Arrivals`, `Line/{id}/Arrivals`, `Vehicle/{ids}/Arrivals` — prediction objects with `vehicleId`, `timeToStation`, `expectedArrival`, `currentLocation` (**empty string for buses in today's sample**; TfL has no bus GPS endpoint — positions must be derived from predictions or from BODS SIRI-VM, which includes TfL's fleet [I]). Live sample (arr.json, line 87 at Charing Cross) shows predictions timestamped seconds ago.
- **Auth/cost**: free; anonymous **50 req/min**, registered app_key **500 req/min** (api-portal products page, [V]). Licence: TfL Transport Data Service terms (OGL-based): commercial use allowed, attribution "Powered by TfL Open Data", TfL may throttle abusive use. Client-direct feasible for low volume.

#### 3.2.12 UK Bus Open Data Service (BODS) — [V]

- **Gives** (England-wide, all operators by law): TransXChange timetables (+ a national GTFS), **SIRI-VM datafeed** (`/api/v1/datafeed/?api_key=…` with `boundingBox`, `operatorRef`, `lineRef`, `originRef`, `destinationRef` filters), **GTFS-RT** (`/api/v1/gtfsrtdatafeed/`), fares NeTEx. Our sample pull (15:45:04Z, no filter) = 31.5 MB XML, **28,279 vehicles**; `RecordedAtTime` age: **p50 = 28 s, 73% ≤ 60 s** (long tail is stale/parked vehicles). GTFS-RT bin = 3.9 MB, header timestamp 10 s before download. SIRI-VM has no MonitoredCall/OnwardCalls (positions only, no ETAs) — ETAs need GTFS-RT TripUpdates or our own projection.
- **Auth**: free account → api_key (401 without). **Cost**: free. **Licence**: OGL v3, "you do not need a licence to use the data" — commercial OK, attribution. Rate limit not published [U]. Client-direct: possible with bbox+lineRef filters but the key is per account → backend proxy recommended.

#### 3.2.13 Swiftly — [I]/[U]

- Agency-facing real-time platform (predictions, vehicles, GTFS-RT) — keys are issued by the customer agency, not self-serve; the developer page 404s. Not a general source for us.

#### 3.2.14 511 SF Bay — [V]

- Free token; GTFS, GTFS-RT (TU/VP/SA), SIRI StopMonitoring/VehicleMonitoring for 30+ Bay Area agencies; **default 60 requests/hour** (higher on request); MTC data agreement. Backend-only (quota).

#### 3.2.15 Rejseplanen (Denmark) & NTA Ireland — [I]/[U]

- Rejseplanen Labs: free Hafas-REST API on request (form), departure boards with real-time, plus open GTFS; vehicle positions via GTFS-RT were not verifiable (site behind Cloudflare) [U]. NTA Ireland GTFS-R: free Azure-portal subscription key, TripUpdates + Vehicles endpoints, daily quota unverified (portal is JS-only) [U].

#### 3.2.16 DIY: consume raw GTFS + GTFS-RT ourselves — [V]

- The most portable and cheapest path: each region = one static GTFS (nightly) + one or more GTFS-RT feeds (poll 10–30 s). Notable free feeds: **UK BODS** (SIRI-VM + GTFS-RT, national), **Entur** (GTFS-RT VP/TU every 15 s, Norway), **Sweden Trafiklab** (GTFS Sverige 2 RT, key), **Finland Digitransit/Traficom**, **Netherlands NDOV/OpenOV** (KV6/GTFS-RT), **Switzerland opentransportdata.swiss** (GTFS-RT TU, key), **Germany**: DELFI static only, VBB/ Hamburg partial, **France** transport.data.gouv.fr (376 RT feeds), **Spain** (Madrid EMT, Barcelona TMB via keys), **Poland** Warsaw ZTM, **Czech** Prague PID, **Japan** ODPT (119 RT feeds), **US/Canada** ~970 feeds (MTA NYC, MBTA V3 API with vehicle positions, CTA, SEPTA, TTC, STM, TransLink…), **Australia** (TfNSW, PTV, TransLink SEQ — keys), **NZ** AT/Metlink. All discoverable via the Mobility Database CSV with `authentication_type` and `api_key_parameter_name`. **Israel is the outlier: no GTFS-RT**, hence the bus.gov.il/Stride route above.
- Costs: bandwidth + a small always-on poller. Protobuf parsing on iOS is fine (SwiftProtobuf) but polling national feeds from phones is not (size, keys) → backend.

## 2. Comparison table

| Service | Coverage | Israel? | Vehicle GPS | ETAs | Format | Auth | Cost | Rate limit | Data latency | Client-direct OK? | Status 2026 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| MOT GTFS static | Israel | yes | no | no | GTFS zip 212 MB/day | none | free | n/a | daily | no (size) | active [V] |
| MOT SIRI SM/VM | Israel | yes | yes (upstream) | yes | SIRI 2.8 SOAP | key + **IP whitelist** | free | unpublished | seconds | **no** | active, access unverified [I] |
| Open Bus Stride | Israel | yes | yes (+dist along route) | schedule only | REST JSON | none | free | none published; be gentle | **12–18 min** measured | yes technically | active [V] |
| bus.gov.il api (unofficial) | Israel | yes | **yes** (`GetRouteLocations`, `GetNextRouteLocation`) | **yes** (`isRealTime`) | REST JSON | none | free | unknown (429 exists) | **≤ ~40 s** measured | yes technically (no key) but unofficial | live [V], no ToS |
| curlbus | Israel | yes | no (SM ETAs) | yes | text/JSON | none | free | none | seconds | hobby service | unverified [U] |
| Moovit API | global | yes | enterprise | enterprise | – | sales | $$$ | – | – | no | enterprise only [V] |
| Transitland v2 | global (static), RT where GTFS-RT exists | static only | no (raw feed download) | yes (TripUpdates) | REST JSON | apikey | free 10k/mo; $200–250/mo Pro | low on free | feed-dependent | no | active [V] |
| Mobility Database | global catalog | static only | catalog of 1,927 RT feeds | – | CSV/REST | free token | free | n/a | n/a | n/a | active [V] |
| Transit app API | 40 countries | **no** | **yes** (`/v4/vehicles`) | yes | REST JSON | key (form) | free 1,500/mo, 5/min | 5/min | seconds | no (quota) | active [V] |
| Google Routes | global | yes | **no** | no | REST | key | paid | – | schedule | – | no RT [V] |
| HERE Public Transit | global | yes (departures) | **no** | yes | REST | apiKey | freemium (~250k/mo [U]) | plan-based | seconds–min | yes (restricted key) | active [I] |
| Navitia | mostly FR/EU | no | no | yes | REST | token | free tier [U] | – | – | no | active [I] |
| OneBusAway | 7 metros | no | yes (distanceAlongTrip) | yes | REST | per-region key | free | region-dependent | seconds | yes | active [V] |
| Entur (OTP) | Norway | no | yes (GraphQL/WS) | yes | GraphQL/SIRI/GTFS-RT | `ET-Client-Name` header | free (NLOD) | fair-use | 15 s | yes | active [V] |
| Digitransit | Finland | no | yes (MQTT) | yes | GraphQL/MQTT | free key | free | [U] | seconds | yes | active [V] |
| Citymapper | – | – | – | – | – | – | – | – | – | – | discontinued 2023 [V] |
| TfL Unified | London | no | no (predictions only) | yes | REST | none/app_key | free | 50/min anon, 500/min key | seconds | yes | active [V] |
| UK BODS | England | no | **yes** (SIRI-VM/GTFS-RT) | GTFS-RT TU | XML/protobuf | api_key | free (OGL) | unpublished | p50 28 s | proxy recommended | active [V] |
| Swiftly | agency customers | no | yes | yes | REST/GTFS-RT | agency-issued | – | – | – | no | [U] |
| 511.org | SF Bay | no | yes | yes | GTFS-RT/SIRI | token | free | 60/hour | seconds | no (quota) | active [V] |
| Rejseplanen / NTA IE | DK / IE | no | partial [U] | yes | Hafas REST / GTFS-R | free key | free | [U] | – | – | [U] |
| DIY GTFS + GTFS-RT | anywhere with feeds | **no feed for IL** | yes | yes | protobuf | per feed | free | per feed | 10–30 s | no (backend poller) | – |

## 4. Key limitations and risks

1. **Israel has no official, self-serve real-time API.** The official path (MOT SIRI) needs an application + static-IP whitelisting → we need a backend anyway. Approval time/criteria for a small indie developer are unverified (gov.il blocked automated access during this research).
2. **The only zero-friction fresh source (api.bus.gov.il) is an undocumented internal API** of a government SPA. Its predecessor was removed without notice when the site was rebuilt. No ToS, unknown rate limit (429 exists). Risk: breakage or blocking at any time → isolate behind a provider abstraction and keep Stride/SIRI as fallback; consider e-mailing the NTA to ask for sanctioned use.
3. **Stride latency**: measured 12–18 min behind real time (ETL backlog), so it cannot animate a bus that is minutes away; it is the right source for stop/route/shape data, history and matching, and a degraded fallback ("last seen 14 min ago").
4. **Identifier churn** in Israel: GTFS `trip_id`, Stride `gtfs_stop.id`/`gtfs_route.id` change daily; stable keys are `stop_code`, `route_mkt`/`route_desc` and SIRI `line_ref` (= bus.gov.il `routeId`). SIRI↔GTFS ride matching is delayed (`siri_ride__gtfs_ride_id` null for live rides).
5. **Direction ambiguity**: "אלנבי ג" exists twice (41122 dir 2, 41117 dir 1) plus אלנבי א/ב variants on both sides; the UI must pick stop *code* + direction, not name.
6. **bus.gov.il positions carry no trip/vehicle id** (`GetRouteLocations` = bare lat/lng); the `Calendar` endpoint gives per-trip `routeLocation` + `stopOrder`, and `GetNextRouteLocation` gives the next-bus position for a stop, which is what we need — but combining them is heuristic.
7. **Worldwide**: the aggregators with vehicle positions (Transit app) have consumer-app-hostile quotas (1,500/month) or are enterprise-only (Moovit, Citymapper gone). Transitland/HERE/Navitia give ETAs but **no positions**. Practical worldwide positions = DIY GTFS-RT/SIRI-VM per region (needs backend polling, per-feed keys and terms, and no Israel).
8. **Keys in the iOS binary**: every keyed service (Transitland, HERE, BODS, Transit, 511) should be proxied; the only client-direct-safe ones are keyless (Stride, bus.gov.il, Entur with client-name header, TfL anonymous 50/min).
9. **Uptime/SLA**: none of the free sources (Stride, bus.gov.il, BODS, Entur) offer an SLA; the app must degrade to schedule-only gracefully.
10. Things I could not verify: gov.il SIRI application page (Cloudflare), Transit API terms page (404), Transitland RT docs page (404), HERE transit line-item pricing, Navitia/Digitransit quotas, Rejseplanen/NTA details, Swiftly public access, whether bus.gov.il enforces limits by IP/UA.

## 5. Architecture note — provider-agnostic data model

Entities the abstraction must expose (and the fields the progress bar actually consumes):

- **Stop**: `id` (provider-scoped), `code` (public sign number, e.g. 41122), `name` (localised map), `lat/lon`, `parentStation?`. Search by text and by radius.
- **Line** (GTFS route): `id`, `shortName` ("112"), `agency`, `longName/desc`.
- **RoutePattern / Direction**: the concrete ordered list of stops for one direction+variant of a line: `patternId` (IL: `route_desc` "13112-2-#" / SIRI `line_ref` 13389; GTFS: route_id+direction_id+shape_id; OBA: trip/shape; Transit: itinerary), `headsign`, `stops: [{stop, sequence, distAlongShape?}]`, `shape?: polyline`. Pattern is the unit the user actually selects ("112 toward Hof HaCarmel").
- **VehiclePosition**: `patternId`, `tripId?`, `vehicleId?`, `lat/lon`, `bearing?`, `recordedAt`, and the derived **`progress`**: either `distanceAlongPattern` (m) or `(lastStopSequence, fractionToNext)`. Providers give this in different ways: Stride `distance_from_journey_start` + `siri_ride_stop.order`; OBA `distanceAlongTrip`/`closestStop`; GTFS-RT `current_stop_sequence`/`current_status` (often absent → snap to shape); bus.gov.il bare lat/lng → snap to shape; SIRI-VM `MonitoredCall`/`ProgressBetweenStops` (absent in BODS).
- **Arrival (ETA)**: `stop`, `patternId`, `tripId?`, `scheduledAt?`, `expectedAt?`, `isRealtime`, `vehiclePosition?` (bus.gov.il and OBA attach the vehicle to the prediction; GTFS-RT TU and Transitland do not).
- **Alert**: optional.

Mismatches the abstraction must hide: (a) stable vs daily-churning ids (IL) → always key on `stop_code` + `route_desc`; (b) some providers return positions per line, some per trip, some per stop's next bus; (c) latency metadata (`recordedAt` must be shown as "as of N s ago" — Stride's 15 min vs bus.gov.il's 40 s); (d) progress computed server-side vs needing shape projection client-side (ship a `snapToPattern(lat,lon)` utility using stop-to-stop polylines or GTFS shapes with `shape_dist_traveled`); (e) direction semantics (GTFS `direction_id` 0/1 vs IL `1/2` vs SIRI `DirectionRef` vs headsign strings); (f) localisation (IL names in he/en/ar; en often null); (g) auth topology — keyless/CORS providers can be hit from the device, keyed ones go through our backend; (h) ETA sources that lack positions (HERE/Navitia/Transitland/TfL) can only drive a time-based bar, so the model should let `progress` be derived from `expectedAt` and average speed when no position exists.

## 1. Executive summary (final)

**Israel — top 3**
1. **api.bus.gov.il (mot-scheduler / route-planner, unofficial)** — the only keyless source with fresh (≤40 s) vehicle GPS *and* real-time ETAs *and* stop search *and* ordered route stops, all verified live for Haifa 112 / stop 41122; risk is that it is undocumented and could vanish.
2. **Open Bus Stride (hasadna)** — free, documented, keyless, has everything structurally (incl. `distance_from_journey_start`) but positions are 12–18 min stale; ideal for stop/route/shape lookups, history and as a degraded fallback.
3. **MOT SIRI directly (+ MOT GTFS)** — the sanctioned upstream, free, seconds-fresh, but requires an application with a whitelisted static IP → only viable once we run a backend; MOT GTFS (nightly) is the base for shapes and `stop_code`s regardless.

**Worldwide — top 3**
1. **DIY GTFS + GTFS-RT/SIRI-VM per region (discovered via Mobility Database)** — free, positions + ETAs, the only route that scales across countries (BODS England, Entur Norway, 511, MBTA, etc.), at the cost of a backend poller and per-feed onboarding.
2. **Entur (Norway) / OneBusAway regions / TfL** as exemplar client-direct-friendly regional APIs — keyless or generous limits, positions (Entur, OBA) or predictions (TfL), open licences; good first international markets.
3. **Transitland v2 (free 10k/mo → $200/mo)** — best for normalising static data and GTFS-RT departures worldwide, but it has no vehicle-position endpoint; Transit app's API has the perfect shape (`/v4/vehicles`) but 1,500 calls/month and no Israel make it a "call sales" option only.

**Not viable**: Moovit (enterprise), Citymapper (discontinued 2023), Google (no RT), HERE/Navitia (ETAs only, no positions).
