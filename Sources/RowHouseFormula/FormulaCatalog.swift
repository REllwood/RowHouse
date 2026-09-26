import Foundation

public struct FormulaFunctionInfo: Sendable, Hashable {
    public var name: String
    public var signature: String
    public var summary: String
    public var category: String

    public init(name: String, signature: String, summary: String, category: String) {
        self.name = name
        self.signature = signature
        self.summary = summary
        self.category = category
    }
}

public enum FormulaCatalog: Sendable {
    /// Every function the evaluator implements, sorted by name. Derived from the evaluator's own
    /// function table, so the two can never drift apart.
    public static let functions: [FormulaFunctionInfo] =
        FormulaFunctionRegistry.all.map(\.info).sorted { $0.name < $1.name }

    public static let categories: [String] = ["Logical", "Text", "Regex", "Numeric", "Date", "Array", "Record"]

    /// Case-insensitive lookup, e.g. for editor autocompletion and hover help.
    public static func function(named name: String) -> FormulaFunctionInfo? {
        FormulaFunctionRegistry.function(named: name)?.info
    }
}
