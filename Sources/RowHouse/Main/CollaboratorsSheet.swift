import RowHouseCore
import SwiftUI

/// Manages the people who can be picked in a base's collaborator fields.
struct CollaboratorsSheet: View {
    let document: BaseDocument
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var confirmRemove: Person?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Collaborators").font(.title2.weight(.semibold))
                Text("People you can choose in collaborator fields of “\(document.info.name)”. They sync with the base; nobody needs an account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                if document.people.isEmpty {
                    Text("No collaborators yet.").foregroundStyle(.secondary)
                }
                ForEach(document.people) { person in
                    PersonRow(document: document, person: person) { confirmRemove = person }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)
            HStack(spacing: 8) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                TextField("Email (optional)", text: $newEmail)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty && newEmail.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .confirmationDialog("Remove \(confirmRemove?.displayName ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let person = confirmRemove { document.removePerson(person.id) }
                confirmRemove = nil
            }
        } message: {
            Text("They disappear from collaborator cells and can no longer be chosen. You can undo this with ⌘Z.")
        }
    }

    private func add() {
        guard document.addPerson(name: newName, email: newEmail) != nil else { return }
        newName = ""
        newEmail = ""
    }
}

private struct PersonRow: View {
    let document: BaseDocument
    let person: Person
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ChoiceColor.allCases, id: \.self) { color in
                    Button {
                        update { $0.color = color }
                    } label: {
                        Label(color.displayName, systemImage: person.color == color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                PersonAvatar(person: person, size: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Colour")
            CommitTextField(text: person.name, prompt: "Name") { name in update { $0.name = name } }
            CommitTextField(text: person.email, prompt: "Email") { email in update { $0.email = email } }
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(person.displayName)")
        }
    }

    private func update(_ change: (inout Person) -> Void) {
        guard var current = document.person(person.id) else { return }
        change(&current)
        let trimmedName = current.name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = current.email.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty || !trimmedEmail.isEmpty else { return }
        document.updatePerson(current)
    }
}
