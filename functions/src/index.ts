import { initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { logger } from "firebase-functions/v2";
import { onRequest } from "firebase-functions/v2/https";
import { gzipSync } from "node:zlib";
import { SECRETS } from "./config";
import { createProxy, DEFAULT_LIMITS } from "./proxy";
import { WEB_AGENCIES, WEB_ORIGINS } from "./web-agencies";

initializeApp();

const secretsByName = new Map(SECRETS.map((secret) => [secret.name, secret]));

/**
 * Module scope, so the memory cache, the coalescing map and the rate windows are shared by every
 * request an instance serves (concurrency > 1) and survive between them.
 */
const proxy = createProxy({
  verifyAppCheck: async (token) => (await getAppCheck().verifyToken(token)).appId,
  fetch: (input, init) => fetch(input, init),
  keyFor: (name) => {
    const value = secretsByName.get(name)?.value();
    return value ? value.trim() : undefined;
  },
  log: (level, event, fields) => logger[level](event, fields),
});

/**
 * `GET /transitProxy/<agency>/<path>` — see `proxy.ts` for the gates and `agencies.ts` for the
 * only paths it will fetch.
 *
 * Sized for a ~$10/month budget: at most 3 small instances, each serving many requests at once
 * (most are cache hits that never leave memory), scaled to zero when idle.
 */
export const transitProxy = onRequest(
  {
    region: "us-central1",
    secrets: SECRETS,
    memory: "256MiB",
    cpu: 1,
    concurrency: 80,
    maxInstances: 3,
    minInstances: 0,
    timeoutSeconds: 15,
    cors: false,
    invoker: "public",
  },
  async (req, res) => {
    const response = await proxy.handle({
      method: req.method,
      url: req.originalUrl || req.url,
      header: (name) => req.get(name),
    });
    res.status(response.status);
    for (const [name, value] of Object.entries(response.headers)) res.set(name, value);
    res.send(response.body);
  },
);

/**
 * `GET /webTransit/<agency>/<path>` — the web version's relay (amirhayek.dev/MyBusStop/web), for
 * keyless agencies whose servers a browser may not read (CORS). It holds no key and needs no App
 * Check: it answers only pages from `WEB_ORIGINS`, and only the paths in `web-agencies.ts`.
 *
 * In Tel Aviv, next to bus.gov.il, whose firewall is wary of traffic from abroad. Smaller than the
 * app's relay: a page polls one stop's lines every 20 seconds while it is open and visible.
 */
const webProxy = createProxy(
  {
    fetch: (input, init) => fetch(input, init),
    keyFor: () => undefined,
    log: (level, event, fields) => logger[level](event, fields),
  },
  // A stop's lines come with every route's stops (half a megabyte) and take a few seconds.
  { ...DEFAULT_LIMITS, requestsPerMinute: 900, maxBodyBytes: 6 * 1024 * 1024, upstreamTimeoutMs: 20_000 },
  WEB_AGENCIES,
  { gate: { kind: "origin", origins: WEB_ORIGINS }, functionPrefix: "/webTransit" },
);

export const webTransit = onRequest(
  {
    region: "me-west1",
    memory: "256MiB",
    cpu: 1,
    concurrency: 80,
    maxInstances: 2,
    minInstances: 0,
    timeoutSeconds: 30,
    cors: false,
    invoker: "public",
  },
  async (req, res) => {
    const response = await webProxy.handle({
      method: req.method,
      url: req.originalUrl || req.url,
      header: (name) => req.get(name),
    });
    res.status(response.status);
    for (const [name, value] of Object.entries(response.headers)) res.set(name, value);
    // A stop's lines come with every route's stops (half a megabyte of JSON), so compress.
    if (response.body.length > 1024 && /\bgzip\b/.test(req.get("Accept-Encoding") ?? "")) {
      res.set("Content-Encoding", "gzip");
      res.append("Vary", "Accept-Encoding");
      res.send(gzipSync(response.body));
      return;
    }
    res.send(response.body);
  },
);
