import Foundation

public struct BufferedEvent: Codable, Sendable, Equatable {
    public let seq: UInt64
    public let vendor: VendorID
    public let event: ContainedEvent
}

public enum BufferOutcome: Sendable, Equatable {
    case buffered
    /// Buffered, and the vendor's oldest event was evicted to make room.
    case bufferedEvictingOldest
    /// `.personal` events are never written to disk.
    case refusedPersonal
    case refusedNoCapacity
}

/// A bounded, per-vendor, privacy-aware holding queue for events a vendor
/// can't take yet (not started, quarantined, paused by policy).
///
/// Capacity is **per vendor**, and overflow evicts that vendor's own oldest
/// event, so one noisy quarantined SDK can never push out another vendor's
/// data. Order within a vendor's queue is array order; `seq` is a stable
/// identity for each event (used to remove exactly the event that was sent).
public struct EventBuffer: Codable, Sendable, Equatable {
    public let capacityPerVendor: Int
    public private(set) var queues: [VendorID: [BufferedEvent]] = [:]
    public private(set) var nextSeq: UInt64 = 0
    public private(set) var evicted: Int = 0
    public private(set) var expired: Int = 0
    public private(set) var refused: Int = 0

    public init(capacityPerVendor: Int) {
        self.capacityPerVendor = capacityPerVendor
    }

    public func pending(for vendor: VendorID) -> [BufferedEvent] { queues[vendor] ?? [] }
    public func count(for vendor: VendorID) -> Int { queues[vendor]?.count ?? 0 }
    public var totalCount: Int { queues.values.reduce(0) { Saturating.add($0, $1.count) } }

    @discardableResult
    public mutating func append(_ event: ContainedEvent, for vendor: VendorID) -> BufferOutcome {
        guard event.privacy != .personal else {
            refused = Saturating.increment(refused)
            return .refusedPersonal
        }
        guard capacityPerVendor > 0 else {
            refused = Saturating.increment(refused)
            return .refusedNoCapacity
        }
        var queue = queues[vendor] ?? []
        var outcome = BufferOutcome.buffered
        while queue.count >= capacityPerVendor, !queue.isEmpty {
            queue.removeFirst()
            evicted = Saturating.increment(evicted)
            outcome = .bufferedEvictingOldest
        }
        queue.append(BufferedEvent(seq: nextSeq, vendor: vendor, event: event))
        // Saturates rather than wraps; at UInt64.max ties are possible but
        // order within a queue is still array order, which is append order.
        nextSeq = Saturating.increment(nextSeq)
        queues[vendor] = queue
        return outcome
    }

    /// A copy with a new per-vendor capacity, preserving global order and
    /// the lifetime counters.
    public func resized(to capacity: Int) -> EventBuffer {
        var fresh = EventBuffer(capacityPerVendor: capacity)
        fresh.nextSeq = nextSeq
        fresh.evicted = evicted
        fresh.expired = expired
        fresh.refused = refused
        let all = queues.values.flatMap { $0 }.sorted { $0.seq < $1.seq }
        for item in all {
            var queue = fresh.queues[item.vendor] ?? []
            if capacity <= 0 {
                fresh.evicted = Saturating.increment(fresh.evicted)
                continue
            }
            if queue.count >= capacity {
                queue.removeFirst()
                fresh.evicted = Saturating.increment(fresh.evicted)
            }
            queue.append(item) // keeps the original seq
            fresh.queues[item.vendor] = queue
        }
        return fresh
    }

    /// The vendor's oldest queued event, left in place.
    public func first(for vendor: VendorID) -> BufferedEvent? { queues[vendor]?.first }

    /// Removes the vendor's head event if it is still `seq`. The check keeps
    /// a stale caller from removing a different event that became the head.
    @discardableResult
    public mutating func removeHead(for vendor: VendorID, ifSeq seq: UInt64) -> Bool {
        guard var queue = queues[vendor], let head = queue.first, head.seq == seq else { return false }
        queue.removeFirst()
        queues[vendor] = queue.isEmpty ? nil : queue
        return true
    }

    /// Drops events older than `maxAge`. A non-finite or negative `maxAge`
    /// expires nothing rather than everything.
    public mutating func expire(olderThan maxAge: TimeInterval, now: Date) {
        guard maxAge.isFinite, maxAge >= 0 else { return }
        for (vendor, queue) in queues {
            let kept = queue.filter { now.timeIntervalSince($0.event.at) <= maxAge }
            expired = Saturating.add(expired, queue.count - kept.count)
            queues[vendor] = kept.isEmpty ? nil : kept
        }
    }

    /// Discards everything queued for a vendor (a privacy kill).
    public mutating func purge(_ vendor: VendorID) -> Int {
        let n = queues[vendor]?.count ?? 0
        queues[vendor] = nil
        return n
    }
}
