import SwiftUI

nonisolated extension Color {
    /// `#RRGGBB`, as the artboards write them.
    nonisolated init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The twelve line colours, assigned by line id and stable across sessions.
///
/// In light mode the colour lives only in rails and badge fills: amber and cyan cannot carry text
/// on cream at any size, so numerals go ink and terminus names use a darker ink of the line colour.
nonisolated enum LinePalette {
    static let count = 12

    static let darkRail: [UInt32] = [
        0xFF3B3F, 0xFFC300, 0x22D3EE, 0x3DDC84, 0xA78BFA, 0xFF7A1A,
        0x4D8CFF, 0xFF5CA8, 0x7BE0C2, 0xE8D44D, 0xC3F53C, 0xFFA9A9,
    ]

    /// Darkened to hold at least 3:1 against the cream ground — except index 1, the brief's amber,
    /// which the brief fixes at this value and which reaches only 1.88:1.
    static let lightRail: [UInt32] = [
        0xD32029, 0xEFA400, 0x0E7C86, 0x1A7F4B, 0x6D4FD6, 0xC2520A,
        0x2461D9, 0xC8207A, 0x1E8A6E, 0x9A8A00, 0x5E8A00, 0xC04A4A,
    ]

    /// Terminus names and the tapped-bus kicker in light mode: at least 4.5:1 on cream.
    static let lightText: [UInt32] = [
        0xB01A22, 0x8A6000, 0x0B636B, 0x12603A, 0x4E37A6, 0x8F3C05,
        0x1A47A8, 0x961558, 0x146650, 0x6F6400, 0x446600, 0x8F3434,
    ]

    /// Ink or white, whichever the numeral can actually be read in.
    ///
    /// On the dark palette ink always wins, which is the rule the artboards state — every one of
    /// those twelve is bright. The light palette is darkened so it can hold its own as a rail
    /// against cream, and that leaves most of it far too dark to carry ink.
    static func numeral(on index: Int, isLight: Bool) -> Color {
        let fill = (isLight ? lightRail : darkRail)[wrap(index)]
        let ink: UInt32 = isLight ? 0x14140F : 0x08080B
        return contrast(fill, ink) >= contrast(fill, 0xFFFFFF) ? Color(hex: ink) : Color(hex: 0xFFFFFF)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let first = relativeLuminance(a), second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let part = Double(value) / 255
            return part <= 0.03928 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
            + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }

    static func rail(_ index: Int, isLight: Bool) -> Color {
        Color(hex: (isLight ? lightRail : darkRail)[wrap(index)])
    }

    static func labelText(_ index: Int, isLight: Bool) -> Color {
        Color(hex: isLight ? lightText[wrap(index)] : darkRail[wrap(index)])
    }

    static func wrap(_ index: Int) -> Int {
        let m = index % count
        return m < 0 ? m + count : m
    }
}

/// Gives every line a colour that does not move between sessions, and never lets two lines the
/// rider is watching look alike.
nonisolated enum LineColorAssigner {
    /// Hue of each palette entry, in degrees, computed from the colour itself so it stays correct
    /// if the palette is ever edited.
    static let hues: [Double] = LinePalette.darkRail.map(hue(of:))

    static func hue(of hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }
        let value: Double
        switch maximum {
        case r: value = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: value = 60 * ((b - r) / delta + 2)
        default: value = 60 * ((r - g) / delta + 4)
        }
        return value < 0 ? value + 360 : value
    }

    static func hueDistance(_ a: Int, _ b: Int) -> Double {
        let difference = abs(hues[LinePalette.wrap(a)] - hues[LinePalette.wrap(b)])
        return min(difference, 360 - difference)
    }

    /// FNV-1a over the line id, so the same line looks the same on every device and every launch.
    static func hashedIndex(for lineID: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lineID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(LinePalette.count))
    }

    /// Keeps whatever a line has been shown as before. A new line takes the colour its operator
    /// publishes, or its hashed one; if that is taken it takes the free colour furthest in hue from
    /// the ones already in use — two watched lines must be told apart at a glance, and "next free
    /// index" happily hands out mint next to green.
    static func resolve(persisted: [String: Int], selected: [String],
                        preferred: [String: Int] = [:]) -> [String: Int] {
        var result = persisted
        var taken = Set(selected.compactMap { persisted[$0] })
        /// Two hues closer than this are not worth telling apart on a rail seen across a room.
        let minimumSeparation = 40.0

        for lineID in selected where persisted[lineID] == nil {
            let wanted = preferred[lineID].map(LinePalette.wrap) ?? hashedIndex(for: lineID)
            let isClear = !taken.contains(wanted)
                && taken.allSatisfy { hueDistance($0, wanted) >= minimumSeparation }

            let index: Int
            if isClear {
                index = wanted
            } else {
                let free = (0..<LinePalette.count).filter { !taken.contains($0) }
                index = free.max { left, right in
                    separation(of: left, from: taken) < separation(of: right, from: taken)
                } ?? wanted
            }
            result[lineID] = index
            taken.insert(index)
        }
        return result
    }

    private static func separation(of index: Int, from taken: Set<Int>) -> Double {
        taken.map { hueDistance(index, $0) }.min() ?? 360
    }

    /// What to show a line as before it has ever been selected.
    static func provisionalIndex(for lineID: String, persisted: [String: Int]) -> Int {
        persisted[lineID] ?? hashedIndex(for: lineID)
    }
}
