import RowHouseCore
import SwiftUI

struct CalendarView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget
    @State private var anchor = Calendar.current.startOfDay(for: Date())

    private var document: BaseDocument { session.document }
    private let calendar = Calendar.current
    private var mode: CalendarMode { view.config.calendarMode ?? .month }

    var body: some View {
        let dateField = document.field(view.config.dateFieldID)
        VStack(spacing: 0) {
            header
            Divider()
            if let dateField {
                switch mode {
                case .month: monthGrid(dateField)
                case .week: weekGrid(dateField)
                }
            } else {
                ContentUnavailableView("Choose a date field", systemImage: "calendar", description: Text("Use the Date field menu above to pick which date to show records on."))
            }
        }
        .onAppear {
            commandTarget.addRecord = { addRecord(on: calendar.startOfDay(for: Date())) }
            commandTarget.expandSelection = {}
            commandTarget.deleteSelection = {}
        }
    }

    private var title: String {
        switch mode {
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        case .week:
            let days = weekDays
            guard let first = days.first, let last = days.last else { return "" }
            let formatter = DateIntervalFormatter()
            formatter.dateTemplate = "dMMMy"
            return formatter.string(from: first, to: last)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
                .contentTransition(.numericText())
            Spacer()
            Picker("", selection: Binding(get: { mode }, set: { newMode in
                document.updateViewConfig(view.id, actionName: "Change Calendar Layout") { $0.calendarMode = newMode == .month ? nil : newMode }
            })) {
                ForEach(CalendarMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ControlGroup {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help(mode == .month ? "Previous month" : "Previous week")
                Button("Today") { anchor = calendar.startOfDay(for: Date()) }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help(mode == .month ? "Next month" : "Next week")
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func shift(_ step: Int) {
        let next = mode == .month
            ? calendar.date(byAdding: .month, value: step, to: anchor)
            : calendar.date(byAdding: .day, value: 7 * step, to: anchor)
        withAnimation(.snappy(duration: 0.2)) { anchor = next ?? anchor }
    }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)) ?? anchor
    }

    private func startOfWeek(_ date: Date) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -leading, to: calendar.startOfDay(for: date)) ?? date
    }

    private var monthDays: [Date] {
        let start = startOfWeek(monthStart)
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekDays: [Date] {
        let start = startOfWeek(anchor)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Records on each visible day, in time order for date-time fields.
    private func recordsByDay(_ days: [Date], dateField: FieldModel, recordIDs: [String]) -> [Date: [RecordModel]] {
        guard let first = days.first, let lastDay = days.last, let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return [:] }
        var byDay: [Date: [(Date, RecordModel)]] = [:]
        for id in recordIDs {
            guard let r = document.record(id), let d = document.value(r, dateField).dateValue, d >= first, d < end else { continue }
            byDay[calendar.startOfDay(for: d), default: []].append((d, r))
        }
        let timed = dateField.includesTime || dateField.type == .createdTime || dateField.type == .lastModifiedTime
        return byDay.mapValues { items in
            (timed ? items.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element) : items).map(\.1)
        }
    }

    private var weekdayHeaders: [String] {
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    private func monthGrid(_ dateField: FieldModel) -> some View {
        let days = monthDays
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "")
        let byDay = recordsByDay(days, dateField: dateField, recordIDs: result.recordIDs)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdayHeaders, id: \.self) { s in
                    Text(s.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            Divider()
            GeometryReader { geo in
                let rowHeight = geo.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { week in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = days[week * 7 + d]
                                DayCell(
                                    session: session,
                                    view: view,
                                    day: day,
                                    inMonth: calendar.isDate(day, equalTo: monthStart, toGranularity: .month),
                                    records: byDay[day] ?? [],
                                    dateField: dateField,
                                    height: rowHeight,
                                    state: state,
                                    siblings: result.recordIDs,
                                    addRecord: { addRecord(on: day) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func weekGrid(_ dateField: FieldModel) -> some View {
        let days = weekDays
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "")
        let byDay = recordsByDay(days, dateField: dateField, recordIDs: result.recordIDs)
        let detailFields = document.cardFields(for: view, excluding: [dateField.id, view.config.colorFieldID ?? ""], limit: 2)
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                WeekDayColumn(
                    session: session,
                    view: view,
                    day: day,
                    records: byDay[day] ?? [],
                    dateField: dateField,
                    detailFields: detailFields,
                    state: state,
                    siblings: result.recordIDs,
                    addRecord: { addRecord(on: day) }
                )
            }
        }
    }

    private func addRecord(on day: Date) {
        guard let field = document.field(view.config.dateFieldID) else {
            let id = document.createRecord(in: view.tableID)
            state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
            return
        }
        var values: [String: JSONValue] = [:]
        if field.type == .date {
            var date = day
            if field.includesTime { date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day }
            values[field.id] = .string(DateCoding.encode(date, includeTime: field.includesTime))
        }
        let id = document.createRecord(in: view.tableID, values: values)
        state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
    }
}

/// Moves dropped records to `day`, keeping each date-time's time of day.
@MainActor
private func reschedule(_ ids: [String], to day: Date, dateField: FieldModel, document: BaseDocument) -> Bool {
    guard dateField.type == .date else { return false }
    let calendar = Calendar.current
    var updates: [String: [String: JSONValue]] = [:]
    for id in ids {
        guard let r = document.record(id) else { continue }
        var target = day
        if dateField.includesTime, let old = document.value(r, dateField).dateValue {
            let c = calendar.dateComponents([.hour, .minute], from: old)
            target = calendar.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: day) ?? day
        }
        updates[id] = [dateField.id: .string(DateCoding.encode(target, includeTime: dateField.includesTime))]
    }
    document.updateRecords(updates, actionName: "Reschedule")
    return !updates.isEmpty
}

private struct DayCell: View {
    let session: BaseSession
    let view: ViewModel
    let day: Date
    let inMonth: Bool
    let records: [RecordModel]
    let dateField: FieldModel
    let height: CGFloat
    var state: WindowState
    let siblings: [String]
    let addRecord: () -> Void
    @State private var targeted = false
    @State private var showAll = false

    var body: some View {
        let document = session.document
        let isToday = Calendar.current.isDateInToday(day)
        let capacity = max(1, Int((height - 30) / 22))
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(isToday ? Color.red : .clear))
                Spacer()
            }
            ForEach(records.prefix(records.count > capacity ? capacity - 1 : capacity)) { record in
                EventChip(session: session, view: view, record: record, state: state, siblings: siblings)
            }
            if records.count > capacity {
                Button("+\(records.count - capacity + 1) more") { showAll = true }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showAll) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.formatted(date: .complete, time: .omitted)).font(.headline).padding(.bottom, 4)
                            ForEach(records) { EventChip(session: session, view: view, record: $0, state: state, siblings: siblings) }
                        }
                        .padding(12)
                        .frame(width: 260)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(targeted ? Color.accentColor.opacity(0.12) : (inMonth ? Color.clear : Color.primary.opacity(0.025)))
        .overlay(Rectangle().stroke(Color(nsColor: Theme.gridLine), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: addRecord)
        .dropDestination(for: String.self) { ids, _ in
            reschedule(ids, to: day, dateField: dateField, document: document)
        } isTargeted: { targeted = $0 }
    }
}

/// A one-line record chip for month cells.
private struct EventChip: View {
    let session: BaseSession
    let view: ViewModel
    let record: RecordModel
    var state: WindowState
    let siblings: [String]

    var body: some View {
        let document = session.document
        let color = document.recordColor(record, view: view)
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill((color ?? .blue).swiftUI).frame(width: 3)
            Text(document.primaryTitle(record))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(height: 19)
        .background(RoundedRectangle(cornerRadius: 4).fill(color?.chipBackground ?? Color.accentColor.opacity(0.14)))
        .foregroundStyle(color?.chipText ?? Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: record.id, siblings: siblings) }
        .draggable(record.id)
    }
}

/// One tall day in the week layout: every record for the day as a card, scrolling if needed.
private struct WeekDayColumn: View {
    let session: BaseSession
    let view: ViewModel
    let day: Date
    let records: [RecordModel]
    let dateField: FieldModel
    let detailFields: [FieldModel]
    var state: WindowState
    let siblings: [String]
    let addRecord: () -> Void
    @State private var targeted = false

    var body: some View {
        let document = session.document
        let isToday = Calendar.current.isDateInToday(day)
        let weekend = Calendar.current.isDateInWeekend(day)
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isToday ? Color.red : Color.secondary)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 18, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                    .frame(minWidth: 32, minHeight: 32)
                    .background(Circle().fill(isToday ? Color.red : .clear))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(records) { record in
                        WeekEventCard(session: session, view: view, record: record, dateField: dateField, detailFields: detailFields)
                            .onTapGesture { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: record.id, siblings: siblings) }
                            .draggable(record.id)
                            .contextMenu {
                                Button("Expand Record") { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: record.id, siblings: siblings) }
                                Button("Duplicate Record") { _ = document.duplicateRecords([record.id]) }
                                Divider()
                                Button("Delete Record", role: .destructive) { document.deleteRecords([record.id]) }
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.12) : (weekend ? Color.primary.opacity(0.025) : Color.clear))
        .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: addRecord)
        .dropDestination(for: String.self) { ids, _ in
            reschedule(ids, to: day, dateField: dateField, document: document)
        } isTargeted: { targeted = $0 }
    }
}

private struct WeekEventCard: View {
    let session: BaseSession
    let view: ViewModel
    let record: RecordModel
    let dateField: FieldModel
    let detailFields: [FieldModel]

    var body: some View {
        let document = session.document
        let color = document.recordColor(record, view: view)
        let date = document.value(record, dateField).dateValue
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill((color ?? .blue).swiftUI)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                if dateField.includesTime, let date {
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(document.primaryTitle(record))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(3)
                    .foregroundStyle(color?.chipText ?? Color.primary)
                ForEach(detailFields) { field in
                    if !document.value(record, field).isEmpty {
                        CompactValueView(session: session, record: record, field: field)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(color?.chipBackground ?? Color.accentColor.opacity(0.12)))
        .contentShape(Rectangle())
    }
}
