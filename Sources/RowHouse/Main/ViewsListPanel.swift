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
        let views = document.views(in: tableID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Views")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(views.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                newViewMenu(compact: true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: Theme.barHeight)
            if views.count > 8 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("Find a view", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            List {
                ForEach(views.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { view in
                    ViewRowItem(view: view, tint: color(for: view.type), selected: view.id == current?.id, renaming: renamingID == view.id, renameText: $renameText) {
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
                        .disabled(views.count <= 1)
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: filter.isEmpty ? { indices, destination in
                    guard let from = indices.first else { return }
                    document.moveView(views[from].id, before: destination < views.count ? views[destination].id : nil)
                } : nil)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            Divider()
            newViewMenu(compact: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .background(Theme.panelBackground)
    }

    /// Menu of view types, shown as a "+" in the header or as a full-width row at the bottom of the panel.
    private func newViewMenu(compact: Bool) -> some View {
        Menu {
            Section("New view") {
                ForEach(ViewType.allCases) { type in
                    Button {
                        let id = document.createView(in: tableID, name: "\(type.displayName) view", type: type)
                        state.viewForTable[tableID] = id
                    } label: {
                        Label(type.displayName, systemImage: type.symbolName)
                    }
                }
            }
        } label: {
            if compact {
                Image(systemName: "plus")
            } else {
                Label("New view", systemImage: "plus")
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a view")
    }

    private func color(for type: ViewType) -> Color {
        switch type {
        case .grid: .blue
        case .list: .indigo
        case .kanban: .green
        case .calendar: .red
        case .gallery: .purple
        case .timeline: .orange
        case .gantt: .mint
        case .form: .pink
        case .chart: .teal
        case .dashboard: .cyan
        }
    }
}

private struct ViewRowItem: View {
    let view: ViewModel
    let tint: Color
    let selected: Bool
    let renaming: Bool
    @Binding var renameText: String
    let commit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: view.config.isLocked ? "lock.fill" : view.type.symbolName)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(tint)
            if renaming {
                TextField("View name", text: $renameText)
                    .textFieldStyle(.plain)
                    .onSubmit(commit)
            } else {
                Text(view.name)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.14) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}
