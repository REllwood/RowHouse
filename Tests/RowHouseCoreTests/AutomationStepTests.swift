import Testing
@testable import RowHouseCore

@Suite("Automation step references")
struct AutomationStepTests {
    private func automation() -> AutomationModel {
        var find = AutomationAction(kind: .findRecords)
        find.label = "Find"
        var notify = AutomationAction(kind: .sendNotification)
        notify.label = "Notify"
        var create = AutomationAction(kind: .createRecord)
        create.fieldValues = ["name": "{{steps.1.items.title}} and {{ steps.2.count | json }}"]
        create.repeatFrom = 1
        create.repeatPath = "items"
        return AutomationModel(id: "aut1", name: "A", description: "", enabled: true,
                               trigger: AutomationTrigger(kind: .manual), actions: [find, notify, create], order: 0)
    }

    @Test func movingStepsKeepsTokensPointingAtTheSameSteps() {
        var model = automation()
        model.swapActions(0, 1)
        #expect(model.actions.map(\.label) == ["Notify", "Find", nil])
        #expect(model.actions[2].fieldValues?["name"] == "{{steps.2.items.title}} and {{ steps.1.count | json }}")
        #expect(model.actions[2].repeatFrom == 2)
    }

    @Test func removingAStepBreaksItsReferencesInsteadOfShiftingThem() {
        var model = automation()
        model.removeAction(at: 0)
        #expect(model.actions[1].fieldValues?["name"] == "{{steps.deleted.items.title}} and {{ steps.1.count | json }}")
        #expect(model.actions[1].repeatFrom == nil)
        #expect(model.actions[1].repeatPath == nil)
    }

    @Test func otherTextIsLeftAlone() {
        #expect(AutomationModel.renumberingTokens(in: "steps.1 without braces, {{trigger.steps.1}}", { $0 + 1 }) == "steps.1 without braces, {{trigger.steps.1}}")
        #expect(AutomationModel.renumberingTokens(in: "{{steps.12}}", { $0 + 1 }) == "{{steps.13}}")
    }
}
