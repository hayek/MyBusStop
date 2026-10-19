import Foundation

/// Decides which line owns the straight spine of the map.
///
/// The trunk is the line of the next arriving bus, but two close ETAs must not make the whole
/// diagram re-lay itself every few seconds — so a change is held back until the previous one has
/// had at least half a minute to settle.
nonisolated struct TrunkSelector: Hashable, Sendable {
    static let minimumInterval: TimeInterval = 30

    var currentTrunkID: String?
    var lastChangeAt: Date?
    /// Set when the rider taps a distance spine on a portrait phone to promote it. It outranks the
    /// automatic candidate, but still goes through the same interval gate.
    var manualTrunkID: String?

    init(currentTrunkID: String? = nil, lastChangeAt: Date? = nil, manualTrunkID: String? = nil) {
        self.currentTrunkID = currentTrunkID
        self.lastChangeAt = lastChangeAt
        self.manualTrunkID = manualTrunkID
    }

    /// - Parameter candidateID: the line of the soonest arrival, or nil when nothing is coming.
    mutating func select(candidateID: String?, now: Date) -> String? {
        let desired = manualTrunkID ?? candidateID
        guard let current = currentTrunkID else {
            currentTrunkID = desired
            lastChangeAt = desired == nil ? nil : now
            return currentTrunkID
        }
        guard let desired, desired != current else { return current }
        if let lastChangeAt, now.timeIntervalSince(lastChangeAt) < Self.minimumInterval {
            return current
        }
        currentTrunkID = desired
        self.lastChangeAt = now
        return desired
    }
}
