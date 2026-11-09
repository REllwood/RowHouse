import Testing
@testable import RowHouseCore

@Suite("Automation drafts")
@MainActor
struct AutomationDraftTests {
    private func saved() throws -> (BaseDocument, String) {
        let doc = TestSupport.document()
        let id = doc.createAutomation(name: "Notify", trigger: AutomationTrigger(kind: .recordCreated), actions: [], enabled: true)
        return (doc, id)
    }

    @Test func savingKeepsChangesMadeElsewhereMeanwhile() throws {
        let (doc, id) = try saved()
        var draft = AutomationDraft(try #require(doc.automation(id)))
        draft.model.name = "Notify the team"
        // Meanwhile the automation is switched off from the list, or on another Mac.
        doc.updateAutomation(id) { $0.enabled = false }

        doc.updateAutomation(id) { $0 = draft.applied(to: $0) }
        let result = try #require(doc.automation(id))
        #expect(result.name == "Notify the team")
        #expect(result.enabled == false)
    }

    @Test func changesElsewhereReachTheDraftWithoutLosingEdits() throws {
        let (doc, id) = try saved()
        var draft = AutomationDraft(try #require(doc.automation(id)))
        draft.model.name = "Notify the team"
        doc.updateAutomation(id) { $0.description = "Written by an assistant" }

        draft.savedVersionChanged(to: try #require(doc.automation(id)))
        #expect(draft.model.name == "Notify the team")
        #expect(draft.model.description == "Written by an assistant")
        #expect(draft.hasEdits)
    }

    @Test func undoingEveryEditLeavesNothingToSave() throws {
        let (doc, id) = try saved()
        var draft = AutomationDraft(try #require(doc.automation(id)))
        draft.model.name = "Typo"
        draft.model.name = "Notify"
        #expect(!draft.hasEdits)
    }
}
