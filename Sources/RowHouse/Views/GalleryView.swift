import RowHouseCore
import SwiftUI

struct GalleryView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    private var document: BaseDocument { session.document }

    var body: some View {
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "")
        let fields = document.cardFields(for: view, excluding: [view.config.coverFieldID ?? ""], limit: 5)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)], spacing: 16) {
                ForEach(result.recordIDs, id: \.self) { id in
                    if let record = document.record(id) {
                        RecordCard(session: session, record: record, fields: fields, coverFieldID: view.config.coverFieldID, coverHeight: 150, accent: document.recordColor(record, view: view))
                            .onTapGesture { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id, siblings: result.recordIDs) }
                            .contextMenu {
                                Button("Expand Record") { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id, siblings: result.recordIDs) }
                                Button("Duplicate Record") { _ = document.duplicateRecords([id]) }
                                Divider()
                                Button("Delete Record", role: .destructive) { document.deleteRecords([id]) }
                            }
                    }
                }
                Button {
                    addRecord()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.title2)
                        Text("Add record")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5])))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .background(Color.primary.opacity(0.025))
        .onAppear {
            commandTarget.addRecord = addRecord
            commandTarget.expandSelection = {}
            commandTarget.deleteSelection = {}
        }
    }

    private func addRecord() {
        let id = document.createRecord(in: view.tableID)
        state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
    }
}
