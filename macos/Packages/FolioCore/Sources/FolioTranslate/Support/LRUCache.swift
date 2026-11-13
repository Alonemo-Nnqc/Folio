import Foundation

/// A thread-safe dictionary of at most `capacity` entries that drops the one used longest ago to make room.
final class LRUCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    let capacity: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0
    private let lock = NSLock()

    init(capacity: Int) { self.capacity = max(capacity, 1) }

    var count: Int { lock.withLock { entries.count } }

    subscript(key: Key) -> Value? {
        get {
            lock.withLock {
                guard let entry = entries[key] else { return nil }
                clock += 1
                entries[key] = (entry.value, clock)
                return entry.value
            }
        }
        set {
            lock.withLock {
                guard let newValue else { entries[key] = nil; return }
                clock += 1
                entries[key] = (newValue, clock)
                if entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                    entries[oldest] = nil
                }
            }
        }
    }

    func removeAll() { lock.withLock { entries.removeAll() } }
}
