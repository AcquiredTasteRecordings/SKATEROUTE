// Services/System/QueryCache.swift
// Shared lightweight LRU cache for short-lived query results.

import Foundation

/// Small in-memory cache with deterministic MRU ordering under concurrent main-actor access.
/// Actor isolation keeps mutations serialized without additional locking.
@MainActor
final class QueryCache<Key: Hashable, Value> {
    private let capacity: Int
    private var dict: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func value(forKey key: Key) -> Value? {
        guard let value = dict[key] else { return nil }
        // move to front (MRU)
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.insert(key, at: 0)
        return value
    }

    func setValue(_ value: Value, forKey key: Key) {
        dict[key] = value
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.insert(key, at: 0)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let lru = order.removeLast()
            dict.removeValue(forKey: lru)
        }
    }

    #if DEBUG
    /// Returns cached keys in MRU order (front is most recent).
    func debugOrder() -> [Key] { order }
    #endif
}
