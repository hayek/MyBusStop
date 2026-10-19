import { DIGITS, type Agency, type ParamRule, type PathRule } from "./agencies";

/**
 * The web relay's whole surface: keyless agencies the web version (amirhayek.dev/MyBusStop/web)
 * cannot reach from a browser because their servers send no CORS headers. No key, no secret: the
 * relay only lets the page read what anyone can already fetch, through the same allowlist,
 * validation, caching and rate windows as the app's relay.
 *
 * Adding one is a table entry here; a keyed agency never belongs in this table.
 */

/** bus.gov.il names stops in Hebrew, English or Arabic, by the path. */
const LANGUAGE = /^(he|en|ar)$/;
/** What a rider types: letters in any script, digits, and the punctuation stop names use. */
const SEARCH_TERM: ParamRule = { pattern: /^[\p{L}\p{M}\p{N} '"׳״().,/-]+$/u, maxLength: 60, required: true };
/** The route's `routeDesc`, as `81001-1-0` (operator line id, direction, alternative). */
const ROUTE_DESC: ParamRule = { pattern: /^\d{1,6}-\d{1,2}-[0-9A-Za-z#]{1,3}$/, maxLength: 16, required: true };

/** A stop's lines and a route's stops change with the timetable, not by the minute. */
const STATIC_TTL = 3600;
/** Bus positions and arrivals: long enough to share one fetch between riders polling the same line. */
const LIVE_TTL = 10;

const scheduler = (name: string, path: string, params: Record<string, ParamRule>, ttlSeconds: number): PathRule => ({
  name,
  pattern: new RegExp(`^/mot-scheduler-prod/api/([a-z]{2})/${path}$`),
  segment: LANGUAGE,
  params,
  ttlSeconds,
});

export const WEB_AGENCIES: Record<string, Agency> = {
  /**
   * Israel — the JSON API behind route.bus.gov.il (BusGovILProvider in the app). Undocumented and
   * keyless, behind a firewall that blocks bursts, so answers are cached and the upstream budget is
   * kept low. Its nearby call (GetStopsCloseToLocation) is left out: it takes 30–60 s and 2 MB, so the
   * web finds nearby stops on Transitous and matches them here by name. No coordinates come through.
   */
  "bus-gov-il": {
    upstream: "https://api.bus.gov.il/prod",
    upstreamPerMinute: 240,
    paths: [
      {
        name: "search-stations",
        pattern: /^\/route-planner-prod\/api\/([a-z]{2})\/AutoComplete\/SearchStations$/,
        segment: LANGUAGE,
        params: { searchTerm: SEARCH_TERM },
        ttlSeconds: STATIC_TTL,
      },
      scheduler("stop-by-code", "Stops/GetStopByCode", { stopcode: { ...DIGITS(6), required: true } }, STATIC_TTL),
      scheduler("stop-full-data", "Stops/GetStopFullData", { stopCode: { ...DIGITS(6), required: true } }, STATIC_TTL),
      scheduler("route-stops", "Routes/GetRouteStops", { routeId: { ...DIGITS(8), required: true } }, STATIC_TTL),
      scheduler("route-locations", "Routes/GetRouteLocations", { routeId: { ...DIGITS(8), required: true } }, LIVE_TTL),
      scheduler(
        "route-calendar",
        "Calendar/GetRouteCalendarAtStopsByStopCodes",
        { stopCodes: { ...DIGITS(6), required: true }, routeDesc: ROUTE_DESC },
        LIVE_TTL,
      ),
    ],
  },
};

/** Pages allowed to call the web relay: the live site, and a local preview of it. */
export const WEB_ORIGINS = [
  "https://amirhayek.dev",
  "https://www.amirhayek.dev",
  "http://127.0.0.1:8770",
  "http://localhost:8770",
];
