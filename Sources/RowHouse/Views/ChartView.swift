import Charts
import RowHouseCore
import SwiftUI

struct ChartView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState

    private var document: BaseDocument { session.document }
    private var chart: ChartConfig { view.config.chart ?? ChartConfig() }

    struct Datum: Identifiable {
        var id: String
        var label: String
        var value: Double
        var color: Color
        var order: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let category = document.field(chart.categoryFieldID) {
                let data = compute(category: category)
                if data.isEmpty {
                    ContentUnavailableView("No data to chart", systemImage: "chart.bar", description: Text("Records in this view don't have values for \(category.name) yet."))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        summary(data)
                        chartBody(data, category: category)
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

    private func compute(category: FieldModel) -> [Datum] {
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "")
        let aggregate = chart.aggregate ?? .count
        let valueField = document.field(chart.valueFieldID)
        var buckets: [String: (label: String, color: Color, order: Int, values: [Double], count: Int)] = [:]
        let palette: [ChoiceColor] = [.blue, .purple, .teal, .orange, .pink, .green, .yellow, .red, .cyan, .gray]
        for id in result.recordIDs {
            guard let r = document.record(id) else { continue }
            let v = document.value(r, category)
            var keys: [(String, String, Color, Int)] = []
            switch v {
            case .choice(let c):
                keys = [(c.id, c.name, c.color.swiftUI, category.choices.firstIndex { $0.id == c.id } ?? 0)]
            case .choices(let cs):
                keys = cs.map { c in (c.id, c.name, c.color.swiftUI, category.choices.firstIndex { $0.id == c.id } ?? 0) }
            case .links(let refs):
                keys = refs.map { ($0.id, $0.title, .accentColor, 0) }
            case .collaborators(let people):
                keys = people.map { ($0.id, $0.displayName, $0.color.swiftUI, 0) }
            case .empty:
                keys = [("", "Empty", .gray.opacity(0.5), Int.max)]
            case .bool(let b):
                keys = [(b ? "1" : "0", b ? "Checked" : "Unchecked", b ? .green : .gray, b ? 0 : 1)]
            default:
                let label = document.displayString(r, category)
                keys = [(label, label.isEmpty ? "Empty" : label, .accentColor, 0)]
            }
            let number = valueField.flatMap { f -> Double? in
                let cell = document.value(r, f)
                if case .list(let items) = cell { return items.compactMap(\.numberValue).reduce(0, +) }
                return cell.numberValue
            }
            for (key, label, color, order) in keys {
                var bucket = buckets[key] ?? (label, color, order, [], 0)
                bucket.count += 1
                if let number { bucket.values.append(number) }
                buckets[key] = bucket
            }
        }
        var data: [Datum] = buckets.map { key, b in
            let value: Double
            switch aggregate {
            case .count: value = Double(b.count)
            case .sum: value = b.values.reduce(0, +)
            case .average: value = b.values.isEmpty ? 0 : b.values.reduce(0, +) / Double(b.values.count)
            case .min: value = b.values.min() ?? 0
            case .max: value = b.values.max() ?? 0
            }
            return Datum(id: key, label: b.label, value: value, color: b.color, order: b.order)
        }
        if category.type != .singleSelect && category.type != .multipleSelects && category.type != .checkbox {
            let sortedKeys = data.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            for (i, d) in sortedKeys.enumerated() {
                if let idx = data.firstIndex(where: { $0.id == d.id }) {
                    data[idx].order = i
                    if data[idx].id != "" { data[idx].color = palette[i % palette.count].swiftUI }
                }
            }
        }
        if chart.sortByValue == true {
            data.sort { $0.value > $1.value }
        } else {
            data.sort { ($0.order, $0.label) < ($1.order, $1.label) }
        }
        return data
    }

    private func format(_ value: Double) -> String {
        if (chart.aggregate ?? .count) == .count { return String(Int(value)) }
        if let f = document.field(chart.valueFieldID) { return CellFormatter.string(.number(value), field: f) }
        return CellFormatter.number(value, precision: 2)
    }

    private func summary(_ data: [Datum]) -> some View {
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

    @ViewBuilder
    private func chartBody(_ data: [Datum], category: FieldModel) -> some View {
        let domain = data.map(\.label)
        let colors = data.map(\.color)
        switch chart.kind ?? .bar {
        case .bar:
            Chart(data) { d in
                BarMark(x: .value(category.name, d.label), y: .value("Value", d.value))
                    .foregroundStyle(by: .value(category.name, d.label))
                    .cornerRadius(5)
                    .annotation(position: .top) {
                        Text(format(d.value)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
            .chartForegroundStyleScale(domain: domain, range: colors)
            .chartLegend(.hidden)
        case .line:
            Chart(data) { d in
                LineMark(x: .value(category.name, d.label), y: .value("Value", d.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                PointMark(x: .value(category.name, d.label), y: .value("Value", d.value))
                    .annotation(position: .top) { Text(format(d.value)).font(.caption).foregroundStyle(.secondary) }
            }
        case .pie, .donut:
            Chart(data) { d in
                SectorMark(angle: .value("Value", d.value), innerRadius: .ratio((chart.kind ?? .bar) == .donut ? 0.58 : 0), angularInset: 1.5)
                    .foregroundStyle(by: .value(category.name, d.label))
                    .cornerRadius(4)
                    .annotation(position: .overlay) {
                        if d.value > 0 { Text(format(d.value)).font(.caption.weight(.bold)).foregroundStyle(.white) }
                    }
            }
            .chartForegroundStyleScale(domain: domain, range: colors)
            .chartLegend(position: .trailing, alignment: .center, spacing: 20)
        }
    }
}
