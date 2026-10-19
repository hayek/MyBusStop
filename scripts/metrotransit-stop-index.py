#!/usr/bin/env python3
"""Builds BusBus/Resources/Transit/MetroTransitStopLines.json from Metro Transit's official GTFS.

NexTrip names a stop's lines only from its upcoming departures, so overnight (and for peak-only
expresses off-peak) a stop seems to have none. The app falls back to this index of every line the
timetable stops there, keyed by public stop number. Rerun it before a release, or after a service
change (Metro Transit picks change in March, June, August and December):

    scripts/metrotransit-stop-index.py
"""
import collections
import csv
import io
import json
import pathlib
import urllib.request
import zipfile

GTFS = "https://svc.metrotransit.org/mtgtfs/gtfs.zip"
OUT = pathlib.Path(__file__).resolve().parent.parent / "BusBus/Resources/Transit/MetroTransitStopLines.json"


def table(archive, name):
    return csv.DictReader(io.TextIOWrapper(archive.open(name), encoding="utf-8-sig"))


def short_name(route):
    # Rail and rapid bus lines have no short name in the GTFS: "METRO Blue Line" is "Blue", as NexTrip says.
    name = route["route_short_name"].strip()
    if name:
        return name
    long_name = route["route_long_name"].strip()
    return long_name.removeprefix("METRO ").removesuffix(" Line") or route["route_id"]


def main():
    with urllib.request.urlopen(GTFS) as response:
        archive = zipfile.ZipFile(io.BytesIO(response.read()))

    routes = {r["route_id"]: r for r in table(archive, "routes.txt")}
    trip_line = {}
    headsigns = collections.defaultdict(collections.Counter)
    for trip in table(archive, "trips.txt"):
        line = (trip["route_id"], trip["direction_id"], trip["direction"])
        trip_line[trip["trip_id"]] = line
        headsigns[line][trip["trip_headsign"]] += 1
    codes = {s["stop_id"]: s["stop_code"] or s["stop_id"] for s in table(archive, "stops.txt")}

    stop_lines = collections.defaultdict(set)
    for call in table(archive, "stop_times.txt"):
        if call["pickup_type"] == "1":  # set-down only: no one boards here
            continue
        stop_lines[codes[call["stop_id"]]].add(trip_line[call["trip_id"]])

    lines = sorted({line for found in stop_lines.values() for line in found},
                   key=lambda l: (int(routes[l[0]].get("route_sort_order") or 0), l))
    index = {line: i for i, line in enumerate(lines)}
    out = {
        "lines": [{
            "route": route,
            "direction": int(direction),
            "directionText": direction_text,
            "shortName": short_name(routes[route]),
            "headsign": headsigns[(route, direction, direction_text)].most_common(1)[0][0],
            "agency": int(routes[route]["agency_id"]),
        } for route, direction, direction_text in lines],
        "stops": {code: sorted(index[l] for l in found) for code, found in sorted(stop_lines.items())},
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
    print(f"{len(out['lines'])} lines at {len(out['stops'])} stops → {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
