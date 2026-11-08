import Foundation

/// When the Watch sends an item (segment or recording end) to the iPhone again. Only the iPhone's
/// acknowledgement (sent after it has stored the item durably) removes an item from the Watch; a
/// transfer WatchConnectivity reports as finished is delivered, not acknowledged. So:
///
/// - Handed over, outcome not seen (e.g. the app restarted meanwhile): sent again soon (1 min,
///   doubling to 10 min), as before.
/// - Delivered without an acknowledgement yet: the iPhone has it or will process it when Omi Notes
///   runs; sent again only after a long wait (30 min, doubling to 4 h), so a lost acknowledgement or
///   a receiver that lost the file still recovers, without resending whole files every few minutes.
/// - Failed: due again at once (the caller's failure backoff spaces the attempts).
///
/// The state is saved (it is small), so a restart doesn't resend everything delivered at once.
///
/// Inventory: while delivered items wait for an acknowledgement, the Watch asks the iPhone which of
/// them it already has (at most every `inventoryInterval`). Its answer acknowledges those (they leave
/// as usual) and names the missing ones, which are due again at once: a lost acknowledgement no
/// longer costs 30 min–4 h per item.
public struct WatchResendPolicy: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        public var times: Int
        public var delivered: Bool
    }

    public static let unconfirmedWait: TimeInterval = 60, unconfirmedMax: TimeInterval = 600
    public static let awaitingAckWait: TimeInterval = 30 * 60, awaitingAckMax: TimeInterval = 4 * 3600

    public static let inventoryInterval: TimeInterval = 15 * 60

    public private(set) var entries: [String: Entry] = [:]
    /// When the Watch last asked which delivered items the iPhone has (absent in older saved state).
    public private(set) var inventoryAskedAt: Date?

    public init() {}

    public func due(_ id: String, now: Date) -> Bool {
        guard let e = entries[id] else { return true }
        let doubling = pow(2, Double(min(e.times - 1, 8)))
        let wait = e.delivered ? min(Self.awaitingAckMax, Self.awaitingAckWait * doubling) : min(Self.unconfirmedMax, Self.unconfirmedWait * doubling)
        return now.timeIntervalSince(e.at) >= wait
    }

    /// Handed to WatchConnectivity (again, if it has an entry).
    public mutating func handedOver(_ id: String, now: Date) {
        entries[id] = Entry(at: now, times: (entries[id]?.times ?? 0) + 1, delivered: false)
    }

    /// WatchConnectivity finished the transfer without an error: the long wait starts now.
    public mutating func delivered(_ id: String, now: Date) {
        guard var e = entries[id] else { return }
        e.delivered = true
        e.at = now
        entries[id] = e
    }

    /// The transfer failed: due again (after the caller's failure backoff).
    public mutating func failed(_ id: String) {
        entries[id] = nil
    }

    public mutating func acknowledged(_ ids: [String]) {
        for id in ids { entries[id] = nil }
    }

    /// Drops entries for items no longer waiting (acknowledged before this state was saved).
    public mutating func keep(only ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    public var awaitingAck: Int { entries.values.filter(\.delivered).count }

    /// Delivered items still waiting for an acknowledgement, oldest delivery first, at most `limit`.
    public func inventory(limit: Int) -> [String] {
        entries.filter(\.value.delivered).sorted { ($0.value.at, $0.key) < ($1.value.at, $1.key) }.prefix(limit).map(\.key)
    }

    public func inventoryDue(now: Date) -> Bool {
        awaitingAck > 0 && inventoryAskedAt.map { now.timeIntervalSince($0) >= Self.inventoryInterval } ?? true
    }

    public mutating func askedInventory(now: Date) { inventoryAskedAt = now }

    /// The iPhone doesn't have these: due again at once (still kept until acknowledged).
    public mutating func missing(_ ids: [String]) {
        for id in ids where entries[id]?.delivered == true { entries[id] = nil }
    }
}
