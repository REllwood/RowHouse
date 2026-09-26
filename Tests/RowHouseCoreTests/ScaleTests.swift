import Foundation
import Testing
@testable import RowHouseCore

@Suite("Scale") @MainActor
struct ScaleTests {
    /// Guards against quadratic behaviour in writes, merges and queries.
    @Test func tenThousandRecordsStayFast() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Big", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let n = doc.createField(in: t, name: "N", type: .number)
        var options = FieldOptions()
        options.formula = "IF({N} > 500, \"big\", \"small\") & \" \" & ROUND({N} * 1.1, 2)"
        let formula = doc.createField(in: t, name: "F", type: .formula, options: options)

        let start = Date()
        doc.createRecords(in: t, values: (0..<10_000).map { i in [name: .string("Record \(i)"), n: .number(Double((i * 7919) % 1000))] })
        #expect(doc.recordCount(in: t) == 10_000)

        let view = doc.views(in: t)[0]
        doc.updateViewConfig(view.id) {
            $0.sorts = [SortSpec(fieldID: formula, ascending: false)]
            $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: n, op: .greaterThan, value: 100)])
        }
        let result = doc.evaluate(view: doc.view(view.id)!)
        #expect(result.recordIDs.count == 8_990)

        var copy = BaseState()
        copy.merge(doc.state)
        #expect(copy.all(.record).count == 10_000)
        // Generous budget for unoptimised builds on shared CI machines; quadratic code takes minutes.
        #expect(Date().timeIntervalSince(start) < 20)
    }
}
