import Foundation

/// A hybrid logical clock timestamp. Ordering is total: wall time, then counter, then node id,
/// so two devices can never produce equal timestamps and merges are deterministic everywhere.
public struct HLC: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var wall: Int64
    public var counter: Int32
    public var node: String

    public init(wall: Int64, counter: Int32, node: String) {
        self.wall = wall
        self.counter = counter
        self.node = node
    }

    public static let zero = HLC(wall: 0, counter: 0, node: "")

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        if lhs.wall != rhs.wall { return lhs.wall < rhs.wall }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.node < rhs.node
    }

    public var description: String { "\(wall)-\(counter)-\(node)" }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let wall = Int64(parts[0]), let counter = Int32(parts[1]) else { return nil }
        self.init(wall: wall, counter: counter, node: String(parts[2]))
    }

    public var date: Date { Date(timeIntervalSince1970: Double(wall) / 1000) }
}

/// Thread-safe hybrid logical clock for one device.
public final class HybridClock: @unchecked Sendable {
    public let node: String
    private var last: HLC
    private let lock = NSLock()
    private let physicalTime: @Sendable () -> Int64

    public init(node: String, physicalTime: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.node = node
        self.physicalTime = physicalTime
        self.last = HLC(wall: 0, counter: 0, node: node)
    }

    public func tick() -> HLC {
        lock.lock()
        defer { lock.unlock() }
        let pt = physicalTime()
        if pt > last.wall {
            last = HLC(wall: pt, counter: 0, node: node)
        } else if last.counter == Int32.max {
            last = HLC(wall: last.wall + 1, counter: 0, node: node)
        } else {
            last = HLC(wall: last.wall, counter: last.counter + 1, node: node)
        }
        return last
    }

    /// Advances the clock past a timestamp seen from another device so later local edits win.
    public func observe(_ remote: HLC) {
        lock.lock()
        defer { lock.unlock() }
        let pt = physicalTime()
        // Remote timestamps are never clamped: a later local edit must always be able to win, even
        // against a Mac whose clock runs fast. Only guard the counter against overflow.
        var remote = remote
        if remote.counter == Int32.max { remote.counter = Int32.max - 1 }
        if last.counter == Int32.max { last = HLC(wall: last.wall + 1, counter: 0, node: node) }
        let wall = max(last.wall, remote.wall, pt)
        let counter: Int32
        if wall == last.wall && wall == remote.wall {
            counter = max(last.counter, remote.counter) + 1
        } else if wall == last.wall {
            counter = last.counter + 1
        } else if wall == remote.wall {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        last = HLC(wall: wall, counter: counter, node: node)
    }

    public var current: HLC {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}
