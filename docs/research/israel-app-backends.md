# BusBus — What Israeli bus apps use as their real-time backend (and what we can use)

Research date: 2026-09-17 (live calls 13:55–14:35 UTC). Research only; no app code. Companion to `transit-apis.md` (which already covers api.bus.gov.il, Open Bus Stride, MOT GTFS, Moovit, Google, Transit app, Citymapper — not repeated here except where new facts changed the picture).

Legend: **[V]** verified from an official document, source code or a live call made today; **[I]** inferred from strong indirect evidence; **[U]** unverified.

Ethics line kept: only public web apps, their JS bundles, public API docs, open-source repos, store listings, privacy policies and forums were read. No app binaries were decompiled, no auth/bot-protection was bypassed, and no third-party keys are recorded here (one public repo contains a hard-coded MOT key; it is deliberately not reproduced).

---

## 1. Executive answer

**Every real-time number in every Israeli bus app comes from one upstream: the Ministry of Transport's SIRI-SM 2.8 service (`moran.mot.gov.il`).** There is no operator that publishes its own fleet GPS publicly; Egged, Dan, Nateev Express, Kavim, Metropoline, Superbus/Metronit, Tnufa, Electra Afikim and Extra all point passengers at third-party front-ends (HopOn/Bus Nearby, Moovit, or the government's own route.bus.gov.il). The "Egged app" (**egg**) is a HopOn white-label; Egged's website links line routes to busnearby.co.il. [V]

Ranked by usefulness to BusBus today:

1. **api.bus.gov.il (unofficial JSON of route.bus.gov.il)** — still the best zero-friction source: keyless, ≤40 s fresh GPS + `isRealTime` ETAs + ordered stops. No plate/speed/departure. Unofficial, no ToS. *(already documented in transit-apis.md; unchanged)*
2. **MOT SIRI-SM 2.8 directly** — the sanctioned source, now fully understood: one-page PDF form → e-mail `ptsupport@mot.gov.il` → key (`RequestorRef`/`Key`) bound to **one static IP**; free; liability-disclaimer-only terms (no commercial restriction, no attribution clause, no fee). Gives `VehicleRef` (= licence plate), `Velocity` (km/h), `Bearing`, `OriginAimedDepartureTime`, `RecordedAtTime`, `DistanceFromStop`, per-stop `ExpectedArrivalTime`, and a **per-line query (`MonitoringRef=all&LineRef=…`)** that returns every bus on a line with its position and next stop — exactly the progress-bar payload. Needs a backend with a static egress IP. **No occupancy, no accessibility** in SIRI (accessibility comes from GTFS `wheelchair_accessible`; occupancy does not exist anywhere).
3. **curlbus.app (public JSON front-end to MOT SIRI-SM)** — keyless, seconds-fresh, exposes `vehicle_ref`, `trip_id`, `departed` (aimed origin departure), `eta`, `location` per stop. Single-maintainer hobby service, no ToS/SLA → acceptable as a *development/verification* source and emergency fallback, not as the production backend.
4. **iBus Israel (`api.ibusisrael.online`)** — a new (2026) keyless FastAPI with a public OpenAPI that proxies MOT SIRI (it even leaks that it uses an MOT CA bundle) and adds GTFS enrichment (`wheelchair_accessible`, `route_distance_m`, `stops_remaining`, shape points). Rich, but anonymous (Gmail contact), its live poller was broken during testing (`stale:true`, `error: …mot_ca_bundle.pem`), and no ToS. Not a foundation.
5. **Open Bus Stride** — 12–20 min behind (re-measured today: snapshot 14:06 finished loading 14:26). History/reference only.
6. **Bus Nearby / HopOn / egg backend (`api.busnearby.co.il`, an OpenTripPlanner instance)** — **no**: since 2025 the API requires a Cloudflare-Turnstile-issued session token (`403 {"error":"Missing session token"}` on every data call today). Defeating that is out of bounds.
7. **Moovit, Google Maps, Transit, Kavim's Moovit widget** — no usable API (enterprise / none / no Israel).

**Bottom line for BusBus:** keep api.bus.gov.il as provider #1 in the client; build a small backend with a static IP and apply for MOT SIRI-SM (that is the *only* route to plate/speed/aimed-departure with legitimacy); use curlbus as the dev-time reference/fallback; use MOT GTFS for accessibility and shapes.

---

## 2. Comparison table

| App / source | Backend / data source | Endpoint visibility | Auth | Fields (GPS / plate / speed / departures / accessibility / ETA) | Freshness | Usable by us? | Risk |
|---|---|---|---|---|---|---|---|
| **MOT SIRI-SM 2.8** (`moran.mot.gov.il/Channels/HTTPChannel/SmQuery/2.8/{json,xml}`) | Ministry real-time server fed by every operator's AVL (+ Israel Railways VM) | Fully documented (ICD-SM 2.8, FAQ) [V] | `Key=` + **static-IP allow-list** [V] | GPS ✓, plate ✓ (`VehicleRef` = licence no.), speed ✓ (`Velocity` km/h) + `Bearing`, aimed origin departure ✓, accessibility ✗, occupancy ✗, ETA ✓ (`ExpectedArrivalTime`, `DistanceFromStop`, OnwardCalls) | seconds (`RecordedAtTime` per vehicle) | **Needs backend** (static IP) | Low legal (signed form, free); medium ops (TLS chain incomplete, IP change by e-mail) |
| **api.bus.gov.il** (route.bus.gov.il / Kol Kav *8787 web) | MOT SIRI + GTFS inside the National PT Authority's own SPA | Internal, undocumented, readable from JS [V] | none [V] | GPS ✓ (bare lat/lng), plate ✗, speed ✗, departures ✗ (static trip id only), accessibility ✗, ETA ✓ (`minutesToArrival`, `isRealTime`) | ≤40 s [V] | **Client-direct (today)** | No ToS; predecessor API was removed without notice; 429 exists |
| **curlbus.app** | MOT SIRI-SM (author's own key) + MOT GTFS | Open-source, JSON via `Accept: application/json` [V] | none [V] | GPS ✓, plate ✓ (`vehicle_ref`), speed ✗ (not surfaced), aimed departure ✓ (`departed`), accessibility ✗, ETA ✓ | seconds (per-visit `timestamp` = SIRI RecordedAtTime) [V] | Client-direct technically; **dev/fallback only** | Hobby service, one maintainer, no ToS/SLA, no rate limit stated |
| **iBus Israel** (`api.ibusisrael.online`) | MOT SIRI-SM (own key) + GTFS + OTP | Public Swagger/OpenAPI [V] | none (debug routes 403) [V] | GPS ✓, plate ✓, speed ✓, bearing ✓, aimed departure ✓, `wheelchair_accessible` ✓ (GTFS), ETA ✓, `route_distance_m`, `stops_remaining`, shape | seconds when working; **live poller broken today** (`stale:true`) [V] | Client-direct technically; **not a foundation** | Anonymous operator, no ToS, unstable |
| **Open Bus Stride** (hasadna) | MOT SIRI snapshots every minute + GTFS | Public OpenAPI [V] | none | GPS ✓, plate ✓, speed ✓, bearing ✓, aimed departure ✓, accessibility ✗, ETA ✗ | **12–20 min lag** [V today] | Client-direct; reference/history only | Community DB, ETL stalls |
| **Bus Nearby / HopOn Rav-Pass / egg (Egged)** | HopOn's OpenTripPlanner (`api.busnearby.co.il/directions/index/...`) fed by MOT SIRI+GTFS | Paths visible in JS/open-source clients [V] | **Cloudflare Turnstile → session token required** [V] | (OTP stoptimes: `realtimeArrival`, wheelchair; vehicle fields unknown) | real-time (OTP RT) | **No** (would require defeating bot protection) | — |
| **Moovit** (also Kavim's site widget, Superbus/Metronit links) | MOT SIRI + GTFS, Moovit's own servers | Not public | enterprise only | Live location in-app (subscription-gated per 2025–26 reviews) | seconds | **No** | — |
| **Google Maps Israel** | MOT via Google Transit Partner Program (schedule; real-time intermittently) | none | none | schedule; live data reported missing since early 2024 | — | **No** | — |
| **Transit app** | not in Israel [V] | — | — | — | — | **No** | — |
| **Efobus (איפה בוס)**, **Wimb**, **Bus Realtime (Arad Seroussi)** | MOT SIRI (each holds its own key) [V for Efobus ToS, I for others] | Private app backends | private | in-app only | seconds | **No** | — |
| **Telegram @ilbusbot / benyaming API** (`api.ginzburg.io/il_transport`) | MOT SIRI via author's key + GTFS | Public OpenAPI (`/siri/get_routes_for_stop/{code}`) [V] | none | ETAs + vehicle location per stop | seconds | Hobby; fallback at most | No ToS, personal server |
| **Operators' own sites** (Egged, Dan, Nateev, Kavim, Metropoline, Superbus, Metronit, Tnufa, Electra Afikim, Extra) | None of their own; they embed/link Bus Nearby, Moovit or route.bus.gov.il [V] | — | — | — | — | **No operator-level API exists** | — |
| **Light rail (Dankal/Tevel, Cfir/JLR), Metronit** | In MOT SIRI/GTFS like buses (JLR excluded from SIRI as of the 2017 FAQ [U whether still true]); Dankal/Cfir sites have no public API | — | — | — | — | Covered via MOT/bus.gov.il | — |

---

## 3. Per-app findings

### 3.1 Egged — website, "egg" app, and the Egged↔HopOn relationship

- **egged.co.il** (fetched today, 458 KB SSR page): the line tables on the site link every "מסלול הקו" to **`https://busnearby.co.il/route/1:<routeId>:<dir>:<alt>`** (e.g. `1:7361:0:01`, `1:19669:0:01`). Egged's site has **no own "where is my bus" feature**; its only real-time-ish copy is marketing ("בנינו מערכות עדכון בזמן אמת, שילוט חכם ואפליקציות מידע לנוסעים"). Backend hosts seen: `contentapi.egged.co.il` (Umbraco CMS media), `reserved-seats.egged.co.il` (Eilat seat booking), an internal `egged-umbarco-graphql-graphql-service`. Nothing that serves vehicle positions. [V]
- **egg – תחבורה ציבורית** (App Store id 6751158990, Google Play `com.egged.egg`), seller EGGED TRANSPORTATION COMPANY LTD, v3.0.1 (20 Aug 2025). Store listing: real-time arrivals, Live Activities (v2.9.7), Rav-Kav loading, Apple Pay. **Support contact is `support@hopon.co.il`** [V]. Egged's privacy policy (dated 29/06/2026) says validation/loading is "provided by an operator authorised by the Ministry of Transport – HopOn", and that some services are supplied by Moovit (Call Bus) [V]. HopOn's own site lists "white-label apps for operators like Egged" as a product [V]. Reviewers note egg and HopOn "look and operate very much the same" (Backpack Israel, updated 12 Sep 2026) [V]. ⇒ **egg = HopOn Rav-Pass white-label; its real-time backend is HopOn's (see 3.3).** [V/I]
- Egged does run its own AVL/fleet system (feeds MOT SIRI as operator_ref 3), but nothing is exposed publicly. [I]
- Usable by us: **no** (no public endpoint of Egged's own).

### 3.2 Dan, Nateev Express, Kavim, Metropoline, Superbus/Metronit, Tnufa, Electra Afikim, Extra

All fetched today; external hosts grepped from each homepage. [V]

| Operator | What the official site uses for trip planning / real-time |
|---|---|
| **Dan** (dan.co.il, Webflow) | Embeds **Bus Nearby**: `busnearby.co.il/plan`, `busnear.by/plan`, geocoding via `api.busnear.by/geocode`; links bus.gov.il. No own API. |
| **Nateev Express** (nateevexpress.com) | Embeds **Bus Nearby** (`api.busnearby.co.il`, `busnear.by`), plus an Entagy-hosted line-info site and a chatbot (`bot.nateevexpress.com`, botica.cloud). |
| **Kavim** (kavim-t.com) | **Moovit** widget (`widgets.moovit.com/ws/fp/...`) and links to moovit.com; Rav-Kav Online. |
| **Metropoline** (metropoline.com) | Links to **route.bus.gov.il** (the government planner) for trip planning. |
| **Superbus / Metronit** (superbus.co.il, metronit.co.il) | Links to **moovitapp.com** and the legacy `bus.co.il/otobusimmvc` timetable site; Metronit site is a Superbus page. |
| **Tnufa** (tnufa-t.com) | Own line list/timetables; real-time → links to **bus.gov.il** / *8787. |
| **Electra Afikim** (electra-afikim.co.il, WordPress) | Line info on an Entagy-hosted subsite; no real-time host. |
| **Extra** | No website found (Instagram only, *6747). |

Conclusion: **no operator publishes fleet GPS or ETAs**; the three sanctioned consumer front-ends are HopOn (Bus Nearby/Rav-Pass/egg), Moovit, and the MOT's route.bus.gov.il. Operator-level real-time with extra fields (plate/accessibility/occupancy) does not exist publicly. [V]

### 3.3 Bus Nearby (אוטובוס קרוב) / HopOn Rav-Pass — `api.busnearby.co.il`

- Publisher: **HopOn Mobility LTD** (App Store 580298535; Android `com.mosko.bus` — the original author's package; the Mapbox style owner in the bundle is `nadavmos`). HopOn is the MOT-licensed payment/validation operator; Rav-Pass's site links `busnear.by/plan` for its planner. [V]
- Web app `busnearby.co.il` = React SPA (`/static/js/main.bb12545f.js`, 1.5 MB, fetched). Config block: `{"api":{"host":"https://api.busnearby.co.il","path":"/directions","plan":"/plan"},"app":{"host":"https://app.busnearby.co.il"},"homeTimezone":"Asia/Jerusalem",…,"geocoder":{"type":"NOMINATIM","bnbBaseUrl":"https://api.busnearby.co.il"},"routingTypes":[{"key":"ITINERARY"}]}` — this is an **otp-react-redux/OTP-UI config**, i.e. the backend is **OpenTripPlanner**. Open-source clients (t0mer/py-busnearby, ziv-daniel HA integration, EladDv/BusPebbIL, Shmuelmb/busnearby-mcp) call the OTP 1.x index API: `GET api.busnearby.co.il/directions/index/stops/1:{stop_id}/stoptimes?numberOfDepartures=…&timeRange=…&startTime=…` → `times[].realtimeArrival`, `serviceDay`, `routeShortName`; stop search `app.busnearby.co.il/stopSearch?query=41122&locale=he` → `{"stop_id":"2005","stop_code":"41122",…}`. [V]
- **Auth today**: the bundle mounts an invisible **Cloudflare Turnstile** (`siteKey 0x4AAAAAADhrK1cSXbUmuKoP`) and POSTs its token to `api.busnearby.co.il/_auth/verify` to obtain a `sessionToken`. Live check (14:2x UTC): `stopSearch` still answers keyless, but `/directions/index/stops/1:2005/stoptimes`, `/routes`, `/stops/{id}` all return **`403 {"error":"Missing session token"}`**. The 2024-era open-source clients are therefore broken. [V]
- Fields: OTP real-time stop times; whether vehicle positions are exposed (OTP2 `vehiclePositions`) could not be observed without a session. Accessibility strings ("Wheelchair accessibility", `ROUTE_OPTIONS_ACCESSIBLE`) exist in the UI. [V/U]
- Usable by us: **No.** Obtaining a session token requires solving Turnstile from a browser context; automating that is defeating bot protection. ToS: none published for the API; Bus Nearby/HopOn are commercial products.

### 3.4 MOT National PT Authority — route.bus.gov.il / Kol Kav *8787 / api.bus.gov.il

- Unchanged from transit-apis.md §3.1.4 (keyless, ≤40 s). New today: the gov.il developers page (read via a text-reader proxy because gov.il blocks direct fetches) confirms MOT's three public layers are **GTFS, special notices, and SIRI-SM** — the JSON API behind route.bus.gov.il is *not* listed as a developer offering, confirming its unofficial status. [V]
- The HA integration `ziv-daniel/hass-israel-transportation-integration` documents the same endpoints and notes the old `bus.gov.il/WebApi/api/passengerinfo` API "were removed when the portal was rebuilt". [V]
- ToS: none found on route.bus.gov.il (SPA has no terms route) or bus.gov.il footer. [V]

### 3.5 curlbus.app (elad661/curlbus)

- Live today: `curl -H 'Accept: application/json' https://curlbus.app/41122` → per-visit `{"producer":"SIRI","timestamp":<RecordedAtTime>,"line_name":"112","route_id":"13389","direction_id":"2","operator_id":"3","vehicle_ref":"23323702","trip_id":"14957591_170926","departed":"2026-09-17 16:50:00+03:00","eta":"…17:34:00+03:00","location":{"lat":"32.813789","lon":"35.000546"},"static_info":{route, agency, destination…}}`. Response `timestamp` equalled wall-clock (17:32:31+03:00 at 14:32:31 UTC); other visits carried RecordedAtTime 20–40 s old. Also `/operators`, `/<operator>/<route>` endpoints. [V]
- README: needs MOT SIRI-SM access; "having your application reviewed can take very long time, and… requires your IP to be added to the whitelist, which means you have to have a static IP. Not great for cloud deployments." Source shows the `Key` param and fields used (`VehicleRef`, `ExpectedArrivalTime`, `OriginAimedDepartureTime`, `RecordedAtTime`). [V]
- Useful side-observation: bus 23323702 had the *same* SIRI RecordedAtTime (16:58:06+03) 34 min later while others were fresh → MOT data contains individually stale vehicles; any UI must show "as of N s ago" per vehicle.
- Usable: client-direct technically (no key, JSON, CORS not tested). ToS: none; hobby. **Dev/fallback only.**

### 3.6 iBus Israel — `ibusisrael.online` / `api.ibusisrael.online` (new, 2026)

- React SPA + FastAPI. Public Swagger at `/docs`, OpenAPI at `/openapi.json` (`"title":"iBus Israel API","version":"0.1.0"`, **no securitySchemes**). Endpoints include `/v2/stop/{stop_code}/arrivals`, `/bus/{vehicle_ref}`, `/v2/vehicle/{vehicle_ref}/monitoring`, `/line/{line_ref}` (buses by line), `/buses_all?bbox=`, `/line/{line_ref}/stops`, `/line/{route_id}/shape`, `/stop/{code}` (with tariff), `/routes/plan`, `/otp/plan`, `/alerts`, `/debug/rt_stats` (403). UI strings: "Live trip data (SIRI)", "Vehicle #", "Trip #", "Live data from Israel Ministry of Transport feeds". Contact in bundle: `ibus.israel@gmail.com`. (A web search wrongly attributes it to Hasadna; nothing on the site says so — treat operator as unknown.) [V]
- Live call `GET /v2/stop/41122/arrivals` (2.3 s): `{"stopId":"41122","updatedAt":"…14:31:16Z","stale":true,"source":"legacy_realtime","error":"Could not find a suitable TLS CA certificate bundle, invalid path: /home/ibus_app/ibus/backend/live_api/mot_ca_bundle.pem","arrivals":[{"vehicle_ref":"23323702","line_ref":"13389","route_short_name":"112","agency_id":"3","direction_ref":"2","dated_vehicle_journey_ref":"14957591","data_frame_ref":"2026-09-17","confidence_level":"probablyReliable","call_order":40,"distance_from_stop_m":0,"latitude":32.813789,"longitude":35.000546,"bearing":152.0,"velocity":0.0,"motion":"stopped","origin_aimed_departure_utc":"2026-09-17T13:50:00+00:00","expected_arrival_utc":"…14:34:00+00:00","expected_in_min":2,"route_distance_m":3322,"wheelchair_accessible":1,"stops_remaining":34}, …]}`. `/bus/23323702` adds `shape_points` (1,350), `route_stops` (67), `next_calls`, `delay_min`, `gtfs_shape_id`. `/line/13389` and `/buses_all` returned `[]` and `buses_stats` showed `active_buses:0` — the map poller was down. [V]
- So: **it is a keyless proxy of MOT SIRI-SM with GTFS enrichment**, richest field set of anything public (plate, speed, bearing, aimed departure, wheelchair flag, distance along route). But: anonymous, broken at test time, `recorded_at_utc` is the proxy's fetch time rather than SIRI's RecordedAtTime (it reported 14:31:42 for a vehicle curlbus showed frozen since 13:58), no ToS, and its own MOT key is on a static IP we don't control.
- Usable: technically client-direct; **do not build on it**. Worth watching / contacting the author.

### 3.7 Open Bus Stride (hasadna) — re-measured

- `siri_snapshots/list?snapshot_id_prefix=2026/09/17/14` at 14:29:02 UTC: snapshot `14/06` finished loading 14:26:25, `14/07` at 14:28:03, `14/08` loading → **~20 min ETL lag**, ~8,460 vehicle locations per minute-snapshot. Same conclusion as before: reference/history only. [V]
- Ecosystem built on it: `@skills-il/openbus-mcp` (agentskills.co.il), hasadna/open-bus-map-search. [V]

### 3.8 Moovit (and Kavim/Superbus via Moovit)

- Israel data = MOT SIRI + GTFS on Moovit's servers [I, consistent with all evidence]. Live-location feature launched Nov 2022 in 220+ cities; in Israel it is reported as **subscription-gated** by a Sept-2026 review ("requires paid subscription to access… real-time bus location tracking on maps"). Moovit also sells real-time to operators (TimePro). No self-serve API (transit-apis.md §3.1.7). **No.** [V/I]

### 3.9 Google Maps Israel

- Transit directions launched April 2013 with MOT + Israel Railways, explicitly **without real-time** at launch. Google's help says some Israeli stops show real-time departures. A June 2024 Google-community thread ("Google Maps not showing live bus location information in Israel") reports live info vanished "in the last few months"; Google's answer: the transit authority supplies data through the Transit Partner Program. ⇒ MOT feeds Google privately (GTFS-RT style) and it is intermittent; **no API for us.** [V for thread/launch, I for the private feed]

### 3.10 Transit app — not available in Israel (regions page, verified in transit-apis.md). **No.** [V]

### 3.11 Efobus (איפה בוס), Wimb, Bus Realtime

- **Efobus** (efobus.com, `il.co.mitug.WhereBus`): ToS says "איפה בוס עושה שימוש במידע המתקבל ממשרד התחבורה"; features live bus map, Bluetooth-based crowding estimate (its own heuristic, not MOT occupancy). Private backend. [V]
- **Wimb** (Barak Kind), **Bus Realtime** (Arad Seroussi, last update 2018): MOT SIRI holders with private backends. [I]
- Usable: **no**.

### 3.12 Telegram / bots / hobby APIs

- `benyaming/israel_bus_info_bot` (@ilbusbot) is built on `benyaming/israel-public-transport-api`, publicly hosted at `https://api.ginzburg.io/il_transport` (OpenAPI 0.1.1, no auth): `/siri/get_routes_for_stop/{stop_code}`, `/stop/near`, `/route/available_for_stop/{code}`, plus an MCP endpoint. Backed by the author's MOT SIRI key. Hobby; fallback at most. [V]
- WhatsApp bots listed on Haredi tech forums (e.g. "Robotomat") wrap the same sources. [U]
- `better-rail` (open-source Israel Railways app) also obtained MOT SIRI-SM access for train delays and documents the constraints (IP allow-list, poller as a separate service, incomplete TLS chain of moran.mot.gov.il). [V]

### 3.13 Light rail & BRT

- MOT SIRI FAQ (Sept 2017): SIRI covers all operators "except the Jerusalem light rail"; trains get ETAs but no location. Whether JLR (now Cfir) is included in 2026 is unverified [U]. Dankal (dankal.co.il) and Cfir (cfir.co.il, `api.cfir.co.il` returns 404 at root) publish no API; HopOn/Moovit show light-rail real-time, and bus.gov.il's API covers "bus, light rail" per the HA integration. Metronit = Superbus/Moovit links. [V/I]

---

## 4. MOT SIRI-SM access — how-to (as verified as it gets)

Sources: gov.il developer page "מידע בזמן אמת – ממשק למפתחים" (read today via a reader proxy), the request form PDF, the FAQ PDF (Sept 2017), ICD-SM 2.8 (sub-version 32) PDF, plus curlbus/better-rail/hasadna source code.

1. **What is offered**: SIRI-SM (Stop Monitoring) only, for developers. (SIRI-VM exists only as the *operator→MOT* upload interface, e.g. the Israel Railways VM ICD; it is not offered to developers.) Data covers buses and trains "up to 4 hours before planned departure": predicted arrival, current vehicle location (once the trip has started; not for trains), line number, trip_id, **vehicle number**. [V]
2. **Form**: `https://www.gov.il/BlobFolder/generalpage/real_time_information_siri/he/real_time_information_receipt_form.pdf` — one page: applicant name, **corporation name & number**, e-mail, phone, mobile, **static IP ("אנא פנה לספק התקשורת שלך לצורך קבלת IP סטטי")**, purpose of use (free text), signature + ID number. [V]
3. **Terms on the form**: liability disclaimer only ("המשרד לא יחויב ולא יישא בכל אחריות…", no accuracy warranty). **No fee, no commercial-use restriction, no attribution requirement, no rate limit** stated. [V] (A 2015 forum post mentions ~1,500 queries/minute as the practical cap [U].)
4. **Send** the signed form to **ptsupport@mot.gov.il**; the reply contains a user code used as `Key=` (HTTP) / `RequestorRef` (SOAP). To change the IP later, e-mail the same address (FAQ Q10b). [V]
5. **Turnaround**: not published. curlbus: "can take very long time" [V]; individuals have succeeded (curlbus author, Better Rail, several student projects on GitHub) even though the form asks for a corporation [I].
6. **Endpoint** (ICD 2.8): `https://moran.mot.gov.il/Channels/HTTPChannel/SmQuery/2.8/{json|xml}?Key=<key>&MonitoringRef=<stop_code[,…]>[&LineRef=<line_ref>][&PreviewInterval=PT45M][&StartTime=…][&StopVisitDetailLevel=normal|calls][&MaximumStopVisits=n][&MaximumStopVisitsPerLine=n]`; alternate host `moran-t.mot.gov.il`. Only one parameter may be multi-valued. Special `MonitoringRef` values: **`all` + `LineRef=…` → all stops of a line** (every active bus on the line with its current stop/position), `AllActiveTripsFilter` (national snapshot, what hasadna polls every 60 s), `AllPlannedTripsFilter`. The 2017 SOAP endpoint `siri.motrealtime.co.il:8081/Siri/SiriServices` (2.7) is legacy. Note: moran.mot.gov.il serves an incomplete TLS chain — pin the CA (Better Rail) or hasadna's `verify=False`. [V]
7. **Response fields** (ICD 2.8 table for `normal`/`calls`/planned): `RecordedAtTime` (time the vehicle recorded the position), `LineRef`, `DirectionRef` (1/2/3), `OperatorRef`, `FramedVehicleJourneyRef{DataFrameRef, DatedVehicleJourneyRef}` (→ GTFS trip via TripIdToDate), `PublishedLineName`, `OriginRef`, `DestinationRef`, **`OriginAimedDepartureTime`**, `ConfidenceLevel`, **`VehicleLocation{Longitude,Latitude}`**, **`Bearing`** (0–360), **`Velocity`** (km/h), **`VehicleRef`** ("Vehicle number. The value should match the license number of the Vehicle (מספר רישוי)"), `MonitoredCall{StopPointRef, Order, ExpectedArrivalTime, DistanceFromStop}`, `OnwardCalls[]{StopPointRef, Order, ExpectedArrivalTime, ArrivalStatus}`. **Not present: occupancy, accessibility, driver, delay reason.** Accessibility must come from GTFS (`trips.txt wheelchair_accessible`, see §5 note); occupancy is not available from any Israeli source. [V]
8. **Architecture implication**: a backend with a fixed egress IP (small VPS or cloud NAT) polls either `MonitoringRef=all&LineRef=X` for lines users are watching, or the national `AllActiveTripsFilter` snapshot (≈8.5k vehicles/min, JSON, gzip) and serves the app. Hasadna's pattern (SSH tunnel through the whitelisted host) shows the IP can be a tiny proxy box. [V]

---

## 5. Recommendation for BusBus

1. **Keep `api.bus.gov.il` as provider #1** (client-direct) — nothing keyless is fresher or more legitimate-looking; wrap it behind the provider abstraction with "as of N s ago" and a schedule-only fallback.
2. **Add a `SIRIProvider` behind our own backend** — apply for MOT SIRI-SM now (form + `ptsupport@mot.gov.il`; get a static IP first, e.g. a €5 VPS or a cloud NAT gateway). Poll `MonitoringRef=all&LineRef=<line_ref>` every 15–30 s per watched line (or the national snapshot every 60 s) and expose to the app: position, bearing, speed, plate (`VehicleRef`), aimed origin departure, next stop `Order` + `DistanceFromStop`, per-stop ETA. Join GTFS nightly for shapes/`shape_dist_traveled` and `wheelchair_accessible`. This is the only path to the "per-bus details" in the brief with a signed, free, commercial-OK licence. Backend requirement: static IP, ~1 small VM, Redis, nightly GTFS ETL (212 MB).
3. **Use curlbus JSON in development** to validate our SIRI parsing/ETAs (same upstream, seconds-fresh, has plate + aimed departure), and optionally as an emergency read-only fallback with a "community source" label — never as the sole production source.
4. **Do not integrate** Bus Nearby/HopOn/egg (Turnstile-gated), Moovit, Google, Transit, or any operator site (they have nothing of their own). Treat iBus Israel and the ginzburg.io API as watch-list items only.
5. **Stride** stays for history, ride matching and analytics.
6. Occupancy: not obtainable; don't promise it. Accessibility: from GTFS only — verified today by range-reading the live MOT zip (188 MB, dated 04/10/26 trip ids): `trips.txt` header is `route_id,service_id,trip_id,trip_headsign,direction_id,shape_id,wheelchair_accessible` (per-trip flag, `1` on the sampled rows) [V]. Join SIRI `DatedVehicleJourneyRef` + `DataFrameRef` → GTFS `trip_id` to show it per bus. data.gov.il has **zero** SIRI/real-time datasets (`package_search?q=siri` → 0) [V], so there is still no public GTFS-RT/SIRI mirror as of 2026-09-17.

---

## 6. Evidence URLs

- gov.il SIRI developers page: https://www.gov.il/he/pages/real_time_information_siri (Cloudflare-blocked to bots; text read via r.jina.ai) · form: …/real_time_information_receipt_form.pdf · FAQ: …/siri-faq_1.pdf · ICD-SM 2.8: …/ICD_SM_28_32.pdf · operator VM ICD (Israel Railways): https://www.gov.il/BlobFolder/generalpage/real_time_information_operator_interface/he/ICD%20VM%203.34R%20Israel%20Railway.pdf
- hasadna/open-bus-siri-requester `requester.py` (endpoint template, SSH-tunnel proxy), open-bus-siri-etl `process_snapshot.py` (fields parsed)
- elad661/curlbus README + `curlbus/siri.py`; live: https://curlbus.app/41122
- better-rail/app `apps/server/README.md`, `src/siri/client.ts`, `.env.example`
- busnearby.co.il `/static/js/main.bb12545f.js`; t0mer/py-busnearby; ziv-daniel/hass-israel-transportation-integration (`const.py`, README); EladDv/BusPebbIL; Shmuelmb/busnearby-mcp
- egged.co.il homepage (busnearby links), egg App Store id6751158990, https://www.egged.co.il/embed/privacy, https://hopon.co/about-us/, https://backpackisrael.com/public-transport-apps-israel/
- dan.co.il, nateevexpress.com, kavim-t.com, metropoline.com, superbus.co.il, metronit.co.il, tnufa-t.com, electra-afikim.co.il (homepage host greps)
- https://api.ibusisrael.online/openapi.json, /v2/stop/41122/arrivals, /bus/23323702
- https://api.ginzburg.io/il_transport/openapi.json; benyaming/israel_bus_info_bot
- forum.hasadna.org.il/t/siri/1094 (2015 IP-whitelist, 1,500 req/min), tchumim.com/topic/17357 (Jan 2026), tapuz thread 14267408 (2014)
- Google: support.google.com/maps/thread/278589930 (June 2024); Israel Hayom/Haaretz April 2013 launch
- Efobus ToS: https://www.efobus.com/termsofuse-ios-heb.html
