import Foundation
import Testing
import RowHouseFormula

@Suite("FormulaCatalog")
struct FormulaCatalogTests {
    static let expectedNames: Set<String> = [
        // Logical
        "IF", "SWITCH", "AND", "OR", "XOR", "NOT", "TRUE", "FALSE", "BLANK", "ERROR", "ISERROR",
        // Text
        "CONCATENATE", "LEN", "LOWER", "UPPER", "TRIM", "LEFT", "RIGHT", "MID", "FIND", "SEARCH", "SUBSTITUTE",
        "REPLACE", "REPT", "T", "ENCODE_URL_COMPONENT",
        // Regex
        "REGEX_MATCH", "REGEX_EXTRACT", "REGEX_REPLACE",
        // Numeric
        "ABS", "AVERAGE", "CEILING", "COUNT", "COUNTA", "COUNTALL", "EVEN", "ODD", "EXP", "FLOOR", "INT", "LOG",
        "MAX", "MIN", "MOD", "POWER", "ROUND", "ROUNDDOWN", "ROUNDUP", "SQRT", "SUM", "VALUE",
        // Date
        "NOW", "TODAY", "DATEADD", "DATETIME_DIFF", "DATETIME_FORMAT", "DATETIME_PARSE", "DATESTR", "TIMESTR",
        "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "WEEKDAY", "WEEKNUM", "IS_BEFORE", "IS_AFTER", "IS_SAME",
        "WORKDAY", "WORKDAY_DIFF", "TONOW", "FROMNOW", "SET_TIMEZONE", "SET_LOCALE",
        // Record
        "RECORD_ID", "CREATED_TIME", "LAST_MODIFIED_TIME",
        // Array
        "ARRAYCOMPACT", "ARRAYFLATTEN", "ARRAYJOIN", "ARRAYUNIQUE", "ARRAYSLICE",
    ]

    @Test func catalogListsExactlyTheImplementedFunctions() {
        let names = FormulaCatalog.functions.map(\.name)
        #expect(Set(names) == Self.expectedNames)
        #expect(names.count == Set(names).count, "duplicate catalog entries")
    }

    @Test func catalogIsSortedByName() {
        let names = FormulaCatalog.functions.map(\.name)
        #expect(names == names.sorted())
    }

    @Test func entriesAreWellFormed() {
        for info in FormulaCatalog.functions {
            #expect(info.signature.hasPrefix(info.name + "("), "\(info.name) signature \(info.signature)")
            #expect(info.signature.hasSuffix(")"), "\(info.name) signature \(info.signature)")
            #expect(!info.summary.isEmpty && info.summary.hasSuffix("."), "\(info.name) summary")
            #expect(FormulaCatalog.categories.contains(info.category), "\(info.name) category \(info.category)")
        }
    }

    @Test func categoriesMatchTheSpecification() {
        func category(_ name: String) -> String? { FormulaCatalog.function(named: name)?.category }
        #expect(category("IF") == "Logical")
        #expect(category("LEN") == "Text")
        #expect(category("REGEX_MATCH") == "Regex")
        #expect(category("SUM") == "Numeric")
        #expect(category("DATETIME_DIFF") == "Date")
        #expect(category("RECORD_ID") == "Record")
        #expect(category("ARRAYJOIN") == "Array")
        #expect(FormulaCatalog.function(named: "datetime_diff")?.signature == "DATETIME_DIFF(date1, date2, [unit])")
        #expect(FormulaCatalog.function(named: "IFERROR") == nil)
    }

    /// Every catalog entry must parse and evaluate for some argument count, and never report
    /// "Unknown function"; and the parser must reject names that are not in the catalog.
    @Test func everyCatalogEntryIsImplemented() {
        let context = TestContext()
        for info in FormulaCatalog.functions {
            var accepted = false
            for count in 0...5 {
                let arguments = Array(repeating: "BLANK()", count: count).joined(separator: ", ")
                let source = "\(info.name)(\(arguments))"
                guard let error = syntaxError(source) else {
                    accepted = true
                    let expr = try? FormulaParser.parse(source)
                    #expect(expr != nil)
                    if let expr {
                        let value = FormulaEvaluator.evaluate(expr, in: context)
                        if case .error(let error) = value {
                            #expect(!error.message.contains("Unknown function"), "\(source): \(error.message)")
                        }
                    }
                    continue
                }
                #expect(error.message.hasPrefix("\(info.name) expects"), "\(source): \(error.message)")
            }
            #expect(accepted, "\(info.name) accepted no argument count between 0 and 5")
        }
    }

    @Test func namesOutsideTheCatalogAreRejected() {
        for name in ["IFERROR", "VLOOKUP", "CONCAT", "NOW2", "DATE"] {
            #expect(syntaxError("\(name)(1)")?.message == "Unknown function \(name)")
        }
    }
}
