import Foundation

extension BaseDocument {
    /// People who can be chosen in collaborator fields, in the order they were added.
    public var people: [Person] { info.people }

    public func person(_ id: String?) -> Person? {
        guard let id else { return nil }
        return info.people.first { $0.id == id }
    }

    /// The person whose id, name or email is `text` (ignoring case).
    public func person(matching text: String) -> Person? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let all = info.people
        return all.first { $0.id == needle }
            ?? all.first { !$0.email.isEmpty && $0.email.caseInsensitiveCompare(needle) == .orderedSame }
            ?? all.first { !$0.name.isEmpty && $0.name == needle }
            ?? all.first { $0.matches(needle) }
    }

    /// Adds a person to the base. Returns nil when both the name and the email are empty.
    @discardableResult
    public func addPerson(name: String, email: String = "", color: ChoiceColor? = nil) -> Person? {
        let person = Person(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color ?? .cycling(people.count)
        )
        guard !person.name.isEmpty || !person.email.isEmpty else { return nil }
        commit([peopleMutation(people + [person])], actionName: "Add Collaborator")
        return person
    }

    /// Adds several people in one change (used by imports).
    public func addPeople(_ newPeople: [Person]) {
        let existing = Set(people.map(\.id))
        let added = newPeople.filter { !existing.contains($0.id) }
        guard !added.isEmpty else { return }
        commit([peopleMutation(people + added)], actionName: "Add Collaborators")
    }

    public func updatePerson(_ person: Person) {
        var all = people
        guard let index = all.firstIndex(where: { $0.id == person.id }), all[index] != person else { return }
        var updated = person
        updated.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.email = person.email.trimmingCharacters(in: .whitespacesAndNewlines)
        all[index] = updated
        commit([peopleMutation(all)], actionName: "Edit Collaborator")
    }

    /// Removes a person from the base. Cells that named them show nothing for them from then on;
    /// the stored ids stay, so undoing the removal brings every value back.
    public func removePerson(_ id: String) {
        let remaining = people.filter { $0.id != id }
        guard remaining.count != people.count else { return }
        commit([peopleMutation(remaining)], actionName: "Remove Collaborator")
    }

    func peopleMutation(_ people: [Person]) -> Mutation {
        Mutation(.base, "base", ["people": JSONValue(encoding: people)])
    }

    /// A Mac shown as a person, for "Created by" and "Last modified by" fields.
    public func devicePerson(_ deviceID: String) -> Person? {
        guard !deviceID.isEmpty else { return nil }
        return Person(id: deviceID, name: deviceName(for: deviceID), color: Person.color(for: deviceID))
    }

    /// Stored collaborator value for people typed or pasted as text: names, emails or ids separated by
    /// commas. Unknown names become new people only when `createMissing` is set.
    func collaboratorValue(from text: String, field: FieldModel, createMissing: Bool) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .null }
        let tokens: [String]
        if person(matching: trimmed) != nil {
            tokens = [trimmed]
        } else {
            tokens = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var ids: [String] = []
        for token in tokens {
            if let p = person(matching: token) {
                if !ids.contains(p.id) { ids.append(p.id) }
            } else if createMissing {
                let isEmail = token.contains("@") && !token.contains(" ")
                if let p = addPerson(name: isEmail ? "" : token, email: isEmail ? token : "") { ids.append(p.id) }
            }
        }
        return storedCollaborators(ids, field: field)
    }

    /// The stored form of a list of person ids: one id, or an array when the field allows several.
    func storedCollaborators(_ ids: [String], field: FieldModel) -> JSONValue {
        guard let first = ids.first else { return .null }
        if field.options.allowMultipleCollaborators == true { return .array(ids.map(JSONValue.string)) }
        return .string(first)
    }
}

extension JSONValue {
    /// Ids stored in a collaborator cell, whichever form (single id or array) was written.
    public var collaboratorIDs: [String] {
        switch self {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .array(let items): return items.compactMap { $0.stringValue ?? $0["id"]?.stringValue }
        case .object: return self["id"]?.stringValue.map { [$0] } ?? []
        default: return []
        }
    }
}
