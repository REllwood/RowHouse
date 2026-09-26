import Foundation

public enum EntityKind: String, CaseIterable, Sendable, Codable {
    case base
    case table
    case field
    case view
    case record
    case automation
    case comment
    case device
}

/// One atomic change: set some properties of one entity at one timestamp.
public struct ChangeOperation: Hashable, Sendable {
    public var ts: HLC
    public var kind: EntityKind
    public var id: String
    public var set: [String: JSONValue]

    public init(ts: HLC, kind: EntityKind, id: String, set: [String: JSONValue]) {
        self.ts = ts
        self.kind = kind
        self.id = id
        self.set = set
    }

    public var json: JSONValue {
        .object(["t": .string(ts.description), "k": .string(kind.rawValue), "i": .string(id), "s": .object(set)])
    }

    public init?(json: JSONValue) {
        guard let t = json["t"]?.stringValue, let ts = HLC(t),
              let k = json["k"]?.stringValue, let kind = EntityKind(rawValue: k),
              let id = json["i"]?.stringValue,
              let set = json["s"]?.objectValue
        else { return nil }
        self.init(ts: ts, kind: kind, id: id, set: set)
    }
}

/// A last-writer-wins register.
public struct Register: Hashable, Sendable {
    public var value: JSONValue
    public var ts: HLC

    public init(value: JSONValue, ts: HLC) {
        self.value = value
        self.ts = ts
    }
}

public struct EntityState: Hashable, Sendable {
    public var props: [String: Register] = [:]

    public init(props: [String: Register] = [:]) {
        self.props = props
    }

    public subscript(key: String) -> JSONValue? { props[key]?.value }

    /// Latest timestamp across the given properties (or all when nil).
    public func latestTimestamp(excluding systemKeys: Bool = false) -> HLC? {
        var best: HLC?
        for (key, reg) in props where !(systemKeys && key.hasPrefix("_")) {
            if best == nil || reg.ts > best! { best = reg.ts }
        }
        return best
    }
}

/// The complete, mergeable state of a base: every property of every entity as an LWW register.
/// `merge` and `apply` are commutative, associative and idempotent, so any device that has seen
/// the same set of operations — in any order, any number of times — ends up with identical state.
public struct BaseState: Sendable {
    public private(set) var entities: [EntityKind: [String: EntityState]] = [:]
    public private(set) var latest: HLC = .zero

    public init() {}

    public func entity(_ kind: EntityKind, _ id: String) -> EntityState? {
        entities[kind]?[id]
    }

    public func ids(of kind: EntityKind) -> Dictionary<String, EntityState>.Keys? {
        entities[kind]?.keys
    }

    public func all(_ kind: EntityKind) -> [String: EntityState] {
        entities[kind] ?? [:]
    }

    /// Applies an operation and returns the property keys whose value actually changed.
    @discardableResult
    public mutating func apply(_ op: ChangeOperation) -> [String] {
        if op.ts > latest { latest = op.ts }
        // Mutate through the nested subscripts in place; copying the bucket out would copy
        // every entity of that kind on each write.
        return Self.write(op.set, at: op.ts, into: &entities[op.kind, default: [:]][op.id, default: EntityState()])
    }

    private static func write(_ set: [String: JSONValue], at ts: HLC, into entity: inout EntityState) -> [String] {
        var changed: [String] = []
        for (key, value) in set {
            if let existing = entity.props[key], existing.ts >= ts { continue }
            let previous = entity.props.updateValue(Register(value: value, ts: ts), forKey: key)?.value
            if previous != value { changed.append(key) }
        }
        return changed
    }

    /// Merges another state, returning (kind, id, changed keys) for everything that changed.
    @discardableResult
    public mutating func merge(_ other: BaseState) -> [(EntityKind, String, [String])] {
        if other.latest > latest { latest = other.latest }
        var result: [(EntityKind, String, [String])] = []
        for (kind, otherBucket) in other.entities {
            for (id, otherEntity) in otherBucket {
                let changed = Self.merge(otherEntity, into: &entities[kind, default: [:]][id, default: EntityState()])
                if !changed.isEmpty { result.append((kind, id, changed)) }
            }
        }
        return result
    }

    private static func merge(_ other: EntityState, into entity: inout EntityState) -> [String] {
        var changed: [String] = []
        for (key, reg) in other.props {
            if let existing = entity.props[key], existing.ts >= reg.ts { continue }
            let previous = entity.props.updateValue(reg, forKey: key)?.value
            if previous != reg.value { changed.append(key) }
        }
        return changed
    }

    // MARK: Serialization — {"kind": {"id": {"key": [value, "ts"]}}}

    public var json: JSONValue {
        var out: [String: JSONValue] = [:]
        for (kind, bucket) in entities {
            var b: [String: JSONValue] = [:]
            b.reserveCapacity(bucket.count)
            for (id, entity) in bucket {
                var e: [String: JSONValue] = [:]
                e.reserveCapacity(entity.props.count)
                for (key, reg) in entity.props {
                    e[key] = .array([reg.value, .string(reg.ts.description)])
                }
                b[id] = .object(e)
            }
            out[kind.rawValue] = .object(b)
        }
        return .object(out)
    }

    public init(json: JSONValue) {
        guard let root = json.objectValue else { return }
        for (kindName, bucketValue) in root {
            guard let kind = EntityKind(rawValue: kindName), let bucket = bucketValue.objectValue else { continue }
            var b: [String: EntityState] = [:]
            b.reserveCapacity(bucket.count)
            for (id, entityValue) in bucket {
                guard let props = entityValue.objectValue else { continue }
                var e = EntityState()
                e.props.reserveCapacity(props.count)
                for (key, pair) in props {
                    guard let arr = pair.arrayValue, arr.count == 2, let tsString = arr[1].stringValue,
                          let ts = HLC(tsString) else { continue }
                    e.props[key] = Register(value: arr[0], ts: ts)
                    if ts > latest { latest = ts }
                }
                b[id] = e
            }
            entities[kind] = b
        }
    }
}
