import RowHouseCore
import SwiftUI

/// Picks people for a collaborator cell: search by name or email, click to add or remove.
struct CollaboratorEditor: View {
    let document: BaseDocument
    let field: FieldModel
    @Binding var value: JSONValue
    let style: EditorStyle
    var initialText: String?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var multi: Bool { field.options.allowMultipleCollaborators == true }

    var body: some View {
        let selectedIDs = value.collaboratorIDs.filter { document.person($0) != nil }
        let selected = (multi ? selectedIDs : Array(selectedIDs.prefix(1))).compactMap { document.person($0) }
        let people = document.people
        let needle = search.trimmingCharacters(in: .whitespaces)
        let filtered = people.filter {
            needle.isEmpty || $0.displayName.localizedCaseInsensitiveContains(needle) || $0.email.localizedCaseInsensitiveContains(needle)
        }
        VStack(alignment: .leading, spacing: 8) {
            if !selected.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selected) { person in
                        HStack(spacing: 3) {
                            PersonChip(person: person)
                            Button {
                                remove(person.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(person.displayName)")
                        }
                    }
                }
            }
            if style != .detail || selected.isEmpty || multi {
                TextField("Find or add a collaborator", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filtered.first { toggle(first.id) } else { addFromSearch() }
                    }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { person in
                            Button {
                                toggle(person.id)
                            } label: {
                                HStack(spacing: 6) {
                                    PersonChip(person: person)
                                    if !person.email.isEmpty, !person.name.isEmpty {
                                        Text(person.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if selected.contains(where: { $0.id == person.id }) {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if !needle.isEmpty, !people.contains(where: { $0.matches(needle) }) {
                            Button {
                                addFromSearch()
                            } label: {
                                Label("Add “\(needle)” as a collaborator", systemImage: "person.badge.plus")
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        if people.isEmpty && needle.isEmpty {
                            Text("No collaborators yet. Type a name or email to add someone, or choose Collaborators… from the base's menu in the sidebar.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6)
                        }
                    }
                }
                .frame(maxHeight: style == .popover ? 260 : 180)
            } else {
                Menu("Change") {
                    ForEach(people) { person in Button(person.displayName) { toggle(person.id) } }
                }
                .fixedSize()
            }
        }
        .onAppear {
            if let initialText {
                search = initialText
                searchFocused = true
            } else if style == .popover {
                searchFocused = true
            }
        }
    }

    private func store(_ ids: [String]) {
        if ids.isEmpty {
            value = .null
        } else {
            value = multi ? .array(ids.map(JSONValue.string)) : .string(ids[0])
        }
    }

    private func toggle(_ id: String) {
        var ids = value.collaboratorIDs.filter { document.person($0) != nil }
        if multi {
            if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        } else {
            ids = ids.first == id ? [] : [id]
        }
        store(ids)
        search = ""
    }

    private func remove(_ id: String) {
        store(value.collaboratorIDs.filter { $0 != id && document.person($0) != nil })
    }

    private func addFromSearch() {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let isEmail = text.contains("@") && !text.contains(" ")
        guard let person = document.addPerson(name: isEmail ? "" : text, email: isEmail ? text : "") else { return }
        var ids = multi ? value.collaboratorIDs.filter { document.person($0) != nil } : []
        ids.append(person.id)
        store(ids)
        search = ""
    }
}

/// Chooses people for filter conditions and default values.
struct PeoplePickerMenu: View {
    let document: BaseDocument
    @Binding var selected: [String]
    var allowsMultiple = true
    var placeholder = "Choose people"

    var body: some View {
        Menu {
            ForEach(document.people) { person in
                Button {
                    if allowsMultiple {
                        if let i = selected.firstIndex(of: person.id) { selected.remove(at: i) } else { selected.append(person.id) }
                    } else {
                        selected = selected == [person.id] ? [] : [person.id]
                    }
                } label: {
                    if selected.contains(person.id) {
                        Label(person.displayName, systemImage: "checkmark")
                    } else {
                        Text(person.displayName)
                    }
                }
            }
            if document.people.isEmpty {
                Text("No collaborators yet")
            }
        } label: {
            let names = selected.compactMap { document.person($0)?.displayName }
            Text(names.isEmpty ? placeholder : names.joined(separator: ", "))
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
