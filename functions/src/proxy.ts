import { AGENCIES, type Agency, type PathRule } from "./agencies";

/**
 * The transit proxy's logic, free of Firebase so it can be tested with plain objects.
 *
 * Order of gates, cheapest refusal first once the caller is known to be the app:
 *   1. GET only                                   → 405
 *   2. App Check token present and valid          → 401
 *      (the web relay instead: an allowed Origin  → 403; see `ProxyGate`)
 *   3. agency + path + parameters in the table    → 404 / 400
 *   4. per-instance request budget                → 429
 *   5. memory cache, then coalescing onto an identical in-flight fetch
 *   6. per-instance, per-agency upstream budget   → 429
 *   7. fetch upstream with the key injected       → upstream status relayed; transport failure 502
 */

export interface ProxyRequest {
  method: string;
  /** The path and query as the caller sent them, still percent-encoded. */
  url: string;
  header(name: string): string | undefined;
}

export interface ProxyResponse {
  status: number;
  headers: Record<string, string>;
  body: Buffer;
}

export interface ProxyDeps {
  /** Resolves with the app id for a valid App Check token; rejects otherwise. Unused by an origin gate. */
  verifyAppCheck?(token: string): Promise<string>;
  fetch: typeof fetch;
  /** The key stored under `secretName`, or undefined when unset. */
  keyFor(secretName: string): string | undefined;
  now?: () => number;
  log?: (level: "info" | "warn" | "error", event: string, fields: Record<string, unknown>) => void;
}

export interface ProxyLimits {
  /** Requests (hits included) one instance accepts per minute, across all agencies. */
  requestsPerMinute: number;
  /** Upper bound on cached entries; the oldest are dropped first. */
  maxCacheEntries: number;
  /** Largest upstream body relayed, in bytes. */
  maxBodyBytes: number;
  upstreamTimeoutMs: number;
}

export const DEFAULT_LIMITS: ProxyLimits = {
  requestsPerMinute: 1200,
  maxCacheEntries: 2000,
  maxBodyBytes: 4 * 1024 * 1024,
  upstreamTimeoutMs: 10_000,
};

/** The function's own name, which prefixes the path on the `cloudfunctions.net` URL. */
const FUNCTION_PREFIX = "/transitProxy";

/**
 * Who may call. The app's relay asks for an App Check token. The web relay serves a browser page,
 * which has no App Check, so it only answers pages from the listed origins and holds no key at
 * all: its table is keyless agencies whose own servers don't allow a browser to read them (CORS).
 * An Origin header can be forged outside a browser, so it keeps other sites from building on this
 * relay rather than locking it; the path table and the rate windows are what bound it.
 */
export type ProxyGate = { kind: "appCheck" } | { kind: "origin"; origins: string[] };

export interface ProxyOptions {
  gate?: ProxyGate;
  /** The function's name, stripped from the front of the path when the URL carries it. */
  functionPrefix?: string;
}

// ---------------------------------------------------------------------------------------------
// Routing

export interface Route {
  agencyID: string;
  agency: Agency;
  rule: PathRule;
  /** Upstream path, canonically encoded (`/where/stop/MTA_308209.json`). */
  path: string;
  /** Allowed parameters only, sorted by name. */
  params: [string, string][];
  /** Normalized upstream URL without the key: the cache key and the log line. */
  cacheKey: string;
}

export type RouteResult = { route: Route } | { status: 400 | 404; error: string };

/** Maps a caller's `/<agency>/<path>?<query>` onto the table, or says why not. */
export function resolveRoute(
  url: string,
  agencies: Record<string, Agency> = AGENCIES,
  functionPrefix: string = FUNCTION_PREFIX,
): RouteResult {
  const queryAt = url.indexOf("?");
  let rawPath = queryAt >= 0 ? url.slice(0, queryAt) : url;
  const rawQuery = queryAt >= 0 ? url.slice(queryAt + 1) : "";

  if (rawPath === functionPrefix || rawPath.startsWith(functionPrefix + "/")) {
    rawPath = rawPath.slice(functionPrefix.length);
  }
  const match = /^\/([a-z0-9-]{1,32})(\/.*)$/.exec(rawPath);
  if (!match) return { status: 404, error: "unknown_route" };
  const [, agencyID, rest] = match;
  if (!Object.prototype.hasOwnProperty.call(agencies, agencyID)) {
    return { status: 404, error: "unknown_agency" };
  }
  const agency = agencies[agencyID];
  if (rest.length > 256) return { status: 404, error: "unknown_path" };

  for (const rule of agency.paths) {
    const found = rule.pattern.exec(rest);
    if (!found) continue;

    // Rebuild the path from the pattern's captures, so what reaches the upstream is the canonical
    // encoding of validated values, never the caller's bytes.
    let path = rest;
    for (const raw of found.slice(1)) {
      let decoded: string;
      try {
        decoded = decodeURIComponent(raw);
      } catch {
        return { status: 400, error: "bad_path" };
      }
      if (!rule.segment || !rule.segment.test(decoded) || /^\.+$/.test(decoded)) {
        return { status: 400, error: "bad_path" };
      }
      // Patterns capture a single segment right before the extension, so its last occurrence is it.
      const at = path.lastIndexOf(raw);
      path = path.slice(0, at) + encodeURIComponent(decoded) + path.slice(at + raw.length);
    }

    const params = filterParams(rawQuery, rule);
    if ("error" in params) return { status: 400, error: params.error };

    const query = params.list.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
    const cacheKey = `${agency.upstream}${path}${query ? `?${query}` : ""}`;
    return { route: { agencyID, agency, rule, path, params: params.list, cacheKey } };
  }
  return { status: 404, error: "unknown_path" };
}

function filterParams(rawQuery: string, rule: PathRule): { list: [string, string][] } | { error: string } {
  if (rawQuery.length > 1024) return { error: "query_too_long" };
  const search = new URLSearchParams(rawQuery);
  const list: [string, string][] = [];
  for (const [name, spec] of Object.entries(rule.params)) {
    const values = search.getAll(name);
    if (values.length > 1) return { error: `duplicate:${name}` };
    const value = values[0];
    if (value === undefined || value === "") {
      if (spec.required) return { error: `missing:${name}` };
      continue;
    }
    if (value.length > spec.maxLength || !spec.pattern.test(value)) return { error: `invalid:${name}` };
    list.push([name, value]);
  }
  // Everything else — including any `key` the caller sent — is dropped, not forwarded.
  list.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return { list };
}

// ---------------------------------------------------------------------------------------------
// Rate limiting

/** A fixed one-minute window. Per instance and approximate on purpose: a counter in Firestore would
 * cost more than the traffic it guards, and `maxInstances` bounds the fleet-wide total anyway. */
export class MinuteWindow {
  private startedAt = 0;
  private count = 0;
  constructor(
    private readonly limit: number,
    private readonly now: () => number,
  ) {}

  take(): boolean {
    const now = this.now();
    if (now - this.startedAt >= 60_000) {
      this.startedAt = now;
      this.count = 0;
    }
    if (this.count >= this.limit) return false;
    this.count += 1;
    return true;
  }
}

// ---------------------------------------------------------------------------------------------
// Cache

interface Upstream {
  status: number;
  contentType: string;
  body: Buffer;
}

interface CacheEntry extends Upstream {
  expiresAt: number;
}

export class ResponseCache {
  private readonly entries = new Map<string, CacheEntry>();
  constructor(
    private readonly maxEntries: number,
    private readonly now: () => number,
  ) {}

  get(key: string): CacheEntry | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= this.now()) {
      this.entries.delete(key);
      return undefined;
    }
    return entry;
  }

  set(key: string, value: Upstream, ttlSeconds: number): void {
    this.entries.delete(key);
    this.entries.set(key, { ...value, expiresAt: this.now() + ttlSeconds * 1000 });
    while (this.entries.size > this.maxEntries) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }

  get size(): number {
    return this.entries.size;
  }
}

// ---------------------------------------------------------------------------------------------
// Handler

class UpstreamUnavailable extends Error {}
class UpstreamBudgetExhausted extends Error {}

function json(status: number, body: Record<string, unknown>, extra: Record<string, string> = {}): ProxyResponse {
  return {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
    body: Buffer.from(JSON.stringify(body)),
  };
}

/** The App Check token from `X-Firebase-AppCheck`, or else `Authorization: Bearer`. */
export function appCheckToken(req: ProxyRequest): string {
  const header = req.header("X-Firebase-AppCheck")?.trim();
  if (header) return header;
  const authorization = req.header("Authorization") ?? "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
}

export function createProxy(
  deps: ProxyDeps,
  limits: ProxyLimits = DEFAULT_LIMITS,
  agencies = AGENCIES,
  options: ProxyOptions = {},
) {
  const gate: ProxyGate = options.gate ?? { kind: "appCheck" };
  const functionPrefix = options.functionPrefix ?? FUNCTION_PREFIX;
  const now = deps.now ?? Date.now;
  const log = deps.log ?? (() => {});
  const cache = new ResponseCache(limits.maxCacheEntries, now);
  const inFlight = new Map<string, Promise<Upstream>>();
  const requests = new MinuteWindow(limits.requestsPerMinute, now);
  const upstreamBudgets = new Map<string, MinuteWindow>();

  function budgetFor(route: Route): MinuteWindow {
    let window = upstreamBudgets.get(route.agencyID);
    if (!window) {
      window = new MinuteWindow(route.agency.upstreamPerMinute, now);
      upstreamBudgets.set(route.agencyID, window);
    }
    return window;
  }

  async function fetchUpstream(route: Route, key: string | undefined): Promise<Upstream> {
    const { agency } = route;
    const query = new URLSearchParams();
    for (const [name, value] of route.params) query.append(name, value);
    // A fresh header set: nothing the caller sent (Authorization, App Check, cookies) is forwarded.
    const headers: Record<string, string> = {
      Accept: "application/json",
      "User-Agent": "BusBus-TransitProxy/1",
      ...(agency.headers ?? {}),
    };
    if (agency.key && key) {
      if (agency.key.kind === "query") {
        query.set(agency.key.name, key);
      } else {
        headers[agency.key.name] = `${agency.key.prefix ?? ""}${key}`;
      }
    }
    const search = query.toString().replace(/\+/g, "%20");
    const url = `${agency.upstream}${route.path}${search ? `?${search}` : ""}`;

    let response: Response;
    try {
      response = await deps.fetch(url, {
        method: "GET",
        headers,
        redirect: "error",
        signal: AbortSignal.timeout(limits.upstreamTimeoutMs),
      });
    } catch (error) {
      throw new UpstreamUnavailable(error instanceof Error ? error.message.slice(0, 120) : "fetch failed");
    }
    const body = Buffer.from(await response.arrayBuffer().catch(() => new ArrayBuffer(0)));
    if (body.length > limits.maxBodyBytes) throw new UpstreamUnavailable("body too large");
    return {
      status: response.status,
      contentType: response.headers.get("content-type") ?? "application/json",
      body,
    };
  }

  function relay(upstream: Upstream, ttlSeconds: number, cacheState: string): ProxyResponse {
    const ok = upstream.status >= 200 && upstream.status < 300;
    return {
      status: upstream.status,
      headers: {
        "Content-Type": upstream.contentType,
        "Cache-Control": ok ? `public, max-age=${Math.max(0, Math.round(ttlSeconds))}` : "no-store",
        "X-Cache": cacheState,
      },
      body: upstream.body,
    };
  }

  /** The web relay's answers carry CORS headers for the page that asked; the app's never do. */
  async function handle(req: ProxyRequest): Promise<ProxyResponse> {
    if (gate.kind === "appCheck") return handleGated(req, null);
    const origin = req.header("Origin") ?? "";
    if (!gate.origins.includes(origin)) {
      log("warn", "transit.rejected_auth", { reason: "origin" });
      return json(403, { error: "forbidden" });
    }
    const cors = { "Access-Control-Allow-Origin": origin, Vary: "Origin" };
    if (req.method === "OPTIONS") {
      return {
        status: 204,
        headers: { ...cors, "Access-Control-Allow-Methods": "GET", "Access-Control-Allow-Headers": "Accept", "Access-Control-Max-Age": "86400" },
        body: Buffer.alloc(0),
      };
    }
    const response = await handleGated(req, "web");
    return { ...response, headers: { ...response.headers, ...cors } };
  }

  async function handleGated(req: ProxyRequest, knownCaller: string | null): Promise<ProxyResponse> {
    const startedAt = now();
    if (req.method !== "GET") return json(405, { error: "method_not_allowed" });

    // ---- App Check, before anything that reveals the table ----------------------------------
    let appID: string;
    if (knownCaller) {
      appID = knownCaller;
    } else {
      const token = appCheckToken(req);
      if (!token || !deps.verifyAppCheck) {
        log("warn", "transit.rejected_auth", { reason: "missing_token" });
        return json(401, { error: "unauthorized" });
      }
      try {
        appID = await deps.verifyAppCheck(token);
      } catch {
        log("warn", "transit.rejected_auth", { reason: "verification_failed" });
        return json(401, { error: "unauthorized" });
      }
    }

    const resolved = resolveRoute(req.url, agencies, functionPrefix);
    if ("error" in resolved) {
      log("warn", "transit.rejected_route", { appID, error: resolved.error });
      return json(resolved.status, { error: resolved.error });
    }
    const { route } = resolved;
    const base = { appID, agency: route.agencyID, path: route.rule.name };

    if (!requests.take()) {
      log("warn", "transit.rate_limited", { ...base, scope: "instance" });
      return json(429, { error: "rate_limited" }, { "Retry-After": "30" });
    }

    const cached = cache.get(route.cacheKey);
    if (cached) return relay(cached, (cached.expiresAt - now()) / 1000, "HIT");

    const pending = inFlight.get(route.cacheKey);
    if (pending) {
      try {
        return relay(await pending, route.rule.ttlSeconds, "COALESCED");
      } catch (error) {
        return failure(error, base, startedAt);
      }
    }

    const key = route.agency.secretName ? deps.keyFor(route.agency.secretName) : undefined;
    if (route.agency.secretName && !key) {
      log("error", "transit.not_configured", { ...base, secret: route.agency.secretName });
      return json(503, { error: "not_configured" });
    }

    const task = (async () => {
      if (!budgetFor(route).take()) throw new UpstreamBudgetExhausted();
      const upstream = await fetchUpstream(route, key);
      if (upstream.status >= 200 && upstream.status < 300) {
        cache.set(route.cacheKey, upstream, route.rule.ttlSeconds);
      }
      return upstream;
    })();
    inFlight.set(route.cacheKey, task);
    try {
      const upstream = await task;
      log(upstream.status < 400 ? "info" : "warn", "transit.served", {
        ...base,
        status: upstream.status,
        bytes: upstream.body.length,
        ms: now() - startedAt,
      });
      return relay(upstream, route.rule.ttlSeconds, "MISS");
    } catch (error) {
      return failure(error, base, startedAt);
    } finally {
      inFlight.delete(route.cacheKey);
    }
  }

  function failure(error: unknown, base: Record<string, unknown>, startedAt: number): ProxyResponse {
    if (error instanceof UpstreamBudgetExhausted) {
      log("warn", "transit.rate_limited", { ...base, scope: "upstream" });
      return json(429, { error: "rate_limited" }, { "Retry-After": "30" });
    }
    log("error", "transit.upstream_failed", {
      ...base,
      ms: now() - startedAt,
      error: error instanceof Error ? error.message : "unknown",
    });
    return json(502, { error: "upstream_unavailable" });
  }

  return { handle, cache };
}
