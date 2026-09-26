import Foundation
import Testing
@testable import RowHouseCore

@Suite("Base document") @MainActor
struct DocumentTests {
    @Test func newTablesComeWithStarterFieldsViewsAndRows() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Tasks")
        #expect(doc.fields(in: t).map(\.name) == ["Name", "Notes", "Status", "Attachments"])
        #expect(doc.primaryField(of: t)?.name == "Name")
        #expect(doc.views(in: t).map(\.type) == [.grid])
        #expect(doc.recordCount(in: t) == 3)
        #expect(doc.createTable(name: "Tasks") != t)
        #expect(doc.tables.map(\.name) == ["Tasks", "Tasks 2"])
    }

    @Test func linkFieldsStayConsistentFromBothSides() {
        let doc = TestSupport.document()
        let projects = doc.createTable(name: "Projects", starterFields: false, emptyRecords: 0)
        let tasks = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        var options = FieldOptions()
        options.linkedTableID = projects
        let link = doc.createField(in: tasks, name: "Project", type: .link, options: options)
        let inverse = doc.field(link)!.options.inverseFieldID!
        #expect(doc.field(inverse)?.tableID == projects)
        #expect(doc.field(inverse)?.isInverseLink == true)

        let pName = doc.primaryField(of: projects)!.id
        let tName = doc.primaryField(of: tasks)!.id
        let website = doc.createRecord(in: projects, values: [pName: "Website"])
        let design = doc.createRecord(in: tasks, values: [tName: "Design", link: [.string(website)]])
        let build = doc.createRecord(in: tasks, values: [tName: "Build"])

        #expect(doc.displayString(doc.record(website)!, doc.field(inverse)!) == "Design")
        // Editing the inverse side writes to the owning side.
        doc.updateRecord(website, values: [inverse: [.string(design), .string(build)]])
        #expect(doc.displayString(doc.record(build)!, doc.field(link)!) == "Website")
        doc.updateRecord(website, values: [inverse: [.string(build)]])
        #expect(doc.value(doc.record(design)!, doc.field(link)!) == .empty)
        // Deleting a linked record removes it from the other side.
        doc.deleteRecords([build])
        #expect(doc.value(doc.record(website)!, doc.field(inverse)!) == .empty)
    }

    @Test func lookupsRollupsAndCountsFollowLinks() {
        let doc = TestSupport.document()
        let projects = doc.createTable(name: "Projects", starterFields: false, emptyRecords: 0)
        let tasks = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        var linkOptions = FieldOptions()
        linkOptions.linkedTableID = tasks
        let link = doc.createField(in: projects, name: "Tasks", type: .link, options: linkOptions)
        let hours = doc.createField(in: tasks, name: "Hours", type: .number)
        var lookup = FieldOptions()
        lookup.linkFieldID = link
        lookup.targetFieldID = hours
        let lookupField = doc.createField(in: projects, name: "Hours list", type: .lookup, options: lookup)
        var rollup = lookup
        rollup.rollupFormula = "SUM(values) * 2"
        let rollupField = doc.createField(in: projects, name: "Double hours", type: .rollup, options: rollup)
        var count = FieldOptions()
        count.linkFieldID = link
        let countField = doc.createField(in: projects, name: "Count", type: .count, options: count)

        let t1 = doc.createRecord(in: tasks, values: [hours: 3])
        let t2 = doc.createRecord(in: tasks, values: [hours: 4.5])
        let p = doc.createRecord(in: projects, values: [link: [.string(t1), .string(t2)]])
        let record = doc.record(p)!
        #expect(doc.value(record, doc.field(countField)!) == .number(2))
        #expect(doc.value(record, doc.field(rollupField)!) == .number(15))
        #expect(doc.displayString(record, doc.field(lookupField)!) == "3, 4.5")

        doc.updateRecord(t1, values: [hours: 10])
        #expect(doc.value(doc.record(p)!, doc.field(rollupField)!) == .number(29))
    }

    @Test func formulasSurviveFieldRenames() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Sales", starterFields: false, emptyRecords: 0)
        let price = doc.createField(in: t, name: "Price", type: .currency)
        let qty = doc.createField(in: t, name: "Qty", type: .number)
        var options = FieldOptions()
        options.formula = "{Price} * {Qty}"
        let total = doc.createField(in: t, name: "Total", type: .formula, options: options)
        #expect(doc.field(total)!.options.formula == "{\(price)} * {\(qty)}")
        let r = doc.createRecord(in: t, values: [price: 2.5, qty: 4])
        #expect(doc.value(doc.record(r)!, doc.field(total)!) == .number(10))

        doc.renameField(qty, to: "Quantity")
        #expect(doc.value(doc.record(r)!, doc.field(total)!) == .number(10))
        #expect(doc.formulaWithFieldNames(doc.field(total)!.options.formula!, tableID: t) == "{Price} * {Quantity}")
    }

    @Test func circularFormulasReportAnError() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Loop", starterFields: false, emptyRecords: 0)
        var a = FieldOptions()
        a.formula = "1"
        let fa = doc.createField(in: t, name: "A", type: .formula, options: a)
        var b = FieldOptions()
        b.formula = "{A} + 1"
        let fb = doc.createField(in: t, name: "B", type: .formula, options: b)
        var loop = doc.field(fa)!.options
        loop.formula = "{B} + 1"
        doc.updateField(fa, options: loop)
        let r = doc.createRecord(in: t)
        if case .error = doc.value(doc.record(r)!, doc.field(fb)!) {} else {
            Issue.record("Expected a circular reference error")
        }
    }

    @Test func changingFieldTypesConvertsValues() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Things", starterFields: false, emptyRecords: 0)
        let f = doc.createField(in: t, name: "Size", type: .singleLineText)
        let r1 = doc.createRecord(in: t, values: [f: "Large"])
        let r2 = doc.createRecord(in: t, values: [f: "Small"])
        let r3 = doc.createRecord(in: t, values: [f: "Large"])
        doc.updateField(f, type: .singleSelect)
        let field = doc.field(f)!
        #expect(field.choices.map(\.name) == ["Large", "Small"])
        #expect(doc.displayString(doc.record(r1)!, field) == "Large")
        #expect(doc.record(r1)![f] == doc.record(r3)![f])
        #expect(doc.displayString(doc.record(r2)!, field) == "Small")

        let n = doc.createField(in: t, name: "Amount", type: .singleLineText)
        doc.updateRecord(r1, values: [n: "$1,250.50"])
        doc.updateField(n, type: .number)
        #expect(doc.record(r1)![n] == .number(1250.5))
    }

    @Test func undoAndRedoRestoreEdits() {
        let doc = TestSupport.document()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let t = doc.createTable(name: "Undo", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        doc.undoManager = undo

        undo.beginUndoGrouping()
        let r = doc.createRecord(in: t, values: [name: "First"])
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        doc.updateRecord(r, values: [name: "Second"])
        undo.endUndoGrouping()
        #expect(doc.displayString(doc.record(r)!, doc.field(name)!) == "Second")

        undo.undo()
        #expect(doc.displayString(doc.record(r)!, doc.field(name)!) == "First")
        undo.undo()
        #expect(doc.record(r) == nil)
        undo.redo()
        #expect(doc.displayString(doc.record(r)!, doc.field(name)!) == "First")
        undo.redo()
        #expect(doc.displayString(doc.record(r)!, doc.field(name)!) == "Second")
    }

    @Test func batchesSeeTheirOwnWritesAndUndoAsOneStep() {
        let doc = TestSupport.document()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let t = doc.createTable(name: "Batch", starterFields: false, emptyRecords: 0)
        let status = doc.createField(in: t, name: "Status", type: .singleSelect)
        doc.undoManager = undo
        var notified = 0
        doc.addObserver { _ in notified += 1 }
        undo.beginUndoGrouping()
        var id = ""
        doc.batch("Paste") {
            id = doc.createRecord(in: t)
            doc.setCell(recordID: id, fieldID: status, text: "Brand new")
            #expect(doc.field(status)!.choices.map(\.name) == ["Brand new"])
        }
        undo.endUndoGrouping()
        #expect(notified == 1)
        #expect(doc.displayString(doc.record(id)!, doc.field(status)!) == "Brand new")
        undo.undo()
        #expect(doc.record(id) == nil)
        #expect(doc.field(status)!.choices.isEmpty)
    }

    @Test func autonumbersFollowCreationOrderAndAreNeverReused() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Tickets", starterFields: false, emptyRecords: 0)
        let auto = doc.createField(in: t, name: "No.", type: .autoNumber)
        let a = doc.createRecord(in: t)
        let b = doc.createRecord(in: t)
        doc.deleteRecords([a])
        let c = doc.createRecord(in: t)
        #expect(doc.value(doc.record(b)!, doc.field(auto)!) == .number(2))
        #expect(doc.value(doc.record(c)!, doc.field(auto)!) == .number(3))
    }

    @Test func parsingUserInputPerFieldType() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Parse", starterFields: false, emptyRecords: 0)
        func field(_ type: FieldType, _ configure: (inout FieldOptions) -> Void = { _ in }) -> FieldModel {
            var o = FieldOptions()
            configure(&o)
            return doc.field(doc.createField(in: t, name: type.rawValue, type: type, options: o))!
        }
        #expect(doc.parseValue("50%", for: field(.percent), createMissingChoices: false) == .number(0.5))
        #expect(doc.parseValue("1:30", for: field(.duration), createMissingChoices: false) == .number(5400))
        #expect(doc.parseValue("yes", for: field(.checkbox), createMissingChoices: false) == .bool(true))
        #expect(doc.parseValue("★★★", for: field(.rating), createMissingChoices: false) == .number(3))
        #expect(doc.parseValue("(12.5)", for: field(.number), createMissingChoices: false) == .number(-12.5))
        #expect(doc.parseValue("2026-09-26", for: field(.date), createMissingChoices: false) == .string("2026-09-26"))
        let multi = field(.multipleSelects)
        let parsed = doc.parseValue("Red, Blue", for: multi, createMissingChoices: true)
        #expect(doc.field(multi.id)!.choices.map(\.name) == ["Red", "Blue"])
        #expect(parsed.stringArray.count == 2)
    }

    @Test func deletingATableRemovesLinksPointingAtIt() {
        let doc = TestSupport.document()
        let a = doc.createTable(name: "A", starterFields: false, emptyRecords: 0)
        let b = doc.createTable(name: "B", starterFields: false, emptyRecords: 0)
        var o = FieldOptions()
        o.linkedTableID = b
        let link = doc.createField(in: a, name: "To B", type: .link, options: o)
        doc.deleteTable(b)
        #expect(doc.field(link) == nil)
        #expect(doc.tables.map(\.name) == ["A"])
    }

    @Test func duplicateTableCopiesStructureAndRecords() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Original")
        let name = doc.primaryField(of: t)!.id
        doc.updateRecord(doc.records(in: t)[0].id, values: [name: "Row one"])
        let copy = doc.duplicateTable(t, includeRecords: true)!
        #expect(doc.table(copy)?.name == "Original copy")
        #expect(doc.recordCount(in: copy) == 3)
        #expect(doc.findRecord(titled: "Row one", in: copy) != nil)
        #expect(doc.fields(in: copy).map(\.name) == doc.fields(in: t).map(\.name))
    }

    @Test func commentsAreStoredPerRecord() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "C")
        let r = doc.records(in: t)[0].id
        doc.addComment(to: r, text: "  Looks good  ")
        #expect(doc.comments(for: r).map(\.text) == ["Looks good"])
        doc.deleteComment(doc.comments(for: r)[0].id)
        #expect(doc.comments(for: r).isEmpty)
    }

    @Test func templatesBuildWorkingBases() {
        for template in BaseTemplate.allCases {
            let doc = TestSupport.document()
            doc.apply(template: template, storage: nil)
            #expect(!doc.tables.isEmpty, "\(template) has tables")
            for table in doc.tables {
                for field in doc.fields(in: table.id) where field.type == .formula || field.type == .rollup {
                    for record in doc.records(in: table.id) {
                        if case .error(let message) = doc.value(record, field) {
                            Issue.record("\(template) \(table.name).\(field.name): \(message)")
                        }
                    }
                }
            }
        }
    }
}
