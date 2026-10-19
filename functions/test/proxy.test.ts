import { describe, expect, it, vi } from "vitest";
import { createProxy, DEFAULT_LIMITS, resolveRoute, type ProxyDeps, type ProxyRequest } from "../src/proxy";

const KEY = "sekret-key-123";
const VM = "/transitProxy/mta/siri/vehicle-monitoring.json?LineRef=MTA%20NYCT_M15&DirectionRef=0&OperatorRef=MTA";

function request(url: string, headers: Record<string, string> = { "X-Firebase-AppCheck": "good" }, method = "GET"): ProxyRequest {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { method, url, header: (name) => lower[name.toLowerCase()] };
}

function setup(overrides: Partial<ProxyDeps> = {}, limits = DEFAULT_LIMITS) {
  let clock = 1_000_000;
  const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
    new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "content-type": "application/json" } }),
  );
  const deps: ProxyDeps = {
    verifyAppCheck: async (token) => {
      if (token !== "good") throw new Error("bad token");
      return "1:app";
    },
    fetch: fetchMock as unknown as typeof fetch,
    keyFor: (name) => (name === "MTA_BUSTIME_KEY" ? KEY : undefined),
    now: () => clock,
    ...overrides,
  };
  const proxy = createProxy(deps, limits);
  return { proxy, fetchMock: deps.fetch as unknown as typeof fetchMock, advance: (ms: number) => (clock += ms) };
}

describe("routing and allowlist", () => {
  it("maps the MTA paths the app uses onto bustime.mta.info", () => {
    const cases: [string, string][] = [
      [VM, "https://bustime.mta.info/api/siri/vehicle-monitoring.json?DirectionRef=0&LineRef=MTA%20NYCT_M15&OperatorRef=MTA"],
      [
        "/mta/siri/stop-monitoring.json?MonitoringRef=MTA_401234&LineRef=MTA%20NYCT_M86%2B&DirectionRef=1&MaximumStopVisits=10&OperatorRef=MTA",
        "https://bustime.mta.info/api/siri/stop-monitoring.json?DirectionRef=1&LineRef=MTA%20NYCT_M86%2B&MaximumStopVisits=10&MonitoringRef=MTA_401234&OperatorRef=MTA",
      ],
      ["/mta/where/stop/MTA_308209.json", "https://bustime.mta.info/api/where/stop/MTA_308209.json"],
      [
        "/mta/where/stops-for-location.json?lat=40.7794&lon=-73.9555&radius=250",
        "https://bustime.mta.info/api/where/stops-for-location.json?lat=40.7794&lon=-73.9555&radius=250",
      ],
      [
        "/mta/where/stops-for-route/MTA%20NYCT_M86%2B.json?includePolylines=false&version=2",
        "https://bustime.mta.info/api/where/stops-for-route/MTA%20NYCT_M86%2B.json?includePolylines=false&version=2",
      ],
    ];
    for (const [input, expected] of cases) {
      const result = resolveRoute(input);
      expect("route" in result && result.route.cacheKey).toBe(expected);
    }
  });

  it("drops parameters outside the allowlist, including a caller's own key", () => {
    const result = resolveRoute(`${VM}&key=stolen&callback=x`);
    expect("route" in result && result.route.params.map(([k]) => k)).toEqual(["DirectionRef", "LineRef", "OperatorRef"]);
  });

  it("refuses unknown agencies, unknown paths and anything shaped like a URL", () => {
    for (const url of [
      "/wmata/foo",
      "/mta/api/where/agencies.json",
      "/mta/siri/vehicle-monitoring.json/../x",
      "/mta/where/stop/..%2F..%2Fetc.json",
      "/mta//evil.example/x",
      "/https://evil.example/x",
      "/__proto__/x",
      "/",
    ]) {
      const result = resolveRoute(url);
      expect("error" in result, url).toBe(true);
    }
  });

  it("requires a line for vehicle monitoring, so the whole fleet is never fetched", () => {
    expect(resolveRoute("/mta/siri/vehicle-monitoring.json?OperatorRef=MTA")).toEqual({ status: 400, error: "missing:LineRef" });
  });

  it("caps and validates values", () => {
    expect(resolveRoute(`/mta/siri/vehicle-monitoring.json?LineRef=${"A".repeat(49)}`)).toMatchObject({ status: 400 });
    expect(resolveRoute("/mta/siri/vehicle-monitoring.json?LineRef=M15&DirectionRef=7")).toMatchObject({ status: 400 });
    expect(resolveRoute("/mta/where/stops-for-location.json?lat=40.7&lon=-73.9&radius=99999")).toMatchObject({ status: 400 });
    expect(resolveRoute("/mta/where/stops-for-location.json?lat=x&lon=-73.9")).toMatchObject({ status: 400 });
    expect(resolveRoute("/mta/siri/vehicle-monitoring.json?LineRef=A&LineRef=B")).toMatchObject({ status: 400 });
  });
});

describe("OneBusAway Puget Sound", () => {
  const OBA = "https://api.pugetsound.onebusaway.org/api";

  it("maps the paths OneBusAwayProvider uses onto api.pugetsound.onebusaway.org", () => {
    const cases: [string, string][] = [
      ["/pugetsound/where/search/stop.json?input=3rd%20Ave%20%26%20Pine%20St", `${OBA}/where/search/stop.json?input=3rd%20Ave%20%26%20Pine%20St`],
      ["/pugetsound/where/stop/1_11133.json", `${OBA}/where/stop/1_11133.json`],
      [
        "/pugetsound/where/stops-for-location.json?lat=47.6097&lon=-122.3331&radius=20000&query=75403",
        `${OBA}/where/stops-for-location.json?lat=47.6097&lon=-122.3331&query=75403&radius=20000`,
      ],
      [
        "/pugetsound/where/stops-for-route/40_100479.json?includePolylines=false&version=2",
        `${OBA}/where/stops-for-route/40_100479.json?includePolylines=false&version=2`,
      ],
      [
        "/pugetsound/where/trips-for-route/1_102615.json?includeStatus=true&includeSchedule=false",
        `${OBA}/where/trips-for-route/1_102615.json?includeSchedule=false&includeStatus=true`,
      ],
      [
        "/pugetsound/where/arrivals-and-departures-for-stop/1_11133.json?minutesBefore=0&minutesAfter=90",
        `${OBA}/where/arrivals-and-departures-for-stop/1_11133.json?minutesAfter=90&minutesBefore=0`,
      ],
    ];
    for (const [input, expected] of cases) {
      const result = resolveRoute(input);
      expect("route" in result && result.route.cacheKey, input).toBe(expected);
    }
  });

  it("never reaches the whole-fleet or other endpoints, and validates ids", () => {
    for (const url of [
      "/pugetsound/where/vehicles-for-agency/1.json",
      "/pugetsound/where/agencies-with-coverage.json",
      "/pugetsound/where/stop/..%2F..%2Fetc.json",
      "/pugetsound/where/trips-for-route/MTA%20NYCT_M15.json",
      "/pugetsound/where/search/stop.json",
      "/pugetsound/where/search/stop.json?input=%3Cscript%3E",
    ]) {
      expect("error" in resolveRoute(url), url).toBe(true);
    }
  });

  it("keeps live answers for 10 s, and uses the Puget Sound key", async () => {
    const { proxy, fetchMock } = setup({ keyFor: (name) => (name === "OBA_PUGETSOUND_KEY" ? "oba-key" : undefined) });
    const response = await proxy.handle(request("/pugetsound/where/trips-for-route/1_102615.json?includeStatus=true"));
    expect(response.status).toBe(200);
    expect(response.headers["Cache-Control"]).toBe("public, max-age=10");
    expect(String(fetchMock.mock.calls[0][0])).toContain("key=oba-key");
  });
});

describe("OneBusAway Tampa", () => {
  it("serves the same paths on api.tampa.onebusawaycloud.com with the Tampa key", async () => {
    const result = resolveRoute("/tampa/where/arrivals-and-departures-for-stop/1_4234.json?minutesBefore=0&minutesAfter=90");
    expect("route" in result && result.route.cacheKey).toBe(
      "https://api.tampa.onebusawaycloud.com/api/where/arrivals-and-departures-for-stop/1_4234.json?minutesAfter=90&minutesBefore=0",
    );
    const { proxy, fetchMock } = setup({ keyFor: (name) => (name === "OBA_TAMPA_KEY" ? "tampa-key" : undefined) });
    const response = await proxy.handle(request("/tampa/where/trips-for-route/1_8.json?includeStatus=true"));
    expect(response.status).toBe(200);
    expect(String(fetchMock.mock.calls[0][0])).toContain("key=tampa-key");
    expect("error" in resolveRoute("/tampa/where/vehicles-for-agency/1.json")).toBe(true);
  });
});

describe("mobiliteit.lu (HAFAS)", () => {
  const LU = "https://cdt.hafas.de/opendata/apiserver";

  it("maps the paths HafasProvider uses for Luxembourg", () => {
    const cases: [string, string][] = [
      [
        "/mobiliteit/location.nearbystops?originCoordLat=49.77723&originCoordLong=6.09528&r=100000&maxNo=5000&type=SE&format=json",
        `${LU}/location.nearbystops?format=json&maxNo=5000&originCoordLat=49.77723&originCoordLong=6.09528&r=100000&type=SE`,
      ],
      [
        "/mobiliteit/departureBoard?id=200405036&duration=120&maxJourneys=200&products=288&passlist=0&format=json",
        `${LU}/departureBoard?duration=120&format=json&id=200405036&maxJourneys=200&passlist=0&products=288`,
      ],
    ];
    for (const [input, expected] of cases) {
      const result = resolveRoute(input);
      expect("route" in result && result.route.cacheKey, input).toBe(expected);
    }
  });

  it("sends our key as accessId, drops the caller's, and refuses anything else", async () => {
    const dropped = resolveRoute("/mobiliteit/departureBoard?id=200405036&format=json&accessId=other");
    expect("route" in dropped && dropped.route.cacheKey).toBe(`${LU}/departureBoard?format=json&id=200405036`);
    const { proxy, fetchMock } = setup({ keyFor: (name) => (name === "MOBILITEIT_LU_KEY" ? "lu-key" : undefined) });
    const response = await proxy.handle(request("/mobiliteit/departureBoard?id=200405036&format=json"));
    expect(response.status).toBe(200);
    expect(response.headers["Cache-Control"]).toBe("public, max-age=15");
    expect(String(fetchMock.mock.calls[0][0])).toContain("accessId=lu-key");
    for (const url of [
      "/mobiliteit/departureBoard?format=json",
      "/mobiliteit/departureBoard?id=abc&format=json",
      "/mobiliteit/departureBoard?id=200405036&format=xml",
      "/mobiliteit/journeyDetail?id=1&format=json",
      "/mobiliteit/location.name?input=Gare&format=json",
    ]) {
      expect("error" in resolveRoute(url), url).toBe(true);
    }
  });
});

describe("VBB (HAFAS)", () => {
  const VBB = "https://fahrinfo.vbb.de/restproxy/latest";

  it("maps the paths HafasProvider uses for Berlin-Brandenburg", () => {
    const cases: [string, string][] = [
      [
        "/vbb/location.name?input=Alexanderplatz&type=S&maxNo=20&format=json",
        `${VBB}/location.name?format=json&input=Alexanderplatz&maxNo=20&type=S`,
      ],
      [
        "/vbb/location.nearbystops?originCoordLat=52.5219&originCoordLong=13.4132&r=1000&maxNo=1000&format=json",
        `${VBB}/location.nearbystops?format=json&maxNo=1000&originCoordLat=52.5219&originCoordLong=13.4132&r=1000`,
      ],
      [
        "/vbb/departureBoard?id=900100003&duration=120&maxJourneys=200&products=12&passlist=0&format=json",
        `${VBB}/departureBoard?duration=120&format=json&id=900100003&maxJourneys=200&passlist=0&products=12`,
      ],
      [
        "/vbb/journeyDetail?id=1%7C51949%7C5%7C86%7C2102026&format=json",
        `${VBB}/journeyDetail?format=json&id=1%7C51949%7C5%7C86%7C2102026`,
      ],
      [
        "/vbb/journeyDetail?id=1%7C32387%7C0%7C86%7C19102026&poly=1&format=json",
        `${VBB}/journeyDetail?format=json&id=1%7C32387%7C0%7C86%7C19102026&poly=1`,
      ],
    ];
    for (const [input, expected] of cases) {
      const result = resolveRoute(input);
      expect("route" in result && result.route.cacheKey, input).toBe(expected);
    }
  });

  it("forwards a search in any script, and sends our key as accessId", async () => {
    const umlaut = resolveRoute("/vbb/location.name?input=M%C3%BCggelheimer%20Str.&format=json");
    expect("route" in umlaut).toBe(true);
    const { proxy, fetchMock } = setup({ keyFor: (name) => (name === "VBB_KEY" ? "vbb-key" : undefined) });
    const response = await proxy.handle(request("/vbb/departureBoard?id=900100003&format=json&accessId=other"));
    expect(response.status).toBe(200);
    const url = String(fetchMock.mock.calls[0][0]);
    expect(url).toContain("accessId=vbb-key");
    expect(url).not.toContain("accessId=other");
  });

  it("refuses anything the app does not send", () => {
    for (const url of [
      "/vbb/location.name?format=json",
      "/vbb/location.name?input=a%0Ab&format=json",
      `/vbb/location.name?input=${"x".repeat(65)}&format=json`,
      "/vbb/journeyDetail?id=1%7Cabc&format=json",
      "/vbb/journeyDetail?id=1%7C2&poly=yes&format=json",
      "/vbb/trip?originId=1&destId=2&format=json",
      "/vbb/departureBoard?id=900100003&format=xml",
    ]) {
      expect("error" in resolveRoute(url), url).toBe(true);
    }
  });
});

describe("App Check", () => {
  it("rejects a request without a token before touching the upstream", async () => {
    const { proxy, fetchMock } = setup();
    const response = await proxy.handle(request(VM, {}));
    expect(response.status).toBe(401);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects an invalid token", async () => {
    const { proxy, fetchMock } = setup();
    expect((await proxy.handle(request(VM, { "X-Firebase-AppCheck": "forged" }))).status).toBe(401);
    expect((await proxy.handle(request(VM, { Authorization: "Bearer forged" }))).status).toBe(401);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("accepts the token as a Bearer too, and never forwards the caller's headers", async () => {
    const { proxy, fetchMock } = setup();
    const response = await proxy.handle(request(VM, { Authorization: "Bearer good", Cookie: "c=1" }));
    expect(response.status).toBe(200);
    const [url, init] = fetchMock.mock.calls[0];
    const headers = init?.headers as Record<string, string>;
    expect(Object.keys(headers).map((h) => h.toLowerCase())).not.toContain("authorization");
    expect(Object.keys(headers).map((h) => h.toLowerCase())).not.toContain("cookie");
    expect(Object.keys(headers).map((h) => h.toLowerCase())).not.toContain("x-firebase-appcheck");
    expect(headers["Accept-Language"]).toBe("en-US");
    expect(String(url)).toContain(`key=${KEY}`);
  });

  it("answers only GET", async () => {
    const { proxy } = setup();
    expect((await proxy.handle(request(VM, undefined, "POST"))).status).toBe(405);
  });
});

describe("cache", () => {
  it("serves vehicle monitoring from memory for 30 s", async () => {
    const { proxy, fetchMock, advance } = setup();
    const first = await proxy.handle(request(VM));
    expect(first.headers["Cache-Control"]).toBe("public, max-age=30");
    expect(first.headers["X-Cache"]).toBe("MISS");
    advance(29_000);
    const second = await proxy.handle(request(VM));
    expect(second.headers["X-Cache"]).toBe("HIT");
    expect(second.headers["Cache-Control"]).toBe("public, max-age=1");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    advance(1_000);
    await proxy.handle(request(VM));
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("keys on the normalized request: order and dropped parameters don't matter", async () => {
    const { proxy, fetchMock } = setup();
    await proxy.handle(request("/mta/siri/vehicle-monitoring.json?OperatorRef=MTA&DirectionRef=0&LineRef=MTA%20NYCT_M15"));
    await proxy.handle(request(`${VM}&key=x&junk=1`));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("keeps static answers for an hour and stop monitoring for 20 s", async () => {
    const { proxy } = setup();
    expect((await proxy.handle(request("/mta/where/stop/MTA_308209.json"))).headers["Cache-Control"]).toBe("public, max-age=3600");
    expect(
      (await proxy.handle(request("/mta/siri/stop-monitoring.json?MonitoringRef=MTA_308209"))).headers["Cache-Control"],
    ).toBe("public, max-age=20");
  });

  it("coalesces identical concurrent requests into one upstream fetch", async () => {
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => (release = resolve));
    const { proxy, fetchMock } = setup({
      fetch: vi.fn(async () => {
        await gate;
        return new Response("{}", { status: 200 });
      }) as unknown as typeof fetch,
    });
    const pending = [proxy.handle(request(VM)), proxy.handle(request(VM)), proxy.handle(request(VM))];
    await new Promise((resolve) => setTimeout(resolve, 0));
    release();
    const responses = await Promise.all(pending);
    expect(responses.map((r) => r.status)).toEqual([200, 200, 200]);
    expect(responses.map((r) => r.headers["X-Cache"]).sort()).toEqual(["COALESCED", "COALESCED", "MISS"]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does not cache failures, and relays their status and body", async () => {
    const { proxy, fetchMock } = setup({
      fetch: vi.fn(async () => new Response('{"code":404}', { status: 404 })) as unknown as typeof fetch,
    });
    const response = await proxy.handle(request("/mta/where/stop/MTA_1.json"));
    expect(response.status).toBe(404);
    expect(response.body.toString()).toBe('{"code":404}');
    expect(response.headers["Cache-Control"]).toBe("no-store");
    await proxy.handle(request("/mta/where/stop/MTA_1.json"));
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("failures and limits", () => {
  it("maps a transport failure to 502 without leaking the key", async () => {
    const { proxy } = setup({
      fetch: vi.fn(async () => {
        throw new TypeError(`fetch failed for ?key=${KEY}`);
      }) as unknown as typeof fetch,
    });
    const response = await proxy.handle(request(VM));
    expect(response.status).toBe(502);
    expect(response.body.toString()).not.toContain(KEY);
  });

  it("returns 503 when the agency's key is not configured", async () => {
    const { proxy } = setup({ keyFor: () => undefined });
    expect((await proxy.handle(request(VM))).status).toBe(503);
  });

  it("rate-limits an instance with 429", async () => {
    const { proxy, advance } = setup({}, { ...DEFAULT_LIMITS, requestsPerMinute: 2 });
    expect((await proxy.handle(request(VM))).status).toBe(200);
    expect((await proxy.handle(request(VM))).status).toBe(200);
    expect((await proxy.handle(request(VM))).status).toBe(429);
    advance(60_000);
    expect((await proxy.handle(request(VM))).status).toBe(200);
  });
});
