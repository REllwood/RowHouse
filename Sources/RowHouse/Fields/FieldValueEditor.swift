import AppKit
import QuickLookUI
import RowHouseCore
import SwiftUI
import UniformTypeIdentifiers

extension BaseDocument {
    /// The stored JSON a field editor works with; link fields (either side) are always id arrays.
    func editableValue(_ record: RecordModel, _ field: FieldModel) -> JSONValue {
        if field.type == .link {
            let ids = compute.linkedRecordIDs(record: record, field: field)
            return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        }
        return record[field.id]
    }

    func binding(recordID: String, field: FieldModel) -> Binding<JSONValue> {
        Binding(
            get: { [weak self] in
                guard let self, let r = self.record(recordID) else { return .null }
                return self.editableValue(r, field)
            },
            set: { [weak self] new in
                self?.updateRecord(recordID, values: [field.id: new], actionName: "Edit \(field.name)")
            }
        )
    }
}

enum EditorStyle {
    case popover, detail, form
}

/// Text used when editing a stored value as plain text.
func plainEditText(_ value: JSONValue, field: FieldModel) -> String {
    switch field.type {
    case .number, .currency:
        return value.numberValue.map { ValueParsing.editableNumber($0) } ?? ""
    case .percent:
        return value.numberValue.map { ValueParsing.editableNumber($0 * 100) } ?? ""
    case .duration:
        return value.numberValue.map { CellFormatter.duration($0, format: field.options.durationFormat ?? .hoursMinutes) } ?? ""
    default:
        return value.stringValue ?? ""
    }
}

struct FieldValueEditor: View {
    let session: BaseSession
    let field: FieldModel
    @Binding var value: JSONValue
    var recordID: String?
    var style: EditorStyle = .detail
    var initialText: String?

    private var document: BaseDocument { session.document }

    var body: some View {
        switch field.type {
        case .singleLineText, .email, .url, .phoneNumber, .number, .currency, .percent, .duration:
            HStack(spacing: 6) {
                if field.type == .currency { Text(field.options.currencySymbol ?? "$").foregroundStyle(.secondary) }
                CommitTextField(
                    text: plainEditText(value, field: field),
                    prompt: prompt,
                    initialText: initialText,
                    monospacedDigits: field.type.isNumeric,
                    commitOnChange: style == .form
                ) { text in
                    let parsed = document.parseValue(text, for: field, createMissingChoices: false)
                    if parsed != value { value = parsed }
                }
                if field.type == .percent { Text("%").foregroundStyle(.secondary) }
                if let url = openableURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: field.type == .email ? "envelope" : (field.type == .phoneNumber ? "phone" : "arrow.up.right.square"))
                    }
                    .buttonStyle(.borderless)
                    .help("Open")
                }
            }
        case .multilineText:
            CommitTextEditor(text: value.stringValue ?? "", initialText: initialText, minHeight: style == .popover ? 160 : 90, commitOnChange: style == .form) { text in
                let v: JSONValue = text.isEmpty ? .null : .string(text)
                if v != value { value = v }
            }
        case .checkbox:
            Toggle(isOn: Binding(get: { value.boolValue ?? false }, set: { value = .bool($0) })) {
                Text(value.boolValue == true ? "Checked" : "Unchecked").foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
        case .rating:
            RatingEditor(value: Binding(get: { Int(clampedRating(value.numberValue, max: field.options.ratingMax ?? 5)) }, set: { value = $0 == 0 ? .null : .number(Double($0)) }), max: min(10, field.options.ratingMax ?? 5))
        case .singleSelect, .multipleSelects:
            SelectEditor(document: document, fieldID: field.id, value: $value, style: style, initialText: initialText)
        case .date:
            DateValueEditor(field: field, value: $value, style: style)
        case .attachment:
            AttachmentEditor(session: session, value: $value, style: style)
        case .link:
            LinkEditor(document: document, field: field, value: $value, style: style, initialText: initialText)
        default:
            if let recordID, let record = document.record(recordID) {
                ComputedValueView(session: session, record: record, field: field)
            } else {
                Text("Calculated automatically").foregroundStyle(.tertiary)
            }
        }
    }

    private var prompt: String {
        switch field.type {
        case .email: "name@example.com"
        case .url: "https://"
        case .phoneNumber: "Phone number"
        case .duration: field.options.durationFormat == .hoursMinutesSeconds ? "h:mm:ss" : "h:mm"
        case .number, .currency, .percent: "0"
        default: ""
        }
    }

    private var openableURL: URL? {
        guard style != .form, let s = value.stringValue, !s.isEmpty else { return nil }
        switch field.type {
        case .url: return URL(string: s.hasPrefix("http") ? s : "https://\(s)")
        case .email: return URL(string: "mailto:\(s)")
        case .phoneNumber: return URL(string: "tel:\(s.filter { !$0.isWhitespace })")
        default: return nil
        }
    }
}

/// Text field that keeps its own text while typing and commits on Return, Tab or losing focus.
struct CommitTextField: View {
    let text: String
    var prompt: String = ""
    var initialText: String?
    var monospacedDigits = false
    /// Forms save as you type, because clicking Submit doesn't end editing on macOS.
    var commitOnChange = false
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: draft) { _, new in
                if commitOnChange && loaded { commit(new) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit(draft) }
            }
            .onChange(of: text) { _, new in
                if !focused { draft = new }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                draft = initialText ?? text
                if initialText != nil { focused = true }
            }
            .onDisappear {
                if draft != text { commit(draft) }
            }
    }
}

struct CommitTextEditor: View {
    let text: String
    var initialText: String?
    var minHeight: CGFloat = 90
    var commitOnChange = false
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .onChange(of: draft) { _, new in
                if commitOnChange && loaded { commit(new) }
            }
            .font(.body)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(focused ? 0.25 : 0.1)))
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit(draft) }
            }
            .onChange(of: text) { _, new in
                if !focused { draft = new }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                draft = initialText.map { text + $0 } ?? text
                if initialText != nil { focused = true }
            }
            .onDisappear {
                if draft != text { commit(draft) }
            }
    }
}

struct RatingEditor: View {
    @Binding var value: Int
    let max: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...Swift.max(1, max), id: \.self) { i in
                Button {
                    value = value == i ? 0 : i
                } label: {
                    Image(systemName: i <= value ? "star.fill" : "star")
                        .foregroundStyle(i <= value ? Color(nsColor: Theme.star) : Color.secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Select

struct SelectEditor: View {
    let document: BaseDocument
    let fieldID: String
    @Binding var value: JSONValue
    let style: EditorStyle
    var initialText: String?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let field = document.field(fieldID)
        let multi = field?.type == .multipleSelects
        let selectedIDs = multi ? value.stringArray : (value.stringValue.map { [$0] } ?? [])
        let choices = field?.choices ?? []
        let filtered = choices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 8) {
            if !selectedIDs.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selectedIDs, id: \.self) { id in
                        if let c = choices.first(where: { $0.id == id }) {
                            HStack(spacing: 3) {
                                ChoiceChip(name: c.name, color: c.color)
                                Button {
                                    remove(id, multi: multi)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if style != .detail || selectedIDs.isEmpty || multi {
                TextField("Find or create an option", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filtered.first { toggle(first.id, multi: multi) } else { createFromSearch(multi: multi) }
                    }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { choice in
                            Button {
                                toggle(choice.id, multi: multi)
                            } label: {
                                HStack {
                                    ChoiceChip(name: choice.name, color: choice.color)
                                    Spacer()
                                    if selectedIDs.contains(choice.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if !search.trimmingCharacters(in: .whitespaces).isEmpty && !choices.contains(where: { $0.name.caseInsensitiveCompare(search.trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
                            Button {
                                createFromSearch(multi: multi)
                            } label: {
                                Label("Create “\(search.trimmingCharacters(in: .whitespaces))”", systemImage: "plus")
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .frame(maxHeight: style == .popover ? 260 : 180)
            } else {
                Menu("Change") {
                    ForEach(choices) { c in Button(c.name) { toggle(c.id, multi: false) } }
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

    private func toggle(_ id: String, multi: Bool) {
        if multi {
            var ids = value.stringArray
            if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
            value = ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        } else {
            value = value.stringValue == id ? .null : .string(id)
        }
        search = ""
    }

    private func remove(_ id: String, multi: Bool) {
        if multi {
            let ids = value.stringArray.filter { $0 != id }
            value = ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        } else {
            value = .null
        }
    }

    private func createFromSearch(multi: Bool) {
        let name = search.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let choice = document.addChoice(named: name, to: fieldID) else { return }
        if multi {
            var ids = value.stringArray
            if !ids.contains(choice.id) { ids.append(choice.id) }
            value = .array(ids.map(JSONValue.string))
        } else {
            value = .string(choice.id)
        }
        search = ""
    }
}

// MARK: - Date

struct DateValueEditor: View {
    let field: FieldModel
    @Binding var value: JSONValue
    let style: EditorStyle

    var body: some View {
        let date = value.stringValue.flatMap { DateCoding.decode($0) }
        VStack(alignment: .leading, spacing: 8) {
            if style == .popover {
                DatePicker("", selection: binding(date), displayedComponents: field.includesTime ? [.date, .hourAndMinute] : [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            } else {
                HStack {
                    if date != nil {
                        DatePicker("", selection: binding(date), displayedComponents: field.includesTime ? [.date, .hourAndMinute] : [.date])
                            .datePickerStyle(.field)
                            .labelsHidden()
                    } else {
                        Button("Add date") { value = .string(DateCoding.encode(Date(), includeTime: field.includesTime)) }
                    }
                }
            }
            HStack {
                Button("Today") { value = .string(DateCoding.encode(Date(), includeTime: field.includesTime)) }
                if date != nil {
                    Button("Clear") { value = .null }
                }
            }
            .controlSize(.small)
        }
    }

    private func binding(_ date: Date?) -> Binding<Date> {
        Binding(get: { date ?? Date() }, set: { value = .string(DateCoding.encode($0, includeTime: field.includesTime)) })
    }
}

// MARK: - Attachments

struct AttachmentEditor: View {
    let session: BaseSession
    @Binding var value: JSONValue
    let style: EditorStyle
    @State private var dropTargeted = false
    @State private var error: String?

    var body: some View {
        let atts = (value.arrayValue ?? []).compactMap { $0.decode(AttachmentInfo.self) }
        VStack(alignment: .leading, spacing: 8) {
            if !atts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(atts) { att in
                        VStack(spacing: 3) {
                            AttachmentThumbnail(url: session.storage.url(for: att), attachment: att, size: 84)
                                .frame(width: 84, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        remove(att)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(session.storage.url(for: att)) }
                                .help("Double-click to open \(att.filename)")
                            Text(att.filename)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 84)
                        }
                    }
                }
            }
            HStack {
                Button {
                    pickFiles()
                } label: {
                    Label("Add files", systemImage: "paperclip")
                }
                Text("or drop files here").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [] : [4])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            }
            return true
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        var atts = (value.arrayValue ?? []).compactMap { $0.decode(AttachmentInfo.self) }
        for url in urls {
            do {
                atts.append(try session.storage.importAttachment(from: url))
            } catch {
                self.error = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        value = JSONValue(encoding: atts)
    }

    private func remove(_ att: AttachmentInfo) {
        let atts = (value.arrayValue ?? []).compactMap { $0.decode(AttachmentInfo.self) }.filter { $0.id != att.id }
        value = atts.isEmpty ? .null : JSONValue(encoding: atts)
    }
}

// MARK: - Links

struct LinkEditor: View {
    let document: BaseDocument
    let field: FieldModel
    @Binding var value: JSONValue
    let style: EditorStyle
    var initialText: String?
    @State private var search = ""
    @State private var picking = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let ids = value.stringArray
        let tableID = field.options.linkedTableID ?? ""
        VStack(alignment: .leading, spacing: 8) {
            if !ids.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        HStack(spacing: 3) {
                            LinkChip(title: document.primaryTitle(recordID: id))
                            Button {
                                let rest = ids.filter { $0 != id }
                                value = rest.isEmpty ? .null : .array(rest.map(JSONValue.string))
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if style == .popover || picking || ids.isEmpty {
                TextField("Find a record in \(document.table(tableID)?.name ?? "the linked table")", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                let candidates = document.records(in: tableID)
                    .filter { !ids.contains($0.id) }
                    .filter { search.isEmpty || document.primaryTitle($0).localizedCaseInsensitiveContains(search) }
                    .prefix(50)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(candidates)) { r in
                            Button {
                                add(r.id)
                            } label: {
                                HStack {
                                    Text(document.primaryTitle(r)).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "plus").foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button {
                                if let primary = document.primaryField(of: tableID) {
                                    add(document.createRecord(in: tableID, values: [primary.id: .string(search.trimmingCharacters(in: .whitespaces))]))
                                }
                            } label: {
                                Label("Create “\(search.trimmingCharacters(in: .whitespaces))” in \(document.table(tableID)?.name ?? "")", systemImage: "plus")
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .frame(maxHeight: style == .popover ? 240 : 160)
            } else if field.options.singleRecordLink != true || ids.isEmpty {
                Button {
                    picking = true
                } label: {
                    Label("Link a record", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            if let initialText { search = initialText }
            if style == .popover { searchFocused = true }
        }
    }

    private func add(_ id: String) {
        var ids = value.stringArray
        if field.options.singleRecordLink == true { ids = [] }
        if !ids.contains(id) { ids.append(id) }
        value = .array(ids.map(JSONValue.string))
        search = ""
        picking = false
    }
}

// MARK: - Computed values

struct ComputedValueView: View {
    let session: BaseSession
    let record: RecordModel
    let field: FieldModel

    var body: some View {
        let document = session.document
        let v = document.value(record, field)
        switch v {
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
        case .list(let items) where field.type == .lookup:
            let target = document.field(field.options.targetFieldID)
            FlowLayout(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .choice(let c): ChoiceChip(name: c.name, color: c.color)
                    case .attachments(let atts):
                        ForEach(atts) { att in
                            AttachmentThumbnail(url: session.storage.url(for: att), attachment: att, size: 48)
                                .frame(width: 48, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    default:
                        Text(CellFormatter.string(item, field: target))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Theme.lookupChipBackground)))
                    }
                }
            }
        default:
            let text = document.displayString(record, field)
            Text(text.isEmpty ? "—" : text)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .monospacedDigit()
        }
    }
}

// MARK: - Popover used by the grid

struct CellEditorPopover: View {
    let session: BaseSession
    let recordID: String
    let fieldID: String
    var initialText: String?
    let close: () -> Void

    var body: some View {
        let document = session.document
        if let field = document.field(fieldID), document.record(recordID) != nil {
            VStack(alignment: .leading, spacing: 10) {
                FieldLabel(field: field)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FieldValueEditor(session: session, field: field, value: document.binding(recordID: recordID, field: field), recordID: recordID, style: .popover, initialText: initialText)
            }
            .padding(12)
            .frame(width: field.type == .date ? 280 : 320)
            .fixedSize(horizontal: false, vertical: true)
            .onExitCommand(perform: close)
        }
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
