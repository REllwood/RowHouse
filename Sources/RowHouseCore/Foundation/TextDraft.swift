/// A text editor's draft and the stored text it started from. Only an edited draft is ever written,
/// so leaving a field you did not change never puts an old value back over one that another Mac, an AI
/// assistant or an automation saved meanwhile. An unedited draft follows the stored text.
public struct TextDraft: Equatable, Sendable {
    /// The stored text this draft is compared with.
    public private(set) var base: String
    public var text: String

    public init(stored: String, typed: String? = nil) {
        base = stored
        text = typed ?? stored
    }

    public var isEdited: Bool { text != base }

    /// The stored text changed elsewhere: an unedited draft takes it, an edited one keeps what was typed.
    public mutating func storedTextChanged(to stored: String) {
        if !isEdited { text = stored }
        base = stored
    }

    /// Writes the draft if it was edited, then treats it as saved.
    public mutating func commitIfEdited(_ commit: (String) -> Void) {
        guard isEdited else { return }
        commit(text)
        base = text
    }
}
