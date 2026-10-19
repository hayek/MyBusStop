# My Stops home + map search — design

Date: 2026-10-18. Status: approved in conversation; the user asked for implement → review → fix →
integration tests (Mac + iOS simulator) → run on their iPhone in one go.
Mockups: https://claude.ai/artifact/6kQrzmF3ATboVBPAL4DR9E — artboards **Home · just your stops**
(`Main`), **B · map + drawer**, **B · typing**, **B · confirm the stop**. The A and C rows and the
"Home · your stops + nearby" artboard were the options not chosen.

## Intent

**What the user said.** The stop picker (`StopPickerView`: title, search field, MY STOPS, NEARBY
with an inline map, all in one scroll) is not easy to use. Make the first screen **My Stops with a
search bar at the top**. Tapping the search bar opens a **screen of its own for searching**: the
search field at the top, a **full map below** with the rider's location, a **center-on-me** button
and a **search here** button that looks for stops wherever the map is. Of three approaches the user
chose **B: a map with a results drawer** (Apple Maps–like) and the **home with only the saved
stops**. Choosing a stop from the list or the map must go through a **confirmation step that is not
an alert**: the stop is highlighted and centred on the map, with **SELECT STOP** and **BACK**.

**Why.** Today one long scroll mixes saved stops, a search field, a small map and a nearby list.
Riders who come back open a saved stop; riders who look for a new one want the map big. Splitting
the two makes each screen do one thing.

**Success.** A returning rider sees their saved stops first and opens one in one tap. A rider
looking for a stop taps search, finds it on a full map or by name, sees it picked out on the map,
and confirms it before going on to choose lines. Nothing is chosen by a mis-tap on a small map.

## Goals

- The root of the iOS/macOS navigation stack becomes **My Stops** (the left home).
- A new full-screen **search screen** with map + drawer, typing, and the confirm step.
- Everything today's picker does for a rider still has a home: location permission, location
  off/restricted, outside coverage, service down notice, region switch (Hong Kong), the data's
  credit line, recent searches, search-this-area, center-on-me.

## Non-goals

- Apple TV (`TVRootView`) — unchanged.
- Place search (malls, streets via Apple's place lookup) — offered in the mockups, left out.
- **Line results.** The B · typing artboard shows a "LINES" section; providers only have
  `searchStops`, so results are stops only. (Builder's note: drop that section; the mockup is not
  updated.)
- Light-mode mockups: the build follows `Theme` in both modes as every screen does; the mockups are
  dark only.
- Re-shooting App Store screenshots. Screenshot mode must keep working (see Screenshots), but
  regenerating the store set is a separate task.

## Anti-goals

- An `.alert` or `.confirmationDialog` for the confirm step.
- Choosing a stop on a single tap anywhere in search (row or pin).
- A drawer whose drag fights the map's pan.
- Losing the rider's place: BACK from the confirm step must put the drawer, its scroll and the map
  back as they were.

## 1. Home — My Stops

Matches the `Main` artboard.

- Title **MY STOPS** (replaces CHOOSE YOUR STOP), trailing **EDIT** (only when there are saved
  stops) and the feedback bubble, and the DEBUG settings gear as today.
- **Search bar** under the title: looks like today's `SearchField` but is a **button** — no text
  entry here. Tapping it opens the search screen with the
  keyboard **down** (the map first). Placeholder copy reuses today's localized "Search stop or line"
  (some providers match route numbers through `searchStops`).
- **Saved stops**: today's `HistorySetupRow`s with their ⓘ, pin, swipe-to-remove and EDIT mode,
  unchanged. Tapping one resumes it (`onResume`) straight away — **no confirm step** for saved
  stops (they were confirmed once already). No more 4-row cap on the home: all saved stops
  (`SavedSetups.limit`) are listed, since this is now the whole screen.
- **Add a stop** row (dashed outline) after the last saved stop: opens the search screen, same as
  the bar.
- The NEARBY section, inline map, recent-search chips, and permission/denied cards **leave the
  home** (they move to the search screen).
- Footer: region caption only (e.g. "STOPS IN TEL AVIV"), without the operator menu. The menu,
  service notice and credit line move to the search screen's drawer, beside the stops they're
  about.
- iPad/Mac landscape: one centred column, max width ≈ 640pt, same content (my call — two columns
  have nothing left to split).

### Empty home (first launch, or everything removed)

My call, not shown in the mockups:
- With no saved stops the title keeps today's welcome copy when `isWelcome` holds ("WELCOME /
  Where do you catch the bus?"), else MY STOPS. Under the search bar sits one large card, "Find
  your first stop", with a short line ("Search by name, or look around you on the map") that opens
  the search screen. No dashed Add-a-stop row in that state.
- The welcome story's answers route into search: **allowLocation** → after the story fades, open
  the search screen (which then asks for location as today's CONTINUE does);
  **searchByName** → open the search screen with the keyboard **up** (replaces
  `requestsSearchFocus` on the home); **timedOut** → stay on the home.

## 2. The search screen

Presented over the home: `.fullScreenCover` on iPhone/iPad, a large `.sheet` on Mac (macOS has no
full-screen cover; my call). Matches **B · map + drawer**.

### Every opening starts fresh

Opening search (bar, Add a stop, welcome, or after the board's change-stop) always starts clean: empty
field, no stop picked, drawer at **medium**, and the list around the rider — an earlier
search-this-area is dropped (`loadNearby(force: true)` when the list was an area search). CANCEL and
SELECT STOP keep nothing for next time. Only the welcome's **searchByName** opens with the keyboard up.

### Layout

- **Header** (solid ground): the search field (a real text field), and **CANCEL** text button that
  closes the whole search screen. A clear (×) button inside the field when it has text.
- **Map** below the header to the bottom edge: MapKit, `UserAnnotation`, no system POIs (as
  `StopMapView` today), the app's `StopPin`s.
- **SEARCH THIS AREA** capsule at the top of the map; shows once the map is moved, and always when
  nothing is listed (location off). Shows **ZOOM IN TO SEARCH** past
  `MapFraming.searchableSpanMeters`, exactly today's rules and `model.searchArea(around:spanMeters:)`.
- **Center-on-me** round button, trailing, just above the drawer's top edge; moves with the drawer.
  Same action as today's recenter button (relocate, reload nearby, fit). Hidden without a location
  fix.
- **Drawer** at the bottom, over the map, with a grabber. Three heights (my call):
  - **small** — header row only (≈ 120pt), for looking at the map;
  - **medium** (default) — ≈ 45% of the screen;
  - **large** — up to just under the header, the map peeking ≈ 150pt above it.
  Drag snaps between them; the list scrolls only at **large**. Typing in the field moves the drawer
  to **large**; clearing the field returns it to **medium**.
- **Wider than tall and at least 600pt wide** (iPhone and iPad landscape, Mac windows): the drawer becomes a **side panel** (leading, ≈ 380pt wide, full height
  under the header), map to its trailing side; no heights. Confirm replaces the panel's content the
  same way (my call).

### Drawer content, not searching

- Header: **IN VIEW** (or **NEARBY** when the list is around the rider, **THIS AREA** after a
  search-here), with the count caption from `nearbyCaption` trailing.
- **Recent searches** chips (`SearchTermChip`) above the header when the field is empty and there
  are any; tapping one runs it.
- Rows: today's `NearbyStopRow` (distance, name, line badges). No ⓘ in the drawer: the confirm step
  shows that stop's details (my call).
- States that today live on the picker go at the top of the drawer content, same components:
  `LocationPermissionCard` (needs permission, CONTINUE asks), `LocationDeniedCard`
  (denied/restricted — its "search" action focuses the field), skeleton rows while locating.
  Outside coverage / unavailable say so via the caption as today.
- Footer at the end of the list: the region caption **with the operator menu** where
  `regionsHere.count > 1`, the service notice, and the credit line with its link — i.e. today's
  `serviceFooter`, moved here.

### Typing

Matches **B · typing**.
- Results (`model.results`) fill the drawer under a **STOPS** header, as rows with a **number**
  badge on the leading side (1, 2, 3…), name and address (`RecentStopRow`'s content plus the
  number).
- The map shows the same results as **numbered pins** (same numbers), up to
  `SetupViewModel.mapResultLimit`. The map frames them as `StopMapView.fit()` does for results.
- Not searching, pins keep the bus glyph.
- Empty results: "NO STOPS MATCH" caption, and the map stays where it was.

### The confirm step

Matches **B · confirm the stop**. Triggered by tapping **a row in the drawer or a pin on the map**
— both the same.

1. The map animates to put the stop **at the centre of the visible map** (above the panel, not the
   screen's centre), zooming in to street level only if the current view is wider than ≈ 1.5 km.
2. That pin grows and gets the focus ring (today's `StopPin` focused look) plus a soft halo; all
   other pins fade to ≈ 40% and stop taking taps.
3. The drawer is replaced by the **confirm panel** (fixed height, no drag):
   - caption "THIS STOP?" and, trailing, distance + walk time ("90 M · 1 MIN WALK", ≈ 80 m/min)
     when the rider's location is known; nothing when not;
   - stop name (large), address line (`StopAddresses`) — and the stop's direction/code if the
     provider has it;
   - line badges for the lines at the stop. Nearby rows already carry them; for search results,
     load them with the same cached `lines(atStop:)` call step 2 uses (shimmer while loading;
     the panel works without them);
   - **BACK** (outlined, with a leading chevron) and **SELECT STOP** (filled, trailing chevron),
     side by side, 1 : 2 widths.
4. **BACK** (also: tapping the faded map, or the system back gesture / Escape on Mac) restores the
   drawer at the height and scroll it had, the map camera from before step 1, and the field's text.
5. **SELECT STOP**: remember the search if any (`rememberSearchIfAny`), close the search screen and
   push **lines** on the root stack — today's `onChoose` path. Back from lines lands on the home
   (my call; the search screen is not reopened).
6. VoiceOver: the confirm panel is announced as a screen change and gets focus on the stop's name;
   BACK and SELECT STOP are plain buttons.

Today's `focusedStopID` / `toggleFocus` is the confirm state's source of truth; a second tap on the
focused pin does nothing (BACK is the way out), unlike today's toggle.

## 3. Model and code shape

Left to the builder, with these constraints:
- `SetupViewModel` stays the one model for home, search and lines; it already holds query,
  results, nearby, area search, focus, regions and history. New state it needs: whether search is
  presented, the drawer height, and what BACK must restore (camera, drawer height, scroll).
- `StopMapView`'s logic (fit, anchor/hasMoved, search-here, recenter) moves into the new full map;
  the embedded card overlay goes away. `StopPickerView` is split into the home and the search
  screen; dead pieces are deleted, not left behind.
- Platform fences as today (`#if os(tvOS)` excludes; tvOS never builds these screens).
- Localize every new string in `Localizable.xcstrings` (the app ships 35 languages); copy follows
  the app's upper-case Space Mono captions.
- Tests: the confirm/BACK restore logic and the drawer's state changes are plain model logic and
  get unit tests in `BusBusTests`.

## 4. Screenshots

`ScreenshotMode` `.stops` must stage the new home with the mock saved stops. Add a `.search` screen
that opens search on the mock nearby stops (and a staged confirm if cheap). Store screenshots are
not regenerated in this work.

## Left to the builder

Exact spacing, animation curves, drawer snap thresholds, map zoom constants, and file layout —
within the mockups and the app's `DesignTokens`/`Typography`.
