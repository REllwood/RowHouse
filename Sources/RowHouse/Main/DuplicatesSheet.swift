import RowHouseCore
import SwiftUI

/// Finds records that share values in chosen fields and merges each group into one record.
struct DuplicatesSheet: View {
    let session: BaseSession
    let tableID: String
    let state: WindowState
    @Environment(\.dismiss) private var dismiss
    @State private var fieldIDs: [String] = []
    @State private var matchCase = false
    @State private var keepers: [String: String] = [:]
    @State private var merged = 0

    var body: some View {
        let document = session.document
        let _ = document.dataRevision
        let candidates = document.fields(in: tableID).filter { $0.type != .button && $0.type != .attachment }
        let groups = fieldIDs.isEmpty ? [] : document.findDuplicates(in: tableID, fieldIDs: fieldIDs, matchCase: matchCase)
        VStack(alignment: .leading, spacing: 14) {
            Text("Find Duplicates").font(.title2.bold())
            HStack(spacing: 12) {
                Menu {
                    ForEach(candidates) { f in
                        Button {
                            if let i = fieldIDs.firstIndex(of: f.id) { fieldIDs.remove(at: i) } else { fieldIDs.append(f.id) }
                            keepers = [:]
                        } label: {
                            Label(f.name, systemImage: fieldIDs.contains(f.id) ? "checkmark" : f.type.symbolName)
                        }
                    }
                } label: {
                    Text(fieldIDs.isEmpty ? "Choose fields to compare" : "Matching " + fieldIDs.compactMap { document.field($0)?.name }.joined(separator: " + "))
                }
                .fixedSize()
                Toggle("Match case", isOn: $matchCase).toggleStyle(.checkbox)
                Spacer()
            }
            if fieldIDs.isEmpty {
                ContentUnavailableView("Pick the fields that identify a record", systemImage: "square.on.square.dashed",
                                       description: Text("Records whose values match in every chosen field are grouped. Spacing and case are ignored unless you turn on Match case."))
                    .frame(maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "checkmark.circle", description: Text(merged > 0 ? "Merged \(merged) record\(merged == 1 ? "" : "s")." : "Every record is unique on these fields."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.recordIDs, id: \.self) { rid in
                                row(rid, group: group, document: document)
                            }
                        } header: {
                            HStack {
                                Text(group.key).lineLimit(1)
                                Spacer()
                                Button("Merge \(group.recordIDs.count)") { merge(group) }
                                    .buttonStyle(.borderless)
                                    .help("Keep the selected record, fill its empty fields from the others and move the others to the trash")
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
            HStack {
                Text(groups.isEmpty ? " " : "\(groups.count) group\(groups.count == 1 ? "" : "s") · \(groups.reduce(0) { $0 + $1.recordIDs.count }) records")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge All") { groups.forEach(merge) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(groups.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear {
            if fieldIDs.isEmpty, let primary = document.primaryField(of: tableID) { fieldIDs = [primary.id] }
        }
    }

    private func row(_ rid: String, group: DuplicateGroup, document: BaseDocument) -> some View {
        let keeper = keepers[group.id] ?? group.recordIDs[0]
        let record = document.record(rid)
        let details = document.fields(in: tableID).prefix(5).dropFirst().compactMap { f -> String? in
            guard let record else { return nil }
            let text = document.displayString(record, f)
            return text.isEmpty ? nil : "\(f.name): \(text)"
        }
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: keeper == rid ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(keeper == rid ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.primaryTitle(recordID: rid).isEmpty ? "Unnamed record" : document.primaryTitle(recordID: rid))
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if keeper == rid { Text("Keep").font(.caption).foregroundStyle(.secondary) }
            Button {
                dismiss()
                let expanded = ExpandedRecord(baseID: session.id, recordID: rid, siblings: group.recordIDs)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { state.expandedRecord = expanded }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Open record")
        }
        .contentShape(Rectangle())
        .onTapGesture { keepers[group.id] = rid }
    }

    private func merge(_ group: DuplicateGroup) {
        let keeper = keepers[group.id] ?? group.recordIDs[0]
        session.document.mergeRecords(keeping: keeper, merging: group.recordIDs.filter { $0 != keeper })
        merged += group.recordIDs.count - 1
        keepers[group.id] = nil
    }
}
