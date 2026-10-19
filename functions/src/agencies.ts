/**
 * The whole surface this proxy exposes: one table entry per agency, one row per upstream path.
 *
 * Nothing outside this table is reachable. The client names an agency and a path; the path must
 * match one of that agency's patterns exactly, only the listed query parameters are forwarded (each
 * checked against a value pattern and a length cap), and the upstream host is ours to choose, never
 * the caller's. That is what keeps a leaked App Check token from turning this into an open proxy
 * or into a way to spend our key on queries the app never makes.
 *
 * Adding an agency (WMATA, CTA, …) is a table entry here plus a `defineSecret` in `config.ts`.
 */

/** How the key reaches the upstream. */
export type KeyInjection =
  | { kind: "query"; name: string }
  | { kind: "header"; name: string; prefix?: string };

export interface ParamRule {
  /** The value must match (whole string). */
  pattern: RegExp;
  /** Hard cap on the value's length, checked before the pattern. */
  maxLength: number;
  /** A request without it is refused (400). */
  required?: boolean;
}

export interface PathRule {
  /** A stable name for logs and tests. */
  name: string;
  /**
   * Matched against the path after the agency (`/siri/vehicle-monitoring.json`). Each capture
   * group is one path segment, decoded, validated by `segment`, and re-encoded canonically.
   */
  pattern: RegExp;
  /** Every captured segment must match this once decoded. */
  segment?: RegExp;
  params: Record<string, ParamRule>;
  /** Seconds a 2xx answer is served from memory and advertised in `Cache-Control`. */
  ttlSeconds: number;
}

export interface Agency {
  /** The upstream base, with no trailing slash. Paths are appended to it. */
  upstream: string;
  /** The name of the secret holding the key; resolved by the caller (see `config.ts`). Absent for a keyless agency. */
  secretName?: string;
  key?: KeyInjection;
  /** Headers the upstream always gets, whatever the client sent. */
  headers?: Record<string, string>;
  paths: PathRule[];
  /** Upstream fetches (cache misses) this instance may make per minute for this agency. */
  upstreamPerMinute: number;
}

export const DIGITS = (max: number): ParamRule => ({ pattern: /^\d+$/, maxLength: max });
export const COORD: ParamRule = { pattern: /^-?\d{1,3}(\.\d{1,12})?$/, maxLength: 20, required: true };
/** MTA identifiers: `MTA NYCT_M15`, `MTA_401234`, `MTABC_Q53+`. */
const MTA_REF = (required = false): ParamRule => ({
  pattern: /^[A-Za-z0-9 _+.-]+$/,
  maxLength: 48,
  required,
});
const DIRECTION: ParamRule = { pattern: /^[01]$/, maxLength: 1 };
const OPERATOR: ParamRule = { pattern: /^MTA$/, maxLength: 3 };

const STATIC_TTL = 3600;

/** OneBusAway ids: `<agency>_<id>`, as in `1_11133` (a stop) or `40_100479` (a route). */
const OBA_ID = /^\d{1,4}_[A-Za-z0-9.-]{1,40}$/;
const BOOL: ParamRule = { pattern: /^(true|false)$/, maxLength: 5 };
/**
 * Sound Transit's terms ask for "the most current Data available": live answers are held only long
 * enough to share one fetch between riders polling the same line within a few seconds.
 */
const LIVE_TTL = 10;

/**
 * The OneBusAway where-API paths `OneBusAwayProvider` sends, shared by every OBA region. Vehicles
 * are only ever asked for one route at a time (`trips-for-route`), never the whole fleet
 * (`vehicles-for-agency`).
 */
const OBA_PATHS: PathRule[] = [
  {
    name: "where-search-stop",
    pattern: /^\/where\/search\/stop\.json$/,
    params: { input: { pattern: /^[\p{L}\p{N} &'.,\/()#-]+$/u, maxLength: 64, required: true } },
    ttlSeconds: STATIC_TTL,
  },
  {
    name: "where-stop",
    pattern: /^\/where\/stop\/([^/]+)\.json$/,
    segment: OBA_ID,
    params: {},
    ttlSeconds: STATIC_TTL,
  },
  {
    name: "where-stops-for-location",
    pattern: /^\/where\/stops-for-location\.json$/,
    params: {
      lat: COORD,
      lon: COORD,
      radius: DIGITS(5),
      query: { pattern: /^[A-Za-z0-9-]+$/, maxLength: 16 },
    },
    ttlSeconds: STATIC_TTL,
  },
  {
    name: "where-stops-for-route",
    pattern: /^\/where\/stops-for-route\/([^/]+)\.json$/,
    segment: OBA_ID,
    params: { includePolylines: BOOL, version: { pattern: /^2$/, maxLength: 1 } },
    ttlSeconds: STATIC_TTL,
  },
  {
    name: "where-trips-for-route",
    pattern: /^\/where\/trips-for-route\/([^/]+)\.json$/,
    segment: OBA_ID,
    params: { includeStatus: BOOL, includeSchedule: BOOL },
    ttlSeconds: LIVE_TTL,
  },
  {
    name: "where-arrivals-and-departures-for-stop",
    pattern: /^\/where\/arrivals-and-departures-for-stop\/([^/]+)\.json$/,
    segment: OBA_ID,
    params: { minutesBefore: DIGITS(2), minutesAfter: DIGITS(3) },
    ttlSeconds: LIVE_TTL,
  },
];

/** HAFAS ReST stop ids (`200405036`). */
const HAFAS_ID: ParamRule = { pattern: /^\d{1,12}$/, maxLength: 12, required: true };
const JSON_FORMAT: ParamRule = { pattern: /^json$/, maxLength: 4, required: true };
/** Departures move by the minute; a few seconds is enough to share one fetch between riders. */
const HAFAS_LIVE_TTL = 15;

/** A station's bus and tram departures, as `HafasProvider.board` asks for them. */
const HAFAS_DEPARTURE_BOARD: PathRule = {
  name: "departureBoard",
  pattern: /^\/departureBoard$/,
  params: {
    id: HAFAS_ID,
    duration: DIGITS(3),
    maxJourneys: DIGITS(3),
    products: DIGITS(5),
    passlist: { pattern: /^[01]$/, maxLength: 1 },
    format: JSON_FORMAT,
  },
  ttlSeconds: HAFAS_LIVE_TTL,
};

export const AGENCIES: Record<string, Agency> = {
  /**
   * MTA Bus Time, New York. Paths and parameters are exactly what `MTABusTimeProvider` sends.
   *
   * MTA revokes keys that fetch vehicle data for the whole system "at less than 30 second
   * intervals": VehicleMonitoring therefore requires a `LineRef` (never the whole fleet) and is
   * cached for 30 s, so however many riders watch a line, MTA sees that line at most twice a minute
   * per instance.
   */
  mta: {
    upstream: "https://bustime.mta.info/api",
    secretName: "MTA_BUSTIME_KEY",
    key: { kind: "query", name: "key" },
    // The where API parses numbers by Accept-Language; under he-IL a negative longitude is a 400.
    headers: { "Accept-Language": "en-US" },
    upstreamPerMinute: 300,
    paths: [
      {
        name: "siri-vehicle-monitoring",
        pattern: /^\/siri\/vehicle-monitoring\.json$/,
        params: {
          LineRef: MTA_REF(true),
          DirectionRef: DIRECTION,
          VehicleMonitoringDetailLevel: { pattern: /^(minimum|basic|normal|calls)$/, maxLength: 7 },
          OperatorRef: OPERATOR,
        },
        ttlSeconds: 30,
      },
      {
        name: "siri-stop-monitoring",
        pattern: /^\/siri\/stop-monitoring\.json$/,
        params: {
          MonitoringRef: MTA_REF(true),
          LineRef: MTA_REF(),
          DirectionRef: DIRECTION,
          MaximumStopVisits: DIGITS(2),
          OperatorRef: OPERATOR,
        },
        ttlSeconds: 20,
      },
      {
        name: "where-stop",
        pattern: /^\/where\/stop\/([^/]+)\.json$/,
        segment: /^MTA_\d{1,9}$/,
        params: {},
        ttlSeconds: STATIC_TTL,
      },
      {
        name: "where-stops-for-location",
        pattern: /^\/where\/stops-for-location\.json$/,
        params: { lat: COORD, lon: COORD, radius: DIGITS(4) },
        ttlSeconds: STATIC_TTL,
      },
      {
        name: "where-stops-for-route",
        pattern: /^\/where\/stops-for-route\/([^/]+)\.json$/,
        segment: /^[A-Za-z0-9 _+.-]{1,48}$/,
        params: {
          includePolylines: { pattern: /^(true|false)$/, maxLength: 5 },
          version: { pattern: /^2$/, maxLength: 1 },
        },
        ttlSeconds: STATIC_TTL,
      },
    ],
  },

  /** OneBusAway Puget Sound (King County Metro, Sound Transit, Community Transit, Pierce Transit…). */
  pugetsound: {
    upstream: "https://api.pugetsound.onebusaway.org/api",
    secretName: "OBA_PUGETSOUND_KEY",
    key: { kind: "query", name: "key" },
    upstreamPerMinute: 300,
    paths: OBA_PATHS,
  },

  /** OneBusAway Tampa (HART), run by the Open Transit Software Foundation. */
  tampa: {
    upstream: "https://api.tampa.onebusawaycloud.com/api",
    secretName: "OBA_TAMPA_KEY",
    key: { kind: "query", name: "key" },
    upstreamPerMinute: 300,
    paths: OBA_PATHS,
  },

  /**
   * mobiliteit.lu, Luxembourg (HAFAS ReST, CC BY 4.0). Paths and parameters are exactly what
   * `HafasProvider` sends for `.luxembourg`. The server has no name search, so the app loads the
   * whole stop list once (one fixed query, ~0.7 MB) and searches it itself; an hour's cache means
   * ATP sees that query at most once an hour per instance.
   */
  mobiliteit: {
    upstream: "https://cdt.hafas.de/opendata/apiserver",
    secretName: "MOBILITEIT_LU_KEY",
    key: { kind: "query", name: "accessId" },
    upstreamPerMinute: 300,
    paths: [
      {
        name: "nearbystops",
        pattern: /^\/location\.nearbystops$/,
        params: {
          originCoordLat: COORD,
          originCoordLong: COORD,
          r: DIGITS(6),
          maxNo: DIGITS(4),
          type: { pattern: /^(S|SE)$/, maxLength: 2 },
          format: JSON_FORMAT,
        },
        ttlSeconds: STATIC_TTL,
      },
      HAFAS_DEPARTURE_BOARD,
    ],
  },

  /**
   * VBB, Berlin-Brandenburg (HAFAS ReST, production access granted 2026-10-02). Paths and
   * parameters are exactly what `HafasProvider` sends for `.vbb`. VBB's terms ask for efficient
   * requests (or the ID may be paused): stops and trips are cached for an hour, boards for 15 s.
   */
  vbb: {
    upstream: "https://fahrinfo.vbb.de/restproxy/latest",
    secretName: "VBB_KEY",
    key: { kind: "query", name: "accessId" },
    upstreamPerMinute: 300,
    paths: [
      {
        name: "location.name",
        pattern: /^\/location\.name$/,
        params: {
          // A rider's search: any printable text, no control characters.
          input: { pattern: /^[^\p{Cc}]+$/u, maxLength: 64, required: true },
          type: { pattern: /^S$/, maxLength: 1 },
          maxNo: DIGITS(2),
          format: JSON_FORMAT,
        },
        ttlSeconds: STATIC_TTL,
      },
      {
        name: "nearbystops",
        pattern: /^\/location\.nearbystops$/,
        params: {
          originCoordLat: COORD,
          originCoordLong: COORD,
          r: DIGITS(5),
          maxNo: DIGITS(4),
          format: JSON_FORMAT,
        },
        ttlSeconds: STATIC_TTL,
      },
      HAFAS_DEPARTURE_BOARD,
      {
        name: "journeyDetail",
        pattern: /^\/journeyDetail$/,
        // VBB's trip references: `1|51949|5|86|2102026`. `poly=1` adds the trip's line for the
        // line card's map; the app always sends it, so one cached reply serves pattern and shape.
        params: {
          id: { pattern: /^[0-9|]+$/, maxLength: 48, required: true },
          format: JSON_FORMAT,
          poly: { pattern: /^[01]$/, maxLength: 1 },
        },
        ttlSeconds: STATIC_TTL,
      },
    ],
  },
};
