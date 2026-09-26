import Charts
import RowHouseCore
import SwiftUI

struct ChartView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState

    private var document: BaseDocument { session.document }
    private var chart: ChartConfig { view.config.chart ?? ChartConfig() }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let category = document.field(chart.categoryFieldID) {
                let data = document.chartData(chart, recordIDs: document.evaluate(view: view, search: state.search[view.tableID] ?? "").recordIDs)
                if data.isEmpty {
                    ContentUnavailableView("No data to chart", systemImage: "chart.bar", description: Text("Records in this view don't have values for \(category.name) yet."))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        summary(data)
                        ChartPlot(data: data, kind: chart.kind ?? .bar, categoryName: category.name, format: format)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView("Choose what to chart", systemImage: "chart.pie", description: Text("Pick a field to group records by."))
            }
        }
    }

    private var controls: some View {
        let fields = document.fields(in: view.tableID)
        let numeric = fields.filter { $0.type.isNumeric || $0.type == .formula || $0.type == .rollup }
        return ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 14) {
            Picker("", selection: binding(\.kind, default: .bar)) {
                ForEach(ChartKind.allCases, id: \.self) { k in
                    Label(k.displayName, systemImage: icon(k)).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Group by", selection: Binding(get: { chart.categoryFieldID ?? "" }, set: { id in update { $0.categoryFieldID = id.isEmpty ? nil : id } })) {
                ForEach(fields.filter { $0.type != .attachment && $0.type != .button }) { Text($0.name).tag($0.id) }
            }
            .fixedSize()
            Picker("Show", selection: binding(\.aggregate, default: .count)) {
                ForEach(ChartAggregate.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .fixedSize()
            if (chart.aggregate ?? .count) != .count {
                Picker("of", selection: Binding(get: { chart.valueFieldID ?? "" }, set: { id in update { $0.valueFieldID = id.isEmpty ? nil : id } })) {
                    Text("Choose…").tag("")
                    ForEach(numeric) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
            }
            Toggle("Sort by value", isOn: Binding(get: { chart.sortByValue ?? false }, set: { v in update { $0.sortByValue = v } }))
                .toggleStyle(.checkbox)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        }
    }

    private func icon(_ k: ChartKind) -> String {
        switch k {
        case .bar: "chart.bar.fill"
        case .line: "chart.xyaxis.line"
        case .pie: "chart.pie.fill"
        case .donut: "circle.dashed"
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ChartConfig, T?>, default value: T) -> Binding<T> {
        Binding(get: { chart[keyPath: keyPath] ?? value }, set: { v in update { $0[keyPath: keyPath] = v } })
    }

    private func update(_ change: (inout ChartConfig) -> Void) {
        document.updateViewConfig(view.id, actionName: "Edit Chart") { config in
            var c = config.chart ?? ChartConfig()
            change(&c)
            config.chart = c
        }
    }

    private func format(_ value: Double) -> String {
        document.formatAggregate(value, aggregate: chart.aggregate ?? .count, field: document.field(chart.valueFieldID))
    }

    private func summary(_ data: [ChartDatum]) -> some View {
        let total = data.reduce(0) { $0 + $1.value }
        let title: String = {
            let agg = chart.aggregate ?? .count
            if agg == .count { return "Records by \(document.field(chart.categoryFieldID)?.name ?? "")" }
            return "\(agg.displayName) of \(document.field(chart.valueFieldID)?.name ?? "value") by \(document.field(chart.categoryFieldID)?.name ?? "")"
        }()
        return HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if (chart.aggregate ?? .count) == .count || (chart.aggregate ?? .count) == .sum {
                Text("Total \(format(total))").font(.headline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// Draws chart data as bars, a line, a pie or a donut. Shared by chart views and dashboards.
struct ChartPlot: View {
    let data: [ChartDatum]
    let kind: ChartKind
    let categoryName: String
    var compact = false
    let format: (Double) -> String

    var body: some View {
        let domain = data.map(\.label)
        let colors = data.map(color)
        switch kind {
        case .bar:
            Chart(data) { d in
                BarMark(x: .value(categoryName, d.label), y: .value("Value", d.value))
                    .foregroundStyle(by: .value(categoryName, d.label))
                    .cornerRadius(compact ? 4 : 5)
                    .annotation(position: .top) {
                        Text(format(d.value)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
            .chartForegroundStyleScale(domain: domain, range: colors)
            .chartLegend(.hidden)
            .chartYAxis { valueAxis }
        case .line:
            Chart(data) { d in
                LineMark(x: .value(categoryName, d.label), y: .value("Value", d.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: compact ? 2.5 : 3))
                PointMark(x: .value(categoryName, d.label), y: .value("Value", d.value))
                    .annotation(position: .top) { Text(format(d.value)).font(.caption).foregroundStyle(.secondary) }
            }
            .chartYAxis { valueAxis }
        case .pie, .donut:
            Chart(data) { d in
                SectorMark(angle: .value("Value", d.value), innerRadius: .ratio(kind == .donut ? 0.58 : 0), angularInset: 1.5)
                    .foregroundStyle(by: .value(categoryName, d.label))
                    .cornerRadius(4)
                    .annotation(position: .overlay) {
                        if d.value > 0 { Text(format(d.value)).font(.caption.weight(.bold)).foregroundStyle(.white) }
                    }
            }
            .chartForegroundStyleScale(domain: domain, range: colors)
            .chartLegend(position: compact ? .bottom : .trailing, alignment: .center, spacing: compact ? 10 : 20)
        }
    }

    /// Value axis labels formatted like the data (currency, percent, duration…).
    private var valueAxis: some AxisContent {
        AxisMarks(position: .trailing) { value in
            AxisGridLine()
            AxisValueLabel {
                if let v = value.as(Double.self) { Text(format(v)) }
            }
        }
    }

    private func color(_ d: ChartDatum) -> Color {
        d.isEmptyBucket ? Color.gray.opacity(0.5) : d.color.swiftUI
    }
}
