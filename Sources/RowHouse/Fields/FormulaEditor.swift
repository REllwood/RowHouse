import RowHouseCore
import RowHouseFormula
import SwiftUI

/// Formula text editor with live validation, a field list and a function reference.
struct FormulaEditor: View {
    let document: BaseDocument
    let tableID: String
    @Binding var text: String
    var excludingFieldID: String?
    @State private var tab = 0
    @State private var search = ""

    var body: some View {
        let error = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : document.compute.validateFormula(text, tableID: tableID, excludingFieldID: excludingFieldID)
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(error == nil ? Color.primary.opacity(0.12) : Color.red.opacity(0.6)))
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            } else if !text.isEmpty {
                Label("Valid formula", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }
            Picker("", selection: $tab) {
                Text("Fields").tag(0)
                Text("Functions").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if tab == 0 {
                        ForEach(document.fields(in: tableID).filter { $0.id != excludingFieldID && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { f in
                            Button {
                                insert("{\(f.name)}")
                            } label: {
                                HStack {
                                    Image(systemName: f.type.symbolName).frame(width: 16).foregroundStyle(.secondary)
                                    Text(f.name)
                                    Spacer()
                                    Text(f.type.displayName).font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(FormulaCatalog.functions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }, id: \.name) { fn in
                            Button {
                                insert(fn.name + "(")
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(fn.signature).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
                                        Spacer()
                                        Text(fn.category).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Text(fn.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 150)
        }
    }

    private func insert(_ snippet: String) {
        if !text.isEmpty && !text.hasSuffix(" ") && !text.hasSuffix("(") { text += " " }
        text += snippet
    }
}
