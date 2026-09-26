import RowHouseCore
import SwiftUI

/// Timeline (Gantt) view: one bar per record from its start date to its end date.
struct RoadmapView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    private var document: BaseDocument { session.document }
    private let calendar = Calendar.current
    private let rowHeight: CGFloat = 36
    private let titleWidth: CGFloat = 230

    var body: some View {
        let startField = document.field(view.config.dateFieldID)
        Group {
            if let startField {
                content(startField: startField, endField: document.field(view.config.endDateFieldID))
            } else {
                ContentUnavailableView("Choose a start date field", systemImage: "chart.bar.xaxis", description: Text("Pick start and end date fields in the bar above."))
            }
        }
        .onAppear {
            commandTarget.addRecord = {
                let id = document.createRecord(in: view.tableID)
                state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
            }
            commandTarget.expandSelection = {}
            commandTarget.deleteSelection = {}
        }
    }

    private var pointsPerDay: CGFloat {
        switch view.config.timelineScale ?? .month {
        case .week: 56
        case .month: 18
        case .quarter: 7
        }
    }

    private struct Item: Identifiable {
        let id: String
        let title: String
        let start: Date?
        let end: Date?
        let color: ChoiceColor?
    }

    private func content(startField: FieldModel, endField: FieldModel?) -> some View {
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "")
        let items: [Item] = result.recordIDs.compactMap { id in
            guard let r = document.record(id) else { return nil }
            let s = document.value(r, startField).dateValue.map { calendar.startOfDay(for: $0) }
            var e = endField.flatMap { document.value(r, $0).dateValue }.map { calendar.startOfDay(for: $0) }
            if let s0 = s, let e0 = e, e0 < s0 { e = s0 }
            return Item(id: id, title: document.primaryTitle(r), start: s, end: e ?? s, color: document.recordColor(r, view: view))
        }
        let today = calendar.startOfDay(for: Date())
        let dates = items.flatMap { [$0.start, $0.end].compactMap { $0 } } + [today]
        let rangeStart = calendar.date(byAdding: .day, value: -10, to: dates.min()!)!
        let rangeEnd = calendar.date(byAdding: .day, value: 21, to: dates.max()!)!
        let dayCount = max(30, calendar.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 30)
        let width = CGFloat(dayCount) * pointsPerDay

        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(items.count) records")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 44)
                        .padding(.horizontal, 12)
                    ForEach(items) { item in
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(width: titleWidth, height: rowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: item.id, siblings: result.recordIDs) }
                        Divider()
                    }
                }
                .frame(width: titleWidth)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                axis(rangeStart: rangeStart, days: dayCount)
                                    .frame(width: width, height: 44)
                                ForEach(items) { item in
                                    ZStack(alignment: .leading) {
                                        Color.clear.frame(width: width, height: rowHeight)
                                        if let s = item.start, let e = item.end {
                                            let x = CGFloat(calendar.dateComponents([.day], from: rangeStart, to: s).day ?? 0) * pointsPerDay
                                            let w = max(pointsPerDay, CGFloat((calendar.dateComponents([.day], from: s, to: e).day ?? 0) + 1) * pointsPerDay)
                                            bar(item, width: w)
                                                .offset(x: x)
                                                .onTapGesture { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: item.id, siblings: result.recordIDs) }
                                        }
                                    }
                                    Divider()
                                }
                            }
                            let todayX = CGFloat(calendar.dateComponents([.day], from: rangeStart, to: today).day ?? 0) * pointsPerDay + pointsPerDay / 2
                            HStack(spacing: 0) {
                                Color.clear.frame(width: todayX, height: 1)
                                Rectangle()
                                    .fill(Color.red.opacity(0.8))
                                    .frame(width: 2, height: CGFloat(items.count) * (rowHeight + 1) + 44)
                                    .id("today")
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async { proxy.scrollTo("today", anchor: UnitPoint(x: 0.3, y: 0)) }
                    }
                }
            }
        }
    }

    private func bar(_ item: Item, width: CGFloat) -> some View {
        let color = item.color ?? .blue
        return Text(item.title)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color.chipText)
            .padding(.horizontal, 8)
            .frame(width: width, height: rowHeight - 12, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.chipBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.swiftUI.opacity(0.55), lineWidth: 1))
            .help(item.title)
    }

    private func axis(rangeStart: Date, days: Int) -> some View {
        Canvas { ctx, size in
            let monthFont = Font.system(size: 11, weight: .semibold)
            let dayFont = Font.system(size: 9)
            for i in 0..<days {
                guard let d = calendar.date(byAdding: .day, value: i, to: rangeStart) else { continue }
                let x = CGFloat(i) * pointsPerDay
                let dayOfMonth = calendar.component(.day, from: d)
                if dayOfMonth == 1 || i == 0 {
                    ctx.draw(Text(d.formatted(.dateTime.month(.abbreviated).year())).font(monthFont).foregroundStyle(.primary), at: CGPoint(x: x + 4, y: 12), anchor: .leading)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.secondary.opacity(0.4)))
                }
                let showDay = pointsPerDay >= 18 || calendar.component(.weekday, from: d) == calendar.firstWeekday
                if showDay {
                    ctx.draw(Text("\(dayOfMonth)").font(dayFont).foregroundStyle(.secondary), at: CGPoint(x: x + pointsPerDay / 2, y: 32), anchor: .center)
                }
                let weekday = calendar.component(.weekday, from: d)
                if weekday == 1 || weekday == 7 {
                    ctx.fill(Path(CGRect(x: x, y: 24, width: pointsPerDay, height: size.height - 24)), with: .color(.primary.opacity(0.03)))
                }
            }
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(.secondary.opacity(0.25)))
        }
    }
}
