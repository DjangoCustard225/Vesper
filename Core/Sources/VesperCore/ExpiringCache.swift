import Foundation

/// A small actor-owned memory cache. Reads never extend an entry's freshness.
struct ExpiringCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let savedAt: Date
        let value: Value
    }
    private let lifetime: TimeInterval
    private let capacity: Int
    private var entries: [String: Entry] = [:]

    init(lifetime: TimeInterval, capacity: Int) {
        precondition(lifetime > 0 && capacity > 0)
        self.lifetime = lifetime
        self.capacity = capacity
    }

    mutating func value(for key: String, now: Date = Date()) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.savedAt) < lifetime else {
            entries[key] = nil
            return nil
        }
        return entry.value
    }

    mutating func insert(_ value: Value, for key: String, now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.savedAt) < lifetime }
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.savedAt < $1.value.savedAt })?.key {
            entries[oldest] = nil
        }
        entries[key] = Entry(savedAt: now, value: value)
    }

    mutating func removeAll() { entries.removeAll() }
}
