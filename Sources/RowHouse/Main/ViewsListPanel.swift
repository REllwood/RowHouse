import RowHouseCore
import SwiftUI

struct ViewsListPanel: View {
    let document: BaseDocument
    let tableID: String
    var state: WindowState
    @State private var filter = ""
    @State private var renamingID: String?
    @State private var renameText = ""

    var body: some View {
        let current = state.currentView(for: tableID, in: document)
        VStack(alignment: .leading, spacing: 0) {
            if document.views(in: tableID).count > 8 {
                TextField("Find a view", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
            } else {
                Text("Views")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            List {
                ForEach(document.views(in: tableID).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { view in
                    ViewRowItem(view: view, selected: view.id == current?.id, renaming: renamingID == view.id, renameText: $renameText) {
                        document.renameView(view.id, to: renameText)
                        renamingID = nil
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.viewForTable[tableID] = view.id }
                    .contextMenu {
                        Button("Rename View") {
                            renameText = view.name
                            renamingID = view.id
                        }
                        Button("Duplicate View") {
                            if let id = document.duplicateView(view.id) { state.viewForTable[tableID] = id }
                        }
                        Divider()
                        Button("Delete View", role: .destructive) {
                            document.deleteView(view.id)
                        }
                        .disabled(document.views(in: tableID).count <= 1)
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .listRowSeparator(.hidden)
                }
                .onMove(perform: filter.isEmpty ? { indices, destination in
                    let views = document.views(in: tableID)
                    guard let from = indices.first else { return }
                    document.moveView(views[from].id, before: destination < views.count ? views[destination].id : nil)
                } : nil)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Create a view")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                ForEach(ViewType.allCases) { type in
                    Button {
                        let id = document.createView(in: tableID, name: "\(type.displayName) view", type: type)
                        state.viewForTable[tableID] = id
                    } label: {
                        HStack {
                            Image(systemName: type.symbolName)
                                .frame(width: 18)
                                .foregroundStyle(color(for: type))
                            Text(type.displayName)
                            Spacer()
                            Image(systemName: "plus").foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func color(for type: ViewType) -> Color {
        switch type {
        case .grid: .blue
        case .kanban: .green
        case .calendar: .red
        case .gallery: .purple
        case .timeline: .orange
        case .form: .pink
        case .chart: .teal
        }
    }
}

private struct ViewRowItem: View {
    let view: ViewModel
    let selected: Bool
    let renaming: Bool
    @Binding var renameText: String
    let commit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: view.type.symbolName)
                .frame(width: 18)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            if renaming {
                TextField("View name", text: $renameText)
                    .textFieldStyle(.plain)
                    .onSubmit(commit)
            } else {
                Text(view.name)
                    .lineLimit(1)
                    .fontWeight(selected ? .semibold : .regular)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
    }
}
