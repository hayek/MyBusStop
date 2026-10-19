import { describe, expect, it, vi } from "vitest";
import { createProxy, DEFAULT_LIMITS, resolveRoute, type ProxyRequest } from "../src/proxy";
import { WEB_AGENCIES, WEB_ORIGINS } from "../src/web-agencies";

const SITE = "https://amirhayek.dev";
const SCHED = "/webTransit/bus-gov-il/mot-scheduler-prod/api/en";

function request(url: string, headers: Record<string, string> = { Origin: SITE }, method = "GET"): ProxyRequest {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { method, url, header: (name) => lower[name.toLowerCase()] };
}

function setup() {
  const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
    new Response(JSON.stringify({ data: [] }), { status: 200, headers: { "content-type": "application/json" } }),
  );
  const verifyAppCheck = vi.fn(async () => "1:app");
  const proxy = createProxy(
    { fetch: fetchMock as unknown as typeof fetch, keyFor: () => undefined, verifyAppCheck, now: () => 1_000_000 },
    DEFAULT_LIMITS,
    WEB_AGENCIES,
    { gate: { kind: "origin", origins: WEB_ORIGINS }, functionPrefix: "/webTransit" },
  );
  return { proxy, fetchMock, verifyAppCheck };
}

const resolve = (url: string) => resolveRoute(url, WEB_AGENCIES, "/webTransit");

describe("web relay: who may call", () => {
  it("answers the site with CORS headers for it, and never asks for App Check", async () => {
    const { proxy, verifyAppCheck } = setup();
    const response = await proxy.handle(request(`${SCHED}/Stops/GetStopFullData?stopCode=21470`));
    expect(response.status).toBe(200);
    expect(response.headers["Access-Control-Allow-Origin"]).toBe(SITE);
    expect(response.headers.Vary).toBe("Origin");
    expect(verifyAppCheck).not.toHaveBeenCalled();
  });

  it("refuses other origins and requests with no origin, before touching the table", async () => {
    const { proxy, fetchMock } = setup();
    for (const headers of [{ Origin: "https://evil.example" }, {}, { Origin: "https://amirhayek.dev.evil.example" }]) {
      const response = await proxy.handle(request(`${SCHED}/Stops/GetStopFullData?stopCode=21470`, headers));
      expect(response.status).toBe(403);
      expect(response.headers["Access-Control-Allow-Origin"]).toBeUndefined();
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("answers a preflight for GET only", async () => {
    const { proxy } = setup();
    const response = await proxy.handle(request(`${SCHED}/Stops/GetStopFullData?stopCode=1`, { Origin: SITE }, "OPTIONS"));
    expect(response.status).toBe(204);
    expect(response.headers["Access-Control-Allow-Methods"]).toBe("GET");
    const post = await proxy.handle(request(`${SCHED}/Stops/GetStopFullData?stopCode=1`, { Origin: SITE }, "POST"));
    expect(post.status).toBe(405);
  });
});

describe("web relay: what it fetches", () => {
  it("maps every bus.gov.il path the web version sends, with no key added", async () => {
    const { proxy, fetchMock } = setup();
    const cases: [string, string][] = [
      [
        "/webTransit/bus-gov-il/route-planner-prod/api/he/AutoComplete/SearchStations?searchTerm=%D7%90%D7%9C%D7%A0%D7%91%D7%99",
        "https://api.bus.gov.il/prod/route-planner-prod/api/he/AutoComplete/SearchStations?searchTerm=%D7%90%D7%9C%D7%A0%D7%91%D7%99",
      ],
      [`${SCHED}/Stops/GetStopByCode?stopcode=21470`, "https://api.bus.gov.il/prod/mot-scheduler-prod/api/en/Stops/GetStopByCode?stopcode=21470"],
      [`${SCHED}/Routes/GetRouteStops?routeId=13428`, "https://api.bus.gov.il/prod/mot-scheduler-prod/api/en/Routes/GetRouteStops?routeId=13428"],
      [`${SCHED}/Routes/GetRouteLocations?routeId=13428`, "https://api.bus.gov.il/prod/mot-scheduler-prod/api/en/Routes/GetRouteLocations?routeId=13428"],
      [
        `${SCHED}/Calendar/GetRouteCalendarAtStopsByStopCodes?stopCodes=21470&routeDesc=81001-1-0`,
        "https://api.bus.gov.il/prod/mot-scheduler-prod/api/en/Calendar/GetRouteCalendarAtStopsByStopCodes?routeDesc=81001-1-0&stopCodes=21470",
      ],
    ];
    for (const [input, expected] of cases) {
      const response = await proxy.handle(request(input));
      expect(response.status).toBe(200);
      expect(String(fetchMock.mock.calls.at(-1)?.[0])).toBe(expected);
    }
  });

  it("refuses languages, paths and values outside the table", () => {
    const refused = [
      `/webTransit/bus-gov-il/mot-scheduler-prod/api/fr/Stops/GetStopByCode?stopcode=1`,
      `${SCHED}/Stops/DeleteStop?stopcode=1`,
      `${SCHED}/Stops/GetStopByCode?stopcode=12a`,
      `${SCHED}/Stops/GetStopsCloseToLocation?lat=32.08&lng=34.78&radius=500`,
      `${SCHED}/Calendar/GetRouteCalendarAtStopsByStopCodes?stopCodes=1&routeDesc=../x`,
      `/webTransit/mta/siri/vehicle-monitoring.json?LineRef=M15`,
      `/webTransit/bus-gov-il/..%2F..%2Fadmin`,
    ];
    for (const url of refused) expect("error" in resolve(url)).toBe(true);
  });

  it("forwards only listed parameters", () => {
    const result = resolve(`${SCHED}/Routes/GetRouteStops?routeId=1&key=x&callback=y`);
    expect("route" in result && result.route.params).toEqual([["routeId", "1"]]);
  });
});
