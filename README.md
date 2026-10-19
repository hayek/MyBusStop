# My Bus Stop

When is the bus coming? My Bus Stop answers it for the stop you use every day: your lines, the next
arrivals, and the buses themselves moving along the route towards you. It runs on iPhone, Apple
Watch, Mac and Apple TV, with widgets, and can turn a spare iPhone into a board on the wall by the
front door.

[App Store](https://apps.apple.com/app/id6814983455) · [Website](https://amirhayek.dev/MyBusStop/)

The app is free, with no ads, no accounts and no in-app purchases.

## Where it works

Each city is a provider talking to its operator's own open data, straight from the device: Israel,
New York, Boston, Seattle, Tampa, Minneapolis–St Paul, Toronto, London, Berlin & Brandenburg,
Vienna, Linz, Nuremberg, Brussels, Luxembourg, Ljubljana, Gdańsk, Kraków, Poznań, Tallinn, Vilnius,
Kaunas, Turku, Tampere, Norway, the Lisbon area, Rennes, Bizkaia, Istanbul, Hong Kong, Tokyo,
Adelaide and Switzerland. `BusBus/Transit/SupportedRegions.swift` has the list and
`BusBus/Transit/Providers` the adapters.

## Building

Open `BusBus.xcodeproj` in Xcode and run the `BusBus` scheme. One scheme builds the iPhone and
Watch app, the Mac app and the Apple TV app.

- **Keys are optional.** Most providers need none. The few that do (New York, Seattle, Tampa,
  Berlin, Luxembourg) read a key in Debug from `Config/Secrets.xcconfig`; copy
  `Config/Secrets.example.xcconfig`, which says where each free key comes from. Release builds hold
  no keys and reach those feeds through a small Firebase function (`functions/`).
- **Firebase is optional.** Without a `BusBus/GoogleService-Info.plist` of your own, analytics and
  crash reports are switched off and everything else works.

Tests: the `BusBus` scheme's unit tests run on the Mac. `scripts/live-api-tests.sh` checks every
provider against its live API.

## Data

Timetables and live positions belong to the operators and data platforms credited in the app's
Settings, each under its own terms. Where the app falls back to [Transitous](https://transitous.org)
outside its own regions, see [transitous.org/sources](https://transitous.org/sources/).

## Licence

The code is MIT licensed (see `LICENSE`). The bundled Archivo and Space Mono fonts are under the
SIL Open Font License (`BusBus/Resources/Fonts`).
