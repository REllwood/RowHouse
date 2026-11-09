import Testing
@testable import RowHouseCore

@Suite("Text drafts")
struct TextDraftTests {
    @Test func anUneditedDraftNeverWritesBackAnOldValue() {
        var draft = TextDraft(stored: "Draft agenda")
        // Another Mac or an AI assistant changes the value while the field has focus.
        draft.storedTextChanged(to: "Final agenda")
        #expect(draft.text == "Final agenda")
        var written: [String] = []
        draft.commitIfEdited { written.append($0) }
        #expect(written.isEmpty)
    }

    @Test func anEditedDraftKeepsWhatWasTypedAndWritesItOnce() {
        var draft = TextDraft(stored: "Draft agenda")
        draft.text = "My agenda"
        draft.storedTextChanged(to: "Final agenda")
        #expect(draft.text == "My agenda")
        var written: [String] = []
        draft.commitIfEdited { written.append($0) }
        draft.commitIfEdited { written.append($0) }
        #expect(written == ["My agenda"])
    }

    @Test func typingTheValueThatArrivedIsNotAnEdit() {
        var draft = TextDraft(stored: "A")
        draft.text = "B"
        draft.storedTextChanged(to: "B")
        #expect(!draft.isEdited)
    }

    @Test func typeToEditStartsAsAnEdit() {
        var draft = TextDraft(stored: "", typed: "x")
        #expect(draft.isEdited)
        var written: [String] = []
        draft.commitIfEdited { written.append($0) }
        #expect(written == ["x"])
    }
}
