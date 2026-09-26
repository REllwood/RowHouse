import AppKit
import RowHouseCore
import SwiftUI

struct GridContainer: View {
    @Environment(AppModel.self) private var app
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    var body: some View {
        let document = session.document
        let fields = document.visibleFields(for: view)
        let result = document.evaluate(
            view: view,
            search: state.search[view.tableID] ?? "",
            collapsedGroups: state.collapsedGroups[view.id] ?? []
        )
        let revision = document.dataRevision &+ document.schemaRevision &* 31
        GridRepresentable(session: session, view: view, fields: fields, result: result, revision: revision, state: state, commandTarget: commandTarget, runButton: runButton)
            .overlay {
                if result.recordIDs.isEmpty && !(state.search[view.tableID] ?? "").isEmpty {
                    ContentUnavailableView.search(text: state.search[view.tableID] ?? "")
                }
            }
    }

    private func runButton(recordID: String, fieldID: String) {
        guard let field = session.document.field(fieldID), let record = session.document.record(recordID) else { return }
        switch field.options.buttonAction ?? .openURL {
        case .openURL:
            if let url = session.document.compute.buttonURL(record: record, field: field) {
                NSWorkspace.shared.open(url)
            } else {
                NSSound.beep()
            }
        case .runAutomation:
            if let automationID = field.options.buttonAutomationID {
                app.engine(session.id)?.buttonClicked(automationID: automationID, recordID: recordID)
            }
        }
    }
}

struct GridRepresentable: NSViewRepresentable {
    let session: BaseSession
    let view: ViewModel
    let fields: [FieldModel]
    let result: ViewResult
    let revision: Int
    let state: WindowState
    let commandTarget: GridCommandTarget
    let runButton: (String, String) -> Void

    func makeCoordinator() -> GridController {
        GridController(session: session, view: view)
    }

    func makeNSView(context: Context) -> NSView {
        let controller = context.coordinator
        wire(controller)
        controller.update(session: session, view: view, fields: fields, result: result, revision: revision)
        DispatchQueue.main.async {
            controller.tableView.window?.makeFirstResponder(controller.tableView)
        }
        return controller.container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let controller = context.coordinator
        wire(controller)
        controller.update(session: session, view: view, fields: fields, result: result, revision: revision)
    }

    private func wire(_ controller: GridController) {
        let state = self.state
        let baseID = session.id
        let viewID = view.id
        controller.callbacks.expand = { recordID, siblings in
            state.expandedRecord = ExpandedRecord(baseID: baseID, recordID: recordID, siblings: siblings)
        }
        controller.callbacks.toggleGroup = { groupID in
            var set = state.collapsedGroups[viewID] ?? []
            if set.contains(groupID) { set.remove(groupID) } else { set.insert(groupID) }
            state.collapsedGroups[viewID] = set
        }
        controller.callbacks.collapsedGroups = { state.collapsedGroups[viewID] ?? [] }
        controller.callbacks.runButton = runButton
        commandTarget.addRecord = { [weak controller] in controller?.addRecord() }
        commandTarget.addRecordFromTemplate = { [weak controller] in controller?.addRecord(from: $0) }
        commandTarget.expandSelection = { [weak controller] in controller?.expandSelection() }
        commandTarget.deleteSelection = { [weak controller] in controller?.deleteSelection() }
        commandTarget.addField = { [weak controller] in controller?.showAddField() }
        commandTarget.fillDown = { [weak controller] in controller?.fillDown() }
    }
}
