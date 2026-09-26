import Foundation

extension FormulaFunctionRegistry {
    static let logicalFunctions: [FormulaFunction] = [
        FormulaFunction(
            "IF(condition, valueIfTrue, [valueIfFalse])", .logical, .range(2, 3), evaluation: .lazy,
            summary: "Returns valueIfTrue when the condition is truthy, otherwise valueIfFalse (or blank)."
        ) { call in
            let condition = call.evaluate(0)
            if let error = condition.firstError {
                return .error(error)
            }
            if condition.isTruthy {
                return call.evaluate(1)
            }
            return call.has(2) ? call.evaluate(2) : .blank
        },

        FormulaFunction(
            "SWITCH(expression, pattern1, result1, …, [default])", .logical, .atLeast(3), evaluation: .lazy,
            summary: "Returns the result paired with the first pattern equal to the expression, else the default or blank."
        ) { call in
            let subject = call.evaluate(0)
            if let error = subject.firstError {
                return .error(error)
            }
            let remaining = call.count - 1
            for pair in 0..<(remaining / 2) {
                let pattern = call.evaluate(1 + pair * 2)
                if let error = pattern.firstError {
                    return .error(error)
                }
                if FormulaComparison.compare(subject, pattern, timeZone: call.timeZone) == .orderedSame {
                    return call.evaluate(2 + pair * 2)
                }
            }
            return remaining % 2 == 1 ? call.evaluate(call.count - 1) : .blank
        },

        FormulaFunction(
            "AND(logical1, [logical2, …])", .logical, .atLeast(1), evaluation: .lazy,
            summary: "Returns true if every argument is truthy; stops at the first falsy one."
        ) { call in
            FormulaFunctionRegistry.shortCircuit(call, stopOn: false)
        },

        FormulaFunction(
            "OR(logical1, [logical2, …])", .logical, .atLeast(1), evaluation: .lazy,
            summary: "Returns true if any argument is truthy; stops at the first truthy one."
        ) { call in
            FormulaFunctionRegistry.shortCircuit(call, stopOn: true)
        },

        FormulaFunction(
            "XOR(logical1, [logical2, …])", .logical, .atLeast(1),
            summary: "Returns true if an odd number of arguments are truthy."
        ) { call in
            let truthyCount = call.expandedValues().reduce(0) { $0 + ($1.isTruthy ? 1 : 0) }
            return .bool(truthyCount % 2 == 1)
        },

        FormulaFunction(
            "NOT(logical)", .logical, .exactly(1),
            summary: "Reverses the truthiness of its argument."
        ) { call in
            .bool(!call.value(0).isTruthy)
        },

        FormulaFunction("TRUE()", .logical, .exactly(0), summary: "Returns the logical value true.") { _ in
            .bool(true)
        },

        FormulaFunction("FALSE()", .logical, .exactly(0), summary: "Returns the logical value false.") { _ in
            .bool(false)
        },

        FormulaFunction("BLANK()", .logical, .exactly(0), summary: "Returns a blank value.") { _ in
            .blank
        },

        FormulaFunction(
            "ERROR([message])", .logical, .range(0, 1),
            summary: "Returns an error value, optionally with a message."
        ) { call in
            let message = call.hasValue(0) ? call.text(0) : "Error"
            return .error(FormulaError(message))
        },

        FormulaFunction(
            "ISERROR(expression)", .logical, .exactly(1), evaluation: .eagerPassingErrors,
            summary: "Returns true if the expression produces an error."
        ) { call in
            .bool(call.value(0).firstError != nil)
        },
    ]

    /// AND stops on the first falsy value, OR on the first truthy one. Arrays are expanded and blanks
    /// count as falsy; with no values at all both return false.
    private static func shortCircuit(_ call: FormulaCall, stopOn stopValue: Bool) -> FormulaValue {
        var sawValue = false
        for index in 0..<call.count {
            let value = call.evaluate(index)
            if let error = value.firstError {
                return .error(error)
            }
            for item in FormulaArrays.expand([value]) {
                sawValue = true
                if item.isTruthy == stopValue {
                    return .bool(stopValue)
                }
            }
        }
        return .bool(stopValue ? false : sawValue)
    }
}
