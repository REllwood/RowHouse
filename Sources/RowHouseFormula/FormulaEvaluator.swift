import Foundation

public enum FormulaEvaluator: Sendable {
    public static func evaluate(_ expr: FormulaExpr, in context: some FormulaContext) -> FormulaValue {
        FormulaInterpreter(context: context).evaluate(expr)
    }
}

struct FormulaInterpreter {
    let context: any FormulaContext
    let timeZone: TimeZone

    init(context: any FormulaContext) {
        self.context = context
        self.timeZone = context.timeZone
    }

    func evaluate(_ expression: FormulaExpr) -> FormulaValue {
        evaluate(expression, chainDepth: 0)
    }

    /// `chainDepth` counts how far we have recursed down the left side of a binary operator chain.
    private func evaluate(_ expression: FormulaExpr, chainDepth: Int) -> FormulaValue {
        switch expression {
        case .number(let value):
            return .number(value)
        case .text(let value):
            return .text(value)
        case .bool(let value):
            return .bool(value)
        case .fieldRef(let reference):
            return context.value(forField: reference) ?? .error(FormulaError("Unknown field {\(reference)}"))
        case .variable(let name):
            return context.variable(name) ?? .error(FormulaError("Unknown variable \(name)"))
        case .unary(let op, let operand):
            return FormulaOperators.applyUnary(op, evaluate(operand))
        case .binary(let op, let lhs, let rhs):
            if chainDepth >= Self.recursiveChainLimit, case .binary = lhs {
                return evaluateChain(expression)
            }
            let left = evaluate(lhs, chainDepth: chainDepth + 1)
            return FormulaOperators.applyBinary(op, left, evaluate(rhs), timeZone: timeZone)
        case .call(let name, let args):
            return call(name, args)
        }
    }

    /// Short operator chains are evaluated recursively (cheapest); beyond this depth the rest of a
    /// left-deep chain is evaluated iteratively.
    private static let recursiveChainLimit = 32

    /// Evaluates a left-deep operator chain such as `a & b & c & …` iteratively, in the same order as
    /// the recursive definition, so long chains don't consume stack.
    private func evaluateChain(_ expression: FormulaExpr) -> FormulaValue {
        var pending: [(op: String, rhs: FormulaExpr)] = []
        var node = expression
        while case .binary(let op, let lhs, let rhs) = node {
            pending.append((op, rhs))
            node = lhs
        }
        var result = evaluate(node)
        for (op, rhs) in pending.reversed() {
            result = FormulaOperators.applyBinary(op, result, evaluate(rhs), timeZone: timeZone)
        }
        return result
    }

    private func call(_ name: String, _ arguments: [FormulaExpr]) -> FormulaValue {
        guard let function = FormulaFunctionRegistry.function(named: name) else {
            return Self.unknownFunction(name)
        }
        guard function.accepts(argumentCount: arguments.count) else {
            return .error(FormulaError(function.arityMessage))
        }
        guard function.evaluation != .lazy else {
            return invoke(function, arguments, values: [])
        }

        var values: [FormulaValue] = []
        values.reserveCapacity(arguments.count)
        for argument in arguments {
            let value = evaluate(argument)
            if function.evaluation == .eager, let error = value.firstError {
                return .error(error)
            }
            values.append(value)
        }
        return invoke(function, arguments, values: values)
    }

    private func invoke(_ function: FormulaFunction, _ arguments: [FormulaExpr], values: [FormulaValue]) -> FormulaValue {
        let result: FormulaValue
        do {
            result = try function.body(FormulaCall(name: function.info.name, arguments: arguments, values: values, interpreter: self))
        } catch let error as FormulaError {
            return .error(error)
        } catch {
            return .error(FormulaError(String(describing: error)))
        }
        if case .number(let number) = result {
            return .checkedNumber(number)
        }
        return result
    }

    private static func unknownFunction(_ name: String) -> FormulaValue {
        .error(FormulaError("Unknown function \(name.uppercased())"))
    }
}

/// The arguments of one function invocation. Eager functions read pre-evaluated `values`; lazy functions
/// evaluate `arguments` on demand with `evaluate(_:)`.
struct FormulaCall {
    let name: String
    let arguments: [FormulaExpr]
    let values: [FormulaValue]
    let interpreter: FormulaInterpreter

    var count: Int { arguments.count }
    var timeZone: TimeZone { interpreter.timeZone }
    var context: any FormulaContext { interpreter.context }

    func has(_ index: Int) -> Bool {
        index < arguments.count
    }

    /// True when the optional argument at `index` was supplied and is not blank.
    func hasValue(_ index: Int) -> Bool {
        index < values.count && !values[index].isBlank
    }

    func evaluate(_ index: Int) -> FormulaValue {
        interpreter.evaluate(arguments[index])
    }

    func value(_ index: Int) -> FormulaValue {
        values[index]
    }

    func number(_ index: Int) throws(FormulaError) -> Double {
        try FormulaCoercion.number(values[index])
    }

    func number(_ index: Int, default fallback: Double) throws(FormulaError) -> Double {
        guard has(index) else { return fallback }
        return try number(index)
    }

    func integer(_ index: Int) throws(FormulaError) -> Int {
        try FormulaMath.clampedInteger(number(index))
    }

    func integer(_ index: Int, default fallback: Int) throws(FormulaError) -> Int {
        guard has(index) else { return fallback }
        return try integer(index)
    }

    func text(_ index: Int) -> String {
        values[index].textValue(in: timeZone)
    }

    func date(_ index: Int) throws(FormulaError) -> Date? {
        try FormulaCoercion.date(values[index], timeZone: timeZone)
    }

    /// All argument values with arrays expanded recursively. Blanks are kept so callers can decide how
    /// to treat them (COUNTALL counts them, SUM skips them).
    func expandedValues() -> [FormulaValue] {
        FormulaArrays.expand(values)
    }
}

enum FormulaArrays {
    static func expand(_ values: [FormulaValue]) -> [FormulaValue] {
        var result: [FormulaValue] = []
        result.reserveCapacity(values.count)
        for value in values {
            append(value, to: &result)
        }
        return result
    }

    private static func append(_ value: FormulaValue, to result: inout [FormulaValue]) {
        if case .array(let items) = value {
            for item in items {
                append(item, to: &result)
            }
        } else {
            result.append(value)
        }
    }

    /// The elements of an array argument; a scalar counts as a one-element list and blank as empty.
    static func elements(_ value: FormulaValue) -> [FormulaValue] {
        switch value {
        case .array(let items): return items
        case .blank: return []
        case .number, .text, .bool, .date, .error: return [value]
        }
    }
}
