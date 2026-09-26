import Foundation

public protocol FormulaContext {
    /// Resolves a field reference (the text inside `{…}` or a bare identifier), which may be a field name
    /// or a field id such as "fldAbc123". Returning nil makes evaluation yield `Unknown field {X}`.
    func value(forField reference: String) -> FormulaValue?
    /// Resolves a variable declared at parse time, e.g. `values` in rollup formulas.
    func variable(_ name: String) -> FormulaValue?
    var recordID: String { get }
    var createdTime: Date { get }
    var lastModifiedTime: Date { get }
    var now: Date { get }
    var timeZone: TimeZone { get }
}
