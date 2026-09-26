import Foundation

public enum ChangeOrigin: Sendable, Equatable {
    /// A change made by the person using this Mac.
    case local
    /// A change merged in from another device's log.
    case remote
    /// A change made by an automation step; `depth` guards against runaway chains.
    case automation(depth: Int)

    public var isRemote: Bool { self == .remote }

    public var automationDepth: Int {
        if case .automation(let depth) = self { return depth }
        return 0
    }
}

public struct ChangeSet: Sendable {
    public var origin: ChangeOrigin
    /// record id → table id
    public var createdRecords: [String: String] = [:]
    /// record id → changed field ids
    public var updatedRecords: [String: Set<String>] = [:]
    /// record id → table id
    public var deletedRecords: [String: String] = [:]
    /// Records brought back by undo/redo (record id → table id).
    public var restoredRecords: [String: String] = [:]
    public var reorderedTables: Set<String> = []
    public var schemaChanged = false
    public var automationsChanged = false
    public var commentsChanged = false
    public var baseInfoChanged = false
    public var affectedTables: Set<String> = []

    public init(origin: ChangeOrigin) {
        self.origin = origin
    }

    public var isEmpty: Bool {
        createdRecords.isEmpty && updatedRecords.isEmpty && deletedRecords.isEmpty && restoredRecords.isEmpty && reorderedTables.isEmpty
            && !schemaChanged && !automationsChanged && !commentsChanged && !baseInfoChanged
    }

    public mutating func formUnion(_ other: ChangeSet) {
        createdRecords.merge(other.createdRecords) { _, new in new }
        for (id, fields) in other.updatedRecords { updatedRecords[id, default: []].formUnion(fields) }
        deletedRecords.merge(other.deletedRecords) { _, new in new }
        restoredRecords.merge(other.restoredRecords) { _, new in new }
        reorderedTables.formUnion(other.reorderedTables)
        schemaChanged = schemaChanged || other.schemaChanged
        automationsChanged = automationsChanged || other.automationsChanged
        commentsChanged = commentsChanged || other.commentsChanged
        baseInfoChanged = baseInfoChanged || other.baseInfoChanged
        affectedTables.formUnion(other.affectedTables)
    }

    public var hasRecordChanges: Bool {
        !createdRecords.isEmpty || !updatedRecords.isEmpty || !deletedRecords.isEmpty || !restoredRecords.isEmpty || !reorderedTables.isEmpty
    }
}

/// A set of property writes for one entity, the unit that transactions are built from.
public struct Mutation: Sendable {
    public var kind: EntityKind
    public var id: String
    public var set: [String: JSONValue]

    public init(_ kind: EntityKind, _ id: String, _ set: [String: JSONValue]) {
        self.kind = kind
        self.id = id
        self.set = set
    }
}
