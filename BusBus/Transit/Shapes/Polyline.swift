import Foundation

/// Encoded polyline formats the providers send route shapes in.
nonisolated enum Polyline {
    struct DecodingError: LocalizedError {
        var reason: String
        var errorDescription: String? { "Bad polyline: \(reason)" }
    }

    // MARK: Google encoded polyline

    /// Google's encoded polyline. Precision 5 is the usual one; MOTIS (Transitous) and our own disk
    /// cache use 6.
    static func decode(_ string: String, precision: Int = 5) throws -> [GeoPoint] {
        let factor = pow(10, Double(precision))
        var points: [GeoPoint] = []
        var lat = 0, lon = 0
        var bytes = string.utf8.makeIterator()

        func next() throws -> Int? {
            var result = 0, shift = 0
            while let byte = bytes.next() {
                let chunk = Int(byte) - 63
                // Real values need 30 bits at most; a longer run is garbage, and would overflow.
                guard chunk >= 0, chunk < 64, shift <= 30 else { throw DecodingError(reason: "character \(byte)") }
                result |= (chunk & 0x1f) << shift
                shift += 5
                if chunk < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            if shift > 0 { throw DecodingError(reason: "truncated") }
            return nil
        }

        while let dLat = try next() {
            guard let dLon = try next() else { throw DecodingError(reason: "odd number of values") }
            lat &+= dLat
            lon &+= dLon
            points.append(GeoPoint(lat: Double(lat) / factor, lon: Double(lon) / factor))
        }
        return points
    }

    static func encode(_ points: [GeoPoint], precision: Int = 5) -> String {
        let factor = pow(10, Double(precision))
        var output = ""
        var lastLat = 0, lastLon = 0

        func append(_ value: Int) {
            var v = value < 0 ? ~(value << 1) : value << 1
            while v >= 0x20 {
                output.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63)))
                v >>= 5
            }
            output.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        }

        for point in points {
            let lat = Int((point.lat * factor).rounded()), lon = Int((point.lon * factor).rounded())
            append(lat - lastLat)
            append(lon - lastLon)
            lastLat = lat
            lastLon = lon
        }
        return output
    }

    // MARK: HERE flexible polyline

    /// HERE's flexible polyline (https://github.com/heremaps/flexible-polyline), which bus.gov.il
    /// sends. A header gives the precision (bus.gov.il says 15) and whether a third value follows
    /// each point; the third value is read and dropped.
    static func decodeFlexible(_ string: String) throws -> [GeoPoint] {
        var values = try flexibleUnsigned(string).makeIterator()
        guard let version = values.next(), version == 1 else { throw DecodingError(reason: "flexible version") }
        guard let header = values.next() else { throw DecodingError(reason: "flexible header") }
        let precision = Int(header & 15)
        let thirdDimension = (header >> 4) & 7
        let factor = pow(10, Double(precision))

        func zigzag(_ value: UInt64) -> Int64 {
            (value & 1) != 0 ? ~Int64(bitPattern: value >> 1) : Int64(bitPattern: value >> 1)
        }

        var points: [GeoPoint] = []
        var lat: Int64 = 0, lon: Int64 = 0
        while let a = values.next() {
            guard let b = values.next() else { throw DecodingError(reason: "odd number of values") }
            lat &+= zigzag(a)
            lon &+= zigzag(b)
            if thirdDimension != 0, values.next() == nil { throw DecodingError(reason: "missing third value") }
            points.append(GeoPoint(lat: Double(lat) / factor, lon: Double(lon) / factor))
        }
        return points
    }

    private static let flexibleAlphabet: [UInt8: UInt64] = {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        return Dictionary(uniqueKeysWithValues: alphabet.utf8.enumerated().map { ($1, UInt64($0)) })
    }()

    private static func flexibleUnsigned(_ string: String) throws -> [UInt64] {
        var values: [UInt64] = []
        var result: UInt64 = 0, shift: UInt64 = 0
        for byte in string.utf8 {
            guard let chunk = flexibleAlphabet[byte], shift < 64 else { throw DecodingError(reason: "character \(byte)") }
            result |= (chunk & 0x1f) << shift
            if chunk & 0x20 != 0 {
                shift += 5
            } else {
                values.append(result)
                result = 0
                shift = 0
            }
        }
        if shift > 0 { throw DecodingError(reason: "truncated") }
        return values
    }
}
