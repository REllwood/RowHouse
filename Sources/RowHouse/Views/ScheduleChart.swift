import AppKit
import RowHouseCore
import SwiftUI

/// The bar chart behind the Timeline and Gantt views: records as bars from their start to end
/// dates, swimlanes for groups, drag to move or stretch bars, and (for Gantt) dependency arrows.
struct ScheduleChart: View {
    enum Style { case timeline, gantt }

    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget
    let style: Style
    @State private var drag: BarDrag?
    @State private var hoveredRecord: String?

    private var document: BaseDocument { session.document }
    private let calendar = Calendar.current

    static let recordRowHeight: CGFloat = 36
    static let axisHeight: CGFloat = 50
    static let titleWidth: CGFloat = 260

    struct BarDrag: Equatable {
        var recordID: String
        var moveDays = 0
        var resizeDays = 0
    }

    enum Row: Identifiable {
        case group(GroupHeader)
        case record(String)

        var id: String {
            switch self {
            case .group(let g): "g:" + g.id
            case .record(let id): id
            }
        }
    }

    /// Everything positioned on the chart, computed once per render.
    struct Layout {
        var rows: [Row] = []
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var contentHeight: CGFloat = 0
        var rangeStart = Date()
        var dayCount = 0
        var pointsPerDay: CGFloat = 18
        var spans: [String: TimelineSpan] = [:]
        var rowOfRecord: [String: Int] = [:]
        var dependencies: [GanttDependency] = []
        var recordIDs: [String] = []

        var width: CGFloat { CGFloat(dayCount) * pointsPerDay }

        func x(_ date: Date, calendar: Calendar) -> CGFloat {
            CGFloat(calendar.dateComponents([.day], from: rangeStart, to: date).day ?? 0) * pointsPerDay
        }

        func barFrame(_ id: String, calendar: Calendar) -> CGRect? {
            guard let span = spans[id], let row = rowOfRecord[id] else { return nil }
            let x = self.x(span.start, calendar: calendar)
            let w = max(6, CGFloat(span.dayCount(calendar: calendar)) * pointsPerDay)
            return CGRect(x: x, y: tops[row] + 6, width: w, height: heights[row] - 12)
        }
    }

    var body: some View {
        let startField = document.field(view.config.dateFieldID)
        Group {
            if let startField {
                chart(startField: startField, endField: document.field(view.config.endDateFieldID))
            } else {
                ContentUnavailableView("Choose a start date field", systemImage: view.type.symbolName, description: Text("Pick start and end date fields in the bar above."))
            }
        }
        .onAppear {
            commandTarget.addRecord = { addRecord(on: calendar.startOfDay(for: Date())) }
            commandTarget.expandSelection = {}
            commandTarget.deleteSelection = {}
        }
    }

    private var pointsPerDay: CGFloat {
        switch view.config.timelineScale ?? .month {
        case .week: 56
        case .month: 18
        case .quarter: 7
        case .year: 2.4
        }
    }

    private func canMove(_ startField: FieldModel) -> Bool { startField.type == .date }

    private func canResize(_ startField: FieldModel, _ endField: FieldModel?) -> Bool {
        startField.type == .date && endField?.type == .date && endField?.id != startField.id
    }

    // MARK: Layout

    private func makeLayout(startField: FieldModel, endField: FieldModel?, visibleWidth: CGFloat, visibleHeight: CGFloat) -> Layout {
        var layout = Layout()
        layout.pointsPerDay = pointsPerDay
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "", collapsedGroups: state.collapsedGroups[view.id] ?? [])
        layout.recordIDs = result.recordIDs
        var y: CGFloat = 0
        for row in result.rows {
            let height: CGFloat
            switch row {
            case .group(let g):
                layout.rows.append(.group(g))
                height = g.depth == 0 ? 34 : 30
            case .record(let id):
                layout.rowOfRecord[id] = layout.rows.count
                layout.rows.append(.record(id))
                height = Self.recordRowHeight
            }
            layout.tops.append(y)
            layout.heights.append(height)
            y += height
        }
        layout.contentHeight = max(y, visibleHeight - Self.axisHeight)

        let displayed = layout.rows.compactMap { if case .record(let id) = $0 { return id } else { return nil } }
        let spans = document.timelineSpans(recordIDs: displayed, startField: startField, endField: endField, calendar: calendar)

        // The visible range comes from the stored dates so it stays put while a bar is dragged.
        let today = calendar.startOfDay(for: Date())
        let lead: Int, trail: Int
        switch view.config.timelineScale ?? .month {
        case .week: (lead, trail) = (7, 14)
        case .month: (lead, trail) = (14, 30)
        case .quarter: (lead, trail) = (30, 60)
        case .year: (lead, trail) = (60, 120)
        }
        let earliest = spans.values.map(\.start).min().map { min($0, today) } ?? today
        let latest = spans.values.map(\.end).max().map { max($0, today) } ?? today
        var start = calendar.date(byAdding: .day, value: -lead, to: earliest) ?? earliest
        if let month = calendar.dateInterval(of: .month, for: start)?.start { start = month }
        let end = calendar.date(byAdding: .day, value: trail, to: latest) ?? latest
        let needed = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        layout.rangeStart = start
        layout.dayCount = max(needed, Int((visibleWidth / pointsPerDay).rounded(.up)) + 1)

        var shown = spans
        if let drag, var span = shown[drag.recordID] {
            span.start = calendar.date(byAdding: .day, value: drag.moveDays, to: span.start) ?? span.start
            let end = calendar.date(byAdding: .day, value: drag.moveDays + drag.resizeDays, to: span.end) ?? span.end
            span.end = max(end, span.start)
            shown[drag.recordID] = span
        }
        layout.spans = shown
        if style == .gantt, let dependencyField = document.field(view.config.dependencyFieldID), dependencyField.type == .link {
            layout.dependencies = document.ganttDependencies(recordIDs: displayed, dependencyField: dependencyField, spans: shown)
        }
        return layout
    }

    // MARK: Chart

    private static let viewportSpace = "scheduleViewport"
    private static let contentSpace = "scheduleContent"

    private func chart(startField: FieldModel, endField: FieldModel?) -> some View {
        GeometryReader { geo in
            let layout = makeLayout(startField: startField, endField: endField, visibleWidth: geo.size.width - Self.titleWidth - 1, visibleHeight: geo.size.height)
            let viewportWidth = max(0, geo.size.width - Self.titleWidth - 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        titleColumn(layout, startField: startField, endField: endField, proxy: proxy)
                            .frame(width: Self.titleWidth)
                            .background(Color(nsColor: .windowBackgroundColor))
                        Divider()
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                Color.clear
                                    .frame(width: layout.width, height: Self.axisHeight + layout.contentHeight)
                                GeometryReader { content in
                                    // Only the part of the chart on screen is drawn, so long ranges and
                                    // many records stay cheap.
                                    let frame = content.frame(in: .named(Self.viewportSpace))
                                    let visible = CGRect(x: Self.titleWidth + 1 - frame.minX, y: -frame.minY, width: viewportWidth, height: geo.size.height)
                                        .intersection(CGRect(origin: .zero, size: content.size))
                                    if !visible.isNull {
                                        viewportLayer(layout, visible: visible, startField: startField, endField: endField)
                                    }
                                }
                                HStack(spacing: 0) {
                                    Color.clear.frame(width: max(0, layout.x(calendar.startOfDay(for: Date()), calendar: calendar) + layout.pointsPerDay / 2), height: 1)
                                    Color.clear.frame(width: 1, height: 1).id("today")
                                }
                                .allowsHitTesting(false)
                            }
                            .coordinateSpace(name: Self.contentSpace)
                        }
                    }
                }
                .coordinateSpace(name: Self.viewportSpace)
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo("today", anchor: UnitPoint(x: 0.3, y: 0)) }
                }
            }
        }
    }

    /// The drawn background, axis and arrows for the visible rect, plus the bars that intersect it.
    private func viewportLayer(_ layout: Layout, visible: CGRect, startField: FieldModel, endField: FieldModel?) -> some View {
        let movable = canMove(startField)
        let resizable = canResize(startField, endField)
        let violated = Set(layout.dependencies.filter(\.isViolated).map(\.dependentID))
        let bodyTop = max(visible.minY, Self.axisHeight)
        let bodyRect = CGRect(x: visible.minX, y: bodyTop - Self.axisHeight, width: visible.width, height: max(0, visible.maxY - bodyTop))
        let barArea = bodyRect.insetBy(dx: -240, dy: -Self.recordRowHeight)
        let bars = layout.rows.compactMap { row -> (String, CGRect)? in
            guard case .record(let id) = row, let frame = layout.barFrame(id, calendar: calendar) else { return nil }
            return frame.intersects(barArea) || drag?.recordID == id ? (id, frame) : nil
        }
        return ZStack(alignment: .topLeading) {
            ScheduleCanvas(
                part: .body,
                layout: layout,
                scale: view.config.timelineScale ?? .month,
                visible: visible,
                hoveredRow: hoveredRecord.flatMap { layout.rowOfRecord[$0] }
            )
            .frame(width: visible.width, height: visible.height)
            .offset(x: visible.minX, y: visible.minY)
            .allowsHitTesting(false)
            if bodyRect.height > 0 {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: bodyRect.width, height: bodyRect.height)
                    .offset(x: bodyRect.minX, y: bodyTop)
                    .onTapGesture(count: 2, coordinateSpace: .named(Self.contentSpace)) { location in
                        schedule(at: CGPoint(x: location.x, y: location.y - Self.axisHeight), layout: layout, startField: startField)
                    }
            }
            ForEach(bars, id: \.0) { id, frame in
                bar(id, frame: frame.offsetBy(dx: 0, dy: Self.axisHeight), visibleMinX: visible.minX, layout: layout, movable: movable, resizable: resizable, violated: violated.contains(id), startField: startField, endField: endField)
            }
            // The date axis stays pinned to the top while records scroll beneath it.
            ScheduleCanvas(part: .axis, layout: layout, scale: view.config.timelineScale ?? .month, visible: visible, hoveredRow: nil)
                .frame(width: visible.width, height: Self.axisHeight)
                .contentShape(Rectangle())
                .offset(x: visible.minX, y: visible.minY)
        }
    }

    private func titleColumn(_ layout: Layout, startField: FieldModel, endField: FieldModel?, proxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
                    switch row {
                    case .group(let header):
                        groupTitle(header)
                            .frame(height: layout.heights[index])
                    case .record(let id):
                        recordTitle(id, layout: layout, startField: startField)
                            .frame(height: layout.heights[index])
                    }
                }
            } header: {
                HStack {
                    Text("\(layout.recordIDs.count) record\(layout.recordIDs.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Today") {
                        withAnimation(.snappy) { proxy.scrollTo("today", anchor: UnitPoint(x: 0.3, y: 0)) }
                    }
                    .controlSize(.small)
                    .help("Scroll to today")
                }
                .padding(.horizontal, 12)
                .frame(height: Self.axisHeight)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(height: 1) }
            }
        }
    }

    private func groupTitle(_ header: GroupHeader) -> some View {
        let collapsed = (state.collapsedGroups[view.id] ?? []).contains(header.id)
        let field = document.field(header.fieldID)
        return HStack(spacing: 7) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            if case .choice(let c) = header.value {
                ChoiceChip(name: c.name, color: c.color, compact: true)
            } else {
                Text(header.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text("\(header.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            Text(field?.name.uppercased() ?? "")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.leading, 10 + CGFloat(header.depth) * 14)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: Theme.groupBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { toggleGroup(header.id) }
        .help(collapsed ? "Expand group" : "Collapse group")
    }

    private func toggleGroup(_ id: String) {
        var set = state.collapsedGroups[view.id] ?? []
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation(.snappy(duration: 0.2)) { state.collapsedGroups[view.id] = set }
    }

    private func recordTitle(_ id: String, layout: Layout, startField: FieldModel) -> some View {
        let record = document.record(id)
        let color = record.flatMap { document.recordColor($0, view: view) }
        let span = layout.spans[id]
        let blocked = layout.dependencies.contains { $0.dependentID == id && $0.isViolated }
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color?.swiftUI ?? Color.clear)
                .frame(width: 3, height: 16)
            Text(record.map { document.primaryTitle($0) } ?? "")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if blocked {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .help("Starts before something it depends on has finished")
            }
            Spacer(minLength: 4)
            if style == .gantt, let span {
                Text("\(span.dayCount(calendar: calendar))d")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if span == nil {
                Text("No date")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(hoveredRecord == id ? Color(nsColor: Theme.rowHover) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hoveredRecord = $0 ? id : (hoveredRecord == id ? nil : hoveredRecord) }
        .onTapGesture { open(id, layout: layout) }
        .contextMenu { recordMenu(id, layout: layout) }
    }

    @ViewBuilder
    private func recordMenu(_ id: String, layout: Layout) -> some View {
        Button("Expand Record") { open(id, layout: layout) }
        Button("Duplicate Record") { _ = document.duplicateRecords([id]) }
        Divider()
        Button("Delete Record", role: .destructive) { document.deleteRecords([id]) }
    }

    private func open(_ id: String, layout: Layout) {
        state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id, siblings: layout.recordIDs)
    }

    private func bar(_ id: String, frame: CGRect, visibleMinX: CGFloat, layout: Layout, movable: Bool, resizable: Bool, violated: Bool, startField: FieldModel, endField: FieldModel?) -> some View {
        let record = document.record(id)
        let title = record.map { document.primaryTitle($0) } ?? ""
        let color = record.flatMap { document.recordColor($0, view: view) } ?? .blue
        let dragging = drag?.recordID == id
        let textWidth = CGFloat(title.count) * 6.6 + 18
        // Titles that would be cut short sit beside the bar instead.
        let inside = frame.width >= min(textWidth, 180)
        // A bar that starts off screen keeps its title in view.
        let titleInset = max(0, min(visibleMinX - frame.minX, frame.width - min(textWidth, frame.width)))
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.chipBackground)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(violated ? Color.red : color.swiftUI.opacity(0.55), lineWidth: violated ? 1.5 : 1)
            if inside {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(color.chipText)
                    .padding(.leading, 8 + titleInset)
                    .padding(.trailing, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(width: frame.width, height: frame.height)
        .overlay(alignment: .leading) {
            if !inside {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: frame.width + 6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if resizable {
                ResizeHandle(visible: hoveredRecord == id || dragging, tint: color.chipText)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                drag = BarDrag(recordID: id, resizeDays: Int((value.translation.width / layout.pointsPerDay).rounded()))
                            }
                            .onEnded { _ in commitDrag(startField: startField, endField: endField) }
                    )
            }
        }
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: 4, y: 2)
        .contentShape(Rectangle())
        .onHover { hoveredRecord = $0 ? id : (hoveredRecord == id ? nil : hoveredRecord) }
        .onTapGesture { open(id, layout: layout) }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard movable else { return }
                    drag = BarDrag(recordID: id, moveDays: Int((value.translation.width / layout.pointsPerDay).rounded()))
                }
                .onEnded { _ in commitDrag(startField: startField, endField: endField) }
        )
        .contextMenu { recordMenu(id, layout: layout) }
        .help(barHelp(id, title: title, layout: layout, violated: violated))
        .offset(x: frame.minX, y: frame.minY)
    }

    private func barHelp(_ id: String, title: String, layout: Layout, violated: Bool) -> String {
        guard let span = layout.spans[id] else { return title }
        let range = span.start == span.end
            ? span.start.formatted(date: .abbreviated, time: .omitted)
            : "\(span.start.formatted(date: .abbreviated, time: .omitted)) – \(span.end.formatted(date: .abbreviated, time: .omitted))"
        var text = "\(title)\n\(range)"
        if violated {
            let blockers = layout.dependencies.filter { $0.dependentID == id && $0.isViolated }.map { document.primaryTitle(recordID: $0.prerequisiteID) }
            text += "\nStarts before \(ListFormatter.localizedString(byJoining: blockers)) finishes"
        }
        return text
    }

    private func commitDrag(startField: FieldModel, endField: FieldModel?) {
        guard let current = drag else { return }
        drag = nil
        let updates = document.scheduleUpdate(recordID: current.recordID, startField: startField, endField: endField, moveDays: current.moveDays, resizeDays: current.resizeDays, calendar: calendar)
        guard !updates.isEmpty else { return }
        document.updateRecord(current.recordID, values: updates, actionName: current.resizeDays != 0 ? "Change Dates" : "Reschedule")
    }

    /// Double-clicking the empty track of an unscheduled record puts it on that day.
    private func schedule(at location: CGPoint, layout: Layout, startField: FieldModel) {
        guard startField.type == .date,
              let row = layout.tops.lastIndex(where: { $0 <= location.y }), location.y < layout.tops[row] + layout.heights[row],
              case .record(let id) = layout.rows[row], layout.spans[id] == nil,
              let day = calendar.date(byAdding: .day, value: Int(location.x / layout.pointsPerDay), to: layout.rangeStart)
        else { return }
        document.updateRecord(id, values: [startField.id: encoded(day, for: startField)], actionName: "Schedule Record")
    }

    private func encoded(_ day: Date, for field: FieldModel) -> JSONValue {
        let date = field.includesTime ? (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day) : day
        return .string(DateCoding.encode(date, includeTime: field.includesTime))
    }

    private func addRecord(on day: Date) {
        var values: [String: JSONValue] = [:]
        if let start = document.field(view.config.dateFieldID), start.type == .date {
            values[start.id] = encoded(day, for: start)
        }
        let id = document.createRecord(in: view.tableID, values: values)
        state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
    }
}

/// The grab area on a bar's right end for stretching it.
private struct ResizeHandle: View {
    let visible: Bool
    let tint: Color
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: 3, height: 12)
                .opacity(visible ? 1 : 0)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside, !cursorPushed {
                NSCursor.resizeLeftRight.push()
                cursorPushed = true
            } else if !inside, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed { NSCursor.pop() }
        }
        .help("Drag to change the end date")
    }
}

/// Draws the visible part of the chart: the date axis, swimlane bands, weekends, period lines,
/// today's marker and dependency arrows. Coordinates are the chart's own, offset by `visible`.
private struct ScheduleCanvas: View {
    enum Part { case axis, body }

    let part: Part
    let layout: ScheduleChart.Layout
    let scale: TimelineScale
    let visible: CGRect
    let hoveredRow: Int?

    var body: some View {
        Canvas { ctx, _ in
            ctx.translateBy(x: -visible.minX, y: part == .axis ? 0 : -visible.minY)
            let calendar = Calendar.current
            let axis = ScheduleChart.axisHeight
            let ppd = layout.pointsPerDay
            let line = Color(nsColor: Theme.gridLine)
            let firstDay = max(0, Int((visible.minX / ppd).rounded(.down)) - 1)
            let lastDay = min(layout.dayCount - 1, Int((visible.maxX / ppd).rounded(.up)) + 1)
            guard firstDay <= lastDay else { return }
            let days: [(index: Int, date: Date)] = (firstDay...lastDay).compactMap { i in
                calendar.date(byAdding: .day, value: i, to: layout.rangeStart).map { (i, $0) }
            }
            let bodyTop = max(visible.minY, axis)
            let today = calendar.startOfDay(for: Date())
            let todayIndex = calendar.dateComponents([.day], from: layout.rangeStart, to: today).day ?? -1
            let todayX = CGFloat(todayIndex) * ppd

            if part == .body {
                guard visible.maxY > axis else { return }
                let bottom = visible.maxY
                if scale == .week || scale == .month {
                    for day in days where calendar.isDateInWeekend(day.date) {
                        ctx.fill(Path(CGRect(x: CGFloat(day.index) * ppd, y: bodyTop, width: ppd, height: bottom - bodyTop)), with: .color(.primary.opacity(0.028)))
                    }
                }
                for day in days {
                    let (major, minor) = boundaries(day.date, calendar: calendar)
                    if major || minor {
                        ctx.fill(Path(CGRect(x: CGFloat(day.index) * ppd, y: bodyTop, width: 1, height: bottom - bodyTop)), with: .color(major ? line : line.opacity(0.5)))
                    }
                }
                let firstRow = max(0, (layout.tops.lastIndex { $0 + axis <= bodyTop }) ?? 0)
                var row = firstRow
                while row < layout.rows.count, layout.tops[row] + axis < bottom {
                    let top = layout.tops[row] + axis
                    let height = layout.heights[row]
                    if case .group = layout.rows[row] {
                        ctx.fill(Path(CGRect(x: visible.minX, y: top, width: visible.width, height: height)), with: .color(Color(nsColor: Theme.groupBackground)))
                    } else if row == hoveredRow {
                        ctx.fill(Path(CGRect(x: visible.minX, y: top, width: visible.width, height: height)), with: .color(Color(nsColor: Theme.rowHover)))
                    }
                    ctx.fill(Path(CGRect(x: visible.minX, y: top + height - 1, width: visible.width, height: 1)), with: .color(line))
                    row += 1
                }
                if todayIndex >= 0 && todayIndex < layout.dayCount {
                    ctx.fill(Path(CGRect(x: todayX, y: bodyTop, width: ppd, height: bottom - bodyTop)), with: .color(.red.opacity(0.07)))
                    ctx.fill(Path(CGRect(x: todayX + ppd / 2 - 1, y: bodyTop, width: 2, height: bottom - bodyTop)), with: .color(.red.opacity(0.85)))
                }
                var arrows = ctx
                arrows.translateBy(x: 0, y: axis)
                drawDependencies(&arrows, calendar: calendar)
                return
            }

            let axisRect = CGRect(x: visible.minX, y: 0, width: visible.width, height: axis)
            ctx.fill(Path(axisRect), with: .color(Color(nsColor: .windowBackgroundColor)))
            drawAxis(&ctx, days: days, calendar: calendar)
            if todayIndex >= 0 && todayIndex < layout.dayCount {
                let center = todayX + ppd / 2
                let label = ctx.resolve(Text("Today").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                let w = label.measure(in: CGSize(width: 100, height: 20)).width + 12
                let pill = CGRect(x: center - w / 2, y: 28, width: w, height: 16)
                ctx.fill(Path(roundedRect: pill, cornerRadius: 8), with: .color(.red))
                ctx.draw(label, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
                ctx.fill(Path(CGRect(x: center - 1, y: pill.maxY, width: 2, height: axis - pill.maxY)), with: .color(.red.opacity(0.85)))
            }
            ctx.fill(Path(CGRect(x: visible.minX, y: axis - 1, width: visible.width, height: 1)), with: .color(line))
        }
    }

    /// Whether a day starts a major period (month, or year on the year scale) or a minor one.
    private func boundaries(_ date: Date, calendar: Calendar) -> (major: Bool, minor: Bool) {
        let dayOfMonth = calendar.component(.day, from: date)
        let major = dayOfMonth == 1 && (scale != .year || calendar.component(.month, from: date) == 1)
        let minor: Bool
        switch scale {
        case .week: minor = true
        case .month, .quarter: minor = calendar.component(.weekday, from: date) == calendar.firstWeekday
        case .year: minor = dayOfMonth == 1
        }
        return (major, minor)
    }

    private func majorLabel(_ date: Date) -> String {
        scale == .year ? date.formatted(.dateTime.year()) : date.formatted(.dateTime.month(.wide).year())
    }

    private func drawAxis(_ ctx: inout GraphicsContext, days: [(index: Int, date: Date)], calendar: Calendar) {
        let ppd = layout.pointsPerDay
        let line = Color(nsColor: Theme.gridLine)
        let majorFont = Font.system(size: 11, weight: .semibold)
        let minorFont = Font.system(size: 9, weight: .medium)
        let labelSpace: CGFloat = scale == .year ? 40 : 110
        let majorStarts = days.filter { boundaries($0.date, calendar: calendar).major }
        // The period already under way at the left edge keeps its label pinned there.
        if let first = days.first(where: { CGFloat($0.index) * ppd >= visible.minX }) ?? days.first {
            let nextMajorX = majorStarts.first { CGFloat($0.index) * ppd > visible.minX }.map { CGFloat($0.index) * ppd } ?? .infinity
            if !boundaries(first.date, calendar: calendar).major || CGFloat(first.index) * ppd > visible.minX + 1, nextMajorX - visible.minX >= labelSpace {
                ctx.draw(Text(majorLabel(first.date)).font(majorFont).foregroundStyle(.primary), at: CGPoint(x: visible.minX + 6, y: 13), anchor: .leading)
            }
        }
        for day in majorStarts {
            let x = CGFloat(day.index) * ppd
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: ScheduleChart.axisHeight)), with: .color(line))
            if x >= visible.minX {
                ctx.draw(Text(majorLabel(day.date)).font(majorFont).foregroundStyle(.primary), at: CGPoint(x: x + 6, y: 13), anchor: .leading)
            }
        }
        for day in days {
            let x = CGFloat(day.index) * ppd
            let d = day.date
            switch scale {
            case .week:
                let text = d.formatted(.dateTime.weekday(.abbreviated)) + " " + d.formatted(.dateTime.day())
                ctx.draw(Text(text).font(minorFont).foregroundStyle(calendar.isDateInWeekend(d) ? .tertiary : .secondary), at: CGPoint(x: x + ppd / 2, y: 36), anchor: .center)
                ctx.fill(Path(CGRect(x: x, y: 26, width: 1, height: ScheduleChart.axisHeight - 26)), with: .color(line.opacity(0.6)))
            case .month:
                ctx.draw(Text(d.formatted(.dateTime.day())).font(minorFont).foregroundStyle(calendar.isDateInWeekend(d) ? .tertiary : .secondary), at: CGPoint(x: x + ppd / 2, y: 36), anchor: .center)
            case .quarter:
                if calendar.component(.weekday, from: d) == calendar.firstWeekday {
                    ctx.draw(Text(d.formatted(.dateTime.day())).font(minorFont).foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 36), anchor: .leading)
                    ctx.fill(Path(CGRect(x: x, y: 28, width: 1, height: ScheduleChart.axisHeight - 28)), with: .color(line.opacity(0.6)))
                }
            case .year:
                if calendar.component(.day, from: d) == 1 {
                    ctx.draw(Text(d.formatted(.dateTime.month(.abbreviated))).font(minorFont).foregroundStyle(.secondary), at: CGPoint(x: x + 4, y: 36), anchor: .leading)
                    ctx.fill(Path(CGRect(x: x, y: 28, width: 1, height: ScheduleChart.axisHeight - 28)), with: .color(line.opacity(0.6)))
                }
            }
        }
    }

    /// Elbow arrows from the end of each prerequisite to the start of the record depending on it.
    private func drawDependencies(_ ctx: inout GraphicsContext, calendar: Calendar) {
        for dep in layout.dependencies {
            guard let from = layout.barFrame(dep.prerequisiteID, calendar: calendar),
                  let to = layout.barFrame(dep.dependentID, calendar: calendar),
                  let toRow = layout.rowOfRecord[dep.dependentID] else { continue }
            let color: Color = dep.isViolated ? .red : Color.secondary.opacity(0.75)
            let start = CGPoint(x: from.maxX, y: from.midY)
            let end = CGPoint(x: to.minX - 1, y: to.midY)
            var points = [start]
            if end.x - start.x >= 18 {
                let midX = start.x + 9
                points += [CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y)]
            } else {
                // Loop back between the rows when the dependent starts too early.
                let laneY = end.y > start.y ? layout.tops[toRow] : layout.tops[toRow] + layout.heights[toRow]
                points += [CGPoint(x: start.x + 9, y: start.y), CGPoint(x: start.x + 9, y: laneY), CGPoint(x: end.x - 12, y: laneY), CGPoint(x: end.x - 12, y: end.y)]
            }
            points.append(CGPoint(x: end.x - 6, y: end.y))
            ctx.stroke(roundedPolyline(points, radius: 4), with: .color(color), style: StrokeStyle(lineWidth: dep.isViolated ? 1.6 : 1.3, lineCap: .round, lineJoin: .round))
            var head = Path()
            head.move(to: CGPoint(x: end.x, y: end.y))
            head.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
            head.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
            head.closeSubpath()
            ctx.fill(head, with: .color(color))
        }
    }

    private func roundedPolyline(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 1..<points.count {
            if i + 1 < points.count {
                let corner = points[i]
                let limit = min(radius, hypot(corner.x - points[i - 1].x, corner.y - points[i - 1].y) / 2, hypot(points[i + 1].x - corner.x, points[i + 1].y - corner.y) / 2)
                path.addArc(tangent1End: corner, tangent2End: points[i + 1], radius: max(0, limit))
            } else {
                path.addLine(to: points[i])
            }
        }
        return path
    }
}
