import Foundation

/// Someone who can be picked in a collaborator field. People belong to the base, not to an account:
/// RowHouse has no sign-in, so a person is just a name, an optional email and a colour.
public struct Person: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var email: String
    public var color: ChoiceColor

    public init(id: String = RowID.person(), name: String, email: String = "", color: ChoiceColor = .blue) {
        self.id = id
        self.name = name
        self.email = email
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case id, name, email, color }

    /// Tolerates missing keys so hand-edited or older data never drops a person.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        color = (try? c.decodeIfPresent(ChoiceColor.self, forKey: .color)) ?? Person.color(for: id)
    }

    /// Filter value meaning "whoever is marked as me on this Mac" (Airtable's current user).
    public static let meToken = "@me"

    /// The name, or the email when no name was given.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return email.isEmpty ? "Unnamed" : email
    }

    /// Up to two initials for an avatar: "Ada Lovelace" → "AL", "grace@example.com" → "G".
    public var initials: String {
        let source = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(email.split(separator: "@").first ?? "")
            : name
        let words = source.split { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Whether `text` names this person: their id, name or email, ignoring case.
    public func matches(_ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        if needle == id { return true }
        if !name.isEmpty, name.caseInsensitiveCompare(needle) == .orderedSame { return true }
        return !email.isEmpty && email.caseInsensitiveCompare(needle) == .orderedSame
    }

    /// A stable colour for an id, so people (and Macs) keep their colour on every device.
    public static func color(for id: String) -> ChoiceColor {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return ChoiceColor.allCases[Int(hash % UInt32(ChoiceColor.allCases.count))]
    }
}

extension RowID {
    public static func person() -> String { make("usr") }
}
