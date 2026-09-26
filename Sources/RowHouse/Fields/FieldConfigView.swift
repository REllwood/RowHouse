import RowHouseCore
import RowHouseFormula
import SwiftUI

/// Create or edit a field: name, type and type-specific options.
struct FieldConfigView: View {
    let document: BaseDocument
    let tableID: String
    let fieldID: String?
    var insertAfter: String?
    let close: () -> Void

    @State private var name = ""
    @State private var type: FieldType = .singleLineText
    @State private var options = FieldOptions()
    @State private var description = ""
    @State private var formulaText = ""
    @State private var rollupText = "SUM(values)"
    @State private var buttonURLText = ""
    @State private var loaded = false
    @State private var showDescription = false

    private var existing: FieldModel? { document.field(fieldID) }
    private var isPrimary: Bool { fieldID != nil && document.primaryField(of: tableID)?.id == fieldID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Field name", text: $name, prompt: Text(type.displayName))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))
            TypePicker(type: $type, allowed: isPrimary ? FieldType.allCases.filter(\.canBePrimary) : FieldType.allCases, disabled: existing?.isInverseLink == true)
            if showDescription || !description.isEmpty {
                TextField("Description", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
            Divider()
            optionsEditor
            if let existing, existing.type != type, document.recordCount(in: tableID) > 0, !type.isComputed {
                Label("Existing values will be converted to \(type.displayName.lowercased()).", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if !showDescription && description.isEmpty {
                    Button {
                        showDescription = true
                    } label: {
                        Label("Add description", systemImage: "text.alignleft")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(fieldID == nil ? "Create field" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationError != nil)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let f = existing {
            name = f.name
            type = f.type
            options = f.options
            description = f.description
            formulaText = document.formulaWithFieldNames(f.options.formula ?? "", tableID: tableID)
            rollupText = f.options.rollupFormula ?? "SUM(values)"
            buttonURLText = document.formulaWithFieldNames(f.options.buttonURLFormula ?? "", tableID: tableID)
        }
    }

    private var validationError: String? {
        switch type {
        case .formula:
            if formulaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a formula" }
            return document.compute.validateFormula(formulaText, tableID: tableID, excludingFieldID: fieldID)
        case .link:
            return options.linkedTableID == nil ? "Choose a table to link to" : nil
        case .lookup, .rollup:
            if options.linkFieldID == nil { return "Choose a link field" }
            if options.targetFieldID == nil { return "Choose a field to look up" }
            if type == .rollup, let linkTable = document.field(options.linkFieldID)?.options.linkedTableID {
                _ = linkTable
                do { _ = try FormulaParser.parse(rollupText, variables: ["values"]) } catch { return error.message }
            }
            return nil
        case .count:
            return options.linkFieldID == nil ? "Choose a link field" : nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private var optionsEditor: some View {
        switch type {
        case .singleSelect, .multipleSelects:
            ChoicesEditor(choices: Binding(get: { options.choices ?? [] }, set: { options.choices = $0 }))
        case .number:
            precisionPicker
        case .currency:
            HStack {
                TextField("Symbol", text: Binding(get: { options.currencySymbol ?? "$" }, set: { options.currencySymbol = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                precisionPicker
            }
        case .percent:
            precisionPicker
        case .duration:
            Picker("Format", selection: Binding(get: { options.durationFormat ?? .hoursMinutes }, set: { options.durationFormat = $0 })) {
                ForEach(DurationFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        case .rating:
            Stepper("Maximum: \(options.ratingMax ?? 5) stars", value: Binding(get: { options.ratingMax ?? 5 }, set: { options.ratingMax = $0 }), in: 1...10)
        case .date:
            dateOptions(includeTimeDefault: false)
        case .createdTime, .lastModifiedTime:
            dateOptions(includeTimeDefault: true)
            if type == .lastModifiedTime {
                FieldMultiPicker(title: "Only when these fields change", document: document, tableID: tableID, selection: Binding(get: { Set(options.watchedFieldIDs ?? []) }, set: { options.watchedFieldIDs = $0.isEmpty ? nil : Array($0) }), exclude: fieldID)
            }
        case .link:
            linkOptions
        case .lookup, .rollup, .count:
            relationalOptions
        case .formula:
            FormulaEditor(document: document, tableID: tableID, text: $formulaText, excludingFieldID: fieldID)
            resultFormatPicker
        case .button:
            TextField("Label", text: Binding(get: { options.buttonLabel ?? "Open" }, set: { options.buttonLabel = $0 }))
                .textFieldStyle(.roundedBorder)
            Picker("Action", selection: Binding(get: { options.buttonAction ?? .openURL }, set: { options.buttonAction = $0 })) {
                Text("Open URL").tag(ButtonAction.openURL)
                Text("Run automation").tag(ButtonAction.runAutomation)
            }
            if (options.buttonAction ?? .openURL) == .openURL {
                TextField("URL formula, e.g. \"https://maps.apple.com/?q=\" & {Address}", text: $buttonURLText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                let automations = document.automations.filter { $0.trigger.kind == .buttonClicked && $0.trigger.tableID == tableID }
                Picker("Automation", selection: Binding(get: { options.buttonAutomationID ?? "" }, set: { options.buttonAutomationID = $0.isEmpty ? nil : $0 })) {
                    Text("Choose…").tag("")
                    ForEach(automations) { Text($0.name).tag($0.id) }
                }
                if automations.isEmpty {
                    Text("Create an automation with the “When a button is clicked” trigger for this table first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .checkbox:
            Text("A checkbox you can tick on or off.").font(.callout).foregroundStyle(.secondary)
        case .autoNumber:
            Text("Automatically numbers records in the order they were created.").font(.callout).foregroundStyle(.secondary)
        case .attachment:
            Text("Add images, PDFs or any file. Files are stored inside the base in iCloud Drive.").font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var precisionPicker: some View {
        Picker("Decimal places", selection: Binding(get: { options.precision ?? (type == .currency ? 2 : 0) }, set: { options.precision = $0 })) {
            ForEach(0...8, id: \.self) { p in
                Text(p == 0 ? "1" : "1." + String(repeating: "0", count: p)).tag(p)
            }
        }
    }

    private func dateOptions(includeTimeDefault: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Date format", selection: Binding(get: { options.dateFormat ?? .friendly }, set: { options.dateFormat = $0 })) {
                Text("Friendly (Sep 26, 2026)").tag(DateDisplayFormat.friendly)
                Text("Local").tag(DateDisplayFormat.local)
                Text("US (9/26/2026)").tag(DateDisplayFormat.us)
                Text("European (26/9/2026)").tag(DateDisplayFormat.european)
                Text("ISO (2026-09-26)").tag(DateDisplayFormat.iso)
            }
            Toggle("Include time", isOn: Binding(get: { options.includeTime ?? includeTimeDefault }, set: { options.includeTime = $0 }))
            if options.includeTime ?? includeTimeDefault {
                Toggle("Use 24-hour clock", isOn: Binding(get: { options.use24HourClock ?? false }, set: { options.use24HourClock = $0 }))
            }
        }
    }

    private var resultFormatPicker: some View {
        HStack {
            Picker("Format", selection: Binding(get: { options.resultFormat ?? .automatic }, set: { options.resultFormat = $0 })) {
                Text("Automatic").tag(FormulaResultFormat.automatic)
                Text("Number").tag(FormulaResultFormat.number)
                Text("Currency").tag(FormulaResultFormat.currency)
                Text("Percent").tag(FormulaResultFormat.percent)
                Text("Duration").tag(FormulaResultFormat.duration)
                Text("Date").tag(FormulaResultFormat.date)
                Text("Date & time").tag(FormulaResultFormat.dateTime)
            }
            if [.number, .currency, .percent].contains(options.resultFormat ?? .automatic) {
                precisionPicker.labelsHidden().frame(width: 90)
            }
        }
    }

    @ViewBuilder
    private var linkOptions: some View {
        if existing?.isInverseLink == true {
            Text("Linked from \(document.table(options.linkedTableID)?.name ?? "another table"). Edit the field there to change the relationship.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Picker("Link to", selection: Binding(get: { options.linkedTableID ?? "" }, set: { options.linkedTableID = $0.isEmpty ? nil : $0 })) {
                Text("Choose a table…").tag("")
                ForEach(document.tables) { t in Text(t.id == tableID ? "\(t.name) (this table)" : t.name).tag(t.id) }
            }
            Toggle("Allow linking to multiple records", isOn: Binding(get: { options.singleRecordLink != true }, set: { options.singleRecordLink = $0 ? nil : true }))
            if let target = options.linkedTableID, target != tableID {
                Text("A matching field is added to \(document.table(target)?.name ?? "the other table") so you can see links from both sides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var relationalOptions: some View {
        let linkFields = document.fields(in: tableID).filter { $0.type == .link }
        if linkFields.isEmpty {
            Label("Add a “Link to another record” field first.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Picker("Linked field", selection: Binding(get: { options.linkFieldID ?? "" }, set: {
                options.linkFieldID = $0.isEmpty ? nil : $0
                options.targetFieldID = nil
            })) {
                Text("Choose…").tag("")
                ForEach(linkFields) { f in Text("\(f.name) → \(document.table(f.options.linkedTableID)?.name ?? "")").tag(f.id) }
            }
            if type != .count, let link = document.field(options.linkFieldID), let target = link.options.linkedTableID {
                Picker(type == .lookup ? "Look up" : "Roll up", selection: Binding(get: { options.targetFieldID ?? "" }, set: { options.targetFieldID = $0.isEmpty ? nil : $0 })) {
                    Text("Choose…").tag("")
                    ForEach(document.fields(in: target)) { f in Label(f.name, systemImage: f.type.symbolName).tag(f.id) }
                }
            }
            if type == .rollup {
                Picker("Aggregation", selection: Binding(get: { rollupPreset }, set: { if !$0.isEmpty { rollupText = $0 } })) {
                    ForEach(Self.rollupPresets, id: \.1) { name, formula in Text(name).tag(formula) }
                    Text("Custom formula").tag("")
                }
                TextField("Formula using values", text: $rollupText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                resultFormatPicker
            }
        }
    }

    static let rollupPresets: [(String, String)] = [
        ("Sum", "SUM(values)"), ("Average", "AVERAGE(values)"), ("Minimum", "MIN(values)"), ("Maximum", "MAX(values)"),
        ("Count numbers", "COUNT(values)"), ("Count non-empty", "COUNTA(values)"), ("Count all", "COUNTALL(values)"),
        ("List all", "ARRAYJOIN(values)"), ("List unique", "ARRAYJOIN(ARRAYUNIQUE(values))"), ("Concatenate", "CONCATENATE(values)"),
        ("All true", "AND(values)"), ("Any true", "OR(values)"),
    ]

    private var rollupPreset: String {
        Self.rollupPresets.first { $0.1 == rollupText }?.1 ?? ""
    }

    private func save() {
        var opts = options
        switch type {
        case .formula: opts.formula = formulaText
        case .rollup: opts.rollupFormula = rollupText
        case .button: opts.buttonURLFormula = buttonURLText.isEmpty ? nil : buttonURLText
        default: break
        }
        if let fieldID {
            document.updateField(fieldID, name: name, type: type, options: opts, description: description)
        } else {
            let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? type.displayName : name
            document.createField(in: tableID, name: finalName, type: type, options: opts, description: description, after: insertAfter)
        }
        close()
    }
}

private struct TypePicker: View {
    @Binding var type: FieldType
    let allowed: [FieldType]
    var disabled = false

    var body: some View {
        Menu {
            ForEach(FieldType.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(allowed.filter { $0.category == category }) { t in
                        Button {
                            type = t
                        } label: {
                            Label(t.displayName, systemImage: t.symbolName)
                        }
                    }
                }
            }
        } label: {
            Label(type.displayName, systemImage: type.symbolName)
        }
        .disabled(disabled)
    }
}

struct ChoicesEditor: View {
    @Binding var choices: [SelectChoice]
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Options").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($choices) { $choice in
                        HStack(spacing: 6) {
                            Menu {
                                ForEach(ChoiceColor.allCases, id: \.self) { color in
                                    Button {
                                        choice.color = color
                                    } label: {
                                        Label(color.displayName, systemImage: choice.color == color ? "checkmark.circle.fill" : "circle.fill")
                                    }
                                }
                            } label: {
                                Circle().fill(choice.color.swiftUI).frame(width: 14, height: 14)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            TextField("Option", text: $choice.name)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                choices.removeAll { $0.id == choice.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            VStack(spacing: 0) {
                                Button { move(choice.id, by: -1) } label: { Image(systemName: "chevron.up").font(.system(size: 8)) }
                                Button { move(choice.id, by: 1) } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                TextField("Add an option", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        choices.append(SelectChoice(name: name, color: .cycling(choices.count)))
        newName = ""
    }

    private func move(_ id: String, by delta: Int) {
        guard let i = choices.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0 && j < choices.count else { return }
        choices.swapAt(i, j)
    }
}

struct FieldMultiPicker: View {
    let title: String
    let document: BaseDocument
    let tableID: String
    @Binding var selection: Set<String>
    var exclude: String?

    var body: some View {
        Menu {
            ForEach(document.fields(in: tableID).filter { $0.id != exclude && !$0.type.isComputed }) { f in
                Button {
                    if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
                } label: {
                    Label(f.name, systemImage: selection.contains(f.id) ? "checkmark" : f.type.symbolName)
                }
            }
        } label: {
            let names = document.fields(in: tableID).filter { selection.contains($0.id) }.map(\.name)
            Text(names.isEmpty ? "\(title): any field" : "\(title): \(names.joined(separator: ", "))")
                .lineLimit(1)
        }
    }
}
