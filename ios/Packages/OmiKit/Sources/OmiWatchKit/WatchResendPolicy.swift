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
/// them it already holds (bytes and checksum). Its answer acknowledges those (they leave as usual) and
/// names the missing ones, which are due again at once: a lost acknowledgement no longer costs
/// 30 min–4 h per item. One question is outstanding at a time (saved; replaced after
/// `inventoryRetire` if never answered), at most one every `inventoryInterval`. An answer counts once,
/// for its own question, and "missing" only for items not handed over again since it was asked.
public struct WatchResendPolicy: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        /// Handovers so far (the resend wait doubles with it); restarts after a failure.
        public var times: Int
        public var delivered: Bool
        /// This handover's number, never reused (absent in older saved state): what a question remembers.
        public var attempt: Int?
    }

    public static let unconfirmedWait: TimeInterval = 60, unconfirmedMax: TimeInterval = 600
    public static let awaitingAckWait: TimeInterval = 30 * 60, awaitingAckMax: TimeInterval = 4 * 3600

    public static let inventoryInterval: TimeInterval = 15 * 60
    public static let inventoryRetire: TimeInterval = 6 * 3600

    /// The question waiting for its answer: its id, when, and each item's handover count then.
    public struct PendingInventory: Codable, Equatable, Sendable {
        public var id: String
        public var askedAt: Date
        /// Older saved state only (handover counts, which repeat after a failure: never matched now).
        public var times: [String: Int]?
        /// Each item's attempt number when asked.
        public var attempts: [String: Int]?
    }

    public private(set) var entries: [String: Entry] = [:]
    /// When the Watch last asked which delivered items the iPhone has (absent in older saved state).
    public private(set) var inventoryAskedAt: Date?
    public private(set) var pendingInventory: PendingInventory?
    /// The next attempt number (only ever grows, saved).
    public private(set) var nextAttempt: Int?
    /// Parts an inventory answer called missing: re-checks, mostly audio an older iPhone build converted
    /// without keeping a checksum receipt. Nothing proves the server has them, so they stay unacknowledged
    /// audio in every total; they only go after new audio (`sendOrder`), for at most `recheckDefer`
    /// (absent in older saved state).
    public private(set) var recheck: Set<String>?
    /// When each re-check became due (absent in older saved state: such a re-check is served as new audio).
    public private(set) var recheckSince: [String: Date]?

    /// How long new audio may keep a re-check waiting before it is sent in recording order like the rest.
    public static let recheckDefer: TimeInterval = 10 * 60

    public init() {}

    public func due(_ id: String, now: Date) -> Bool {
        guard let e = entries[id] else { return true }
        let doubling = pow(2, Double(min(e.times - 1, 8)))
        let wait = e.delivered ? min(Self.awaitingAckMax, Self.awaitingAckWait * doubling) : min(Self.unconfirmedMax, Self.unconfirmedWait * doubling)
        return now.timeIntervalSince(e.at) >= wait
    }

    /// Handed to WatchConnectivity (again, if it has an entry).
    public mutating func handedOver(_ id: String, now: Date) {
        let attempt = nextAttempt ?? 1
        nextAttempt = attempt + 1
        entries[id] = Entry(at: now, times: (entries[id]?.times ?? 0) + 1, delivered: false, attempt: attempt)
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
        if recheck != nil { recheck?.subtract(ids) }
        for id in ids { recheckSince?[id] = nil }
    }

    /// Drops entries for items no longer waiting (acknowledged before this state was saved).
    public mutating func keep(only ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
        if recheck != nil { recheck?.formIntersection(ids) }
        recheckSince = recheckSince?.filter { ids.contains($0.key) }
    }

    /// Whether `id` is a re-check (see `recheck`).
    public func isRecheck(_ id: String) -> Bool { recheck?.contains(id) ?? false }

    public var recheckCount: Int { recheck?.count ?? 0 }

    /// Whether `id` is a re-check still deferred behind new audio at `now` (it waits at most `recheckDefer`).
    public func isDeferred(_ id: String, now: Date) -> Bool {
        guard isRecheck(id), let since = recheckSince?[id] else { return false }
        return now.timeIntervalSince(since) < Self.recheckDefer
    }

    /// New audio first (never handed over, or resent after a failure), deferred re-checks after it; stable
    /// within each. A re-check waiting longer than `recheckDefer` goes with new audio, so it is never starved.
    public func sendOrder<T>(_ items: [T], now: Date, id: (T) -> String) -> [T] {
        items.filter { !isDeferred(id($0), now: now) } + items.filter { isDeferred(id($0), now: now) }
    }

    public var awaitingAck: Int { entries.values.filter(\.delivered).count }

    /// Delivered items still waiting for an acknowledgement, oldest delivery first, at most `limit`.
    public func inventory(limit: Int) -> [String] {
        entries.filter(\.value.delivered).sorted { ($0.value.at, $0.key) < ($1.value.at, $1.key) }.prefix(limit).map(\.key)
    }

    public func inventoryDue(now: Date) -> Bool {
        guard awaitingAck > 0 else { return false }
        if let pending = pendingInventory { return now.timeIntervalSince(pending.askedAt) >= Self.inventoryRetire }
        return inventoryAskedAt.map { now.timeIntervalSince($0) >= Self.inventoryInterval } ?? true
    }

    /// A question was sent (it replaces any earlier unanswered one).
    public mutating func askInventory(id: String, ids: [String], now: Date) {
        // entries saved by an older build have no attempt number: give them one (their wait and count stay)
        for i in ids where entries[i] != nil && entries[i]?.attempt == nil {
            let attempt = nextAttempt ?? 1
            nextAttempt = attempt + 1
            entries[i]?.attempt = attempt
        }
        pendingInventory = PendingInventory(id: id, askedAt: now, times: nil,
                                            attempts: Dictionary(uniqueKeysWithValues: ids.compactMap { i in entries[i]?.attempt.map { (i, $0) } }))
        inventoryAskedAt = now
    }

    /// The answer to question `id`: its missing items that are still as they were when asked become due
    /// at once (returned). Any other or repeated answer changes nothing.
    public mutating func answeredInventory(id: String, missing: [String], now: Date = Date()) -> [String] {
        guard let pending = pendingInventory, pending.id == id else { return [] }
        pendingInventory = nil
        var due: [String] = []
        for item in missing {
            // the same handover it asked about: a later one (even after a failure) has another number
            guard let e = entries[item], e.delivered, let attempt = e.attempt, pending.attempts?[item] == attempt else { continue }
            entries[item] = nil
            due.append(item)
        }
        if !due.isEmpty {
            recheck = (recheck ?? []).union(due)
            var since = recheckSince ?? [:]
            for item in due where since[item] == nil { since[item] = now }
            recheckSince = since
        }
        return due
    }
}
