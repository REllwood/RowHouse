import RowHouseCore
import SwiftUI

struct CalendarView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!

    private var document: BaseDocument { session.document }
    private let calendar = Calendar.current

    var body: some View {
        let dateField = document.field(view.config.dateFieldID)
        VStack(spacing: 0) {
            header
            Divider()
            if let dateField {
                grid(dateField)
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

    private var header: some View {
        HStack(spacing: 12) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title2.weight(.semibold))
            Spacer()
            ControlGroup {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Button("Today") { month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))! }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    private var visibleDays: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -leading, to: month)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private func grid(_ dateField: FieldModel) -> some View {
        let days = visibleDays
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "")
        var byDay: [Date: [RecordModel]] = [:]
        let first = days.first!, last = calendar.date(byAdding: .day, value: 1, to: days.last!)!
        for id in result.recordIDs {
            guard let r = document.record(id), let d = document.value(r, dateField).dateValue, d >= first, d < last else { continue }
            byDay[calendar.startOfDay(for: d), default: []].append(r)
        }
        let symbols = calendar.shortWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ordered, id: \.self) { s in
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
                                    inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
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
                eventChip(record, document: document)
            }
            if records.count > capacity {
                Button("+\(records.count - capacity + 1) more") { showAll = true }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showAll) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.formatted(date: .complete, time: .omitted)).font(.headline).padding(.bottom, 4)
                            ForEach(records) { eventChip($0, document: document) }
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
            guard dateField.type == .date else { return false }
            var updates: [String: [String: JSONValue]] = [:]
            for id in ids {
                guard let r = document.record(id) else { continue }
                var target = day
                if dateField.includesTime, let old = document.value(r, dateField).dateValue {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: old)
                    target = Calendar.current.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: day) ?? day
                }
                updates[id] = [dateField.id: .string(DateCoding.encode(target, includeTime: dateField.includesTime))]
            }
            document.updateRecords(updates, actionName: "Reschedule")
            return !updates.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private func eventChip(_ record: RecordModel, document: BaseDocument) -> some View {
        let color = document.recordColor(record, view: view)
        return HStack(spacing: 4) {
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
