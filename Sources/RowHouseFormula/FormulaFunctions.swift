import Foundation

final class FormulaFunction: Sendable {
    enum Evaluation: Sendable, Equatable {
        /// Arguments are evaluated first; an error in any argument (including inside arrays) is returned
        /// without calling the body.
        case eager
        /// Arguments are evaluated first and errors are passed to the body (ISERROR).
        case eagerPassingErrors
        /// The body evaluates arguments itself, only as needed (IF, SWITCH, AND, OR).
        case lazy
    }

    enum Arity: Sendable {
        case exactly(Int)
        case range(Int, Int)
        case atLeast(Int)
    }

    typealias Body = @Sendable (FormulaCall) throws -> FormulaValue

    let info: FormulaFunctionInfo
    let minimumArguments: Int
    let maximumArguments: Int?
    let evaluation: Evaluation
    let body: Body

    init(
        _ signature: String,
        _ category: FormulaFunctionCategory,
        _ arity: Arity,
        evaluation: Evaluation = .eager,
        summary: String,
        body: @escaping Body
    ) {
        let name = String(signature.prefix { $0 != "(" })
        self.info = FormulaFunctionInfo(name: name, signature: signature, summary: summary, category: category.rawValue)
        switch arity {
        case .exactly(let count):
            minimumArguments = count
            maximumArguments = count
        case .range(let minimum, let maximum):
            minimumArguments = minimum
            maximumArguments = maximum
        case .atLeast(let minimum):
            minimumArguments = minimum
            maximumArguments = nil
        }
        self.evaluation = evaluation
        self.body = body
    }

    func accepts(argumentCount: Int) -> Bool {
        argumentCount >= minimumArguments && argumentCount <= (maximumArguments ?? .max)
    }

    var arityMessage: String {
        "\(info.name) expects \(Self.describeArity(minimum: minimumArguments, maximum: maximumArguments))"
    }

    private static func describeArity(minimum: Int, maximum: Int?) -> String {
        func arguments(_ count: Int) -> String {
            count == 1 ? "1 argument" : "\(count) arguments"
        }
        guard let maximum else {
            return "at least \(arguments(minimum))"
        }
        if minimum == maximum {
            return minimum == 0 ? "no arguments" : arguments(minimum)
        }
        if minimum == 0 {
            return "at most \(arguments(maximum))"
        }
        if maximum == minimum + 1 {
            return "\(minimum) or \(maximum) arguments"
        }
        return "\(minimum) to \(maximum) arguments"
    }
}

enum FormulaFunctionCategory: String, Sendable {
    case text = "Text"
    case numeric = "Numeric"
    case logical = "Logical"
    case date = "Date"
    case array = "Array"
    case record = "Record"
    case regex = "Regex"
}

enum FormulaFunctionRegistry {
    static let all: [FormulaFunction] =
        logicalFunctions + textFunctions + regexFunctions + numericFunctions
        + dateFunctions + recordFunctions + arrayFunctions

    private static let byName: [String: FormulaFunction] = {
        var functions: [String: FormulaFunction] = [:]
        for function in all {
            functions[function.info.name] = function
        }
        return functions
    }()

    static func function(named name: String) -> FormulaFunction? {
        byName[name] ?? byName[name.uppercased()]
    }
}
