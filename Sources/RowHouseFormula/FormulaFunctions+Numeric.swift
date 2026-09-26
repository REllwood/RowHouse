import Foundation

extension FormulaFunctionRegistry {
    static let numericFunctions: [FormulaFunction] = [
        FormulaFunction("ABS(number)", .numeric, .exactly(1), summary: "Returns the absolute value of a number.") { call in
            try .number(abs(call.number(0)))
        },

        FormulaFunction(
            "SUM(number1, [number2, …])", .numeric, .atLeast(1),
            summary: "Adds the numbers; arrays are expanded and non-numeric values ignored."
        ) { call in
            .number(FormulaNumericAggregates.numbers(in: call).reduce(0, +))
        },

        FormulaFunction(
            "AVERAGE(number1, [number2, …])", .numeric, .atLeast(1),
            summary: "Returns the mean of the numbers, or blank if there are none."
        ) { call in
            let numbers = FormulaNumericAggregates.numbers(in: call)
            guard !numbers.isEmpty else { return .blank }
            return .number(numbers.reduce(0, +) / Double(numbers.count))
        },

        FormulaFunction(
            "MAX(number1, [number2, …])", .numeric, .atLeast(1),
            summary: "Returns the largest number (or latest date when only dates are given)."
        ) { call in
            FormulaNumericAggregates.extreme(in: call, largest: true)
        },

        FormulaFunction(
            "MIN(number1, [number2, …])", .numeric, .atLeast(1),
            summary: "Returns the smallest number (or earliest date when only dates are given)."
        ) { call in
            FormulaNumericAggregates.extreme(in: call, largest: false)
        },

        FormulaFunction(
            "COUNT(value1, [value2, …])", .numeric, .atLeast(1),
            summary: "Counts the numeric values."
        ) { call in
            let count = call.expandedValues().reduce(0) { total, value in
                if case .number = value { return total + 1 }
                return total
            }
            return .number(Double(count))
        },

        FormulaFunction(
            "COUNTA(value1, [value2, …])", .numeric, .atLeast(1),
            summary: "Counts the non-blank values."
        ) { call in
            .number(Double(call.expandedValues().reduce(0) { $0 + ($1.isBlank ? 0 : 1) }))
        },

        FormulaFunction(
            "COUNTALL(value1, [value2, …])", .numeric, .atLeast(1),
            summary: "Counts all values, including blanks."
        ) { call in
            .number(Double(call.expandedValues().count))
        },

        FormulaFunction(
            "CEILING(value, [significance])", .numeric, .range(1, 2),
            summary: "Rounds up to the nearest multiple of significance (default 1)."
        ) { call in
            let value = try call.number(0)
            let significance = try call.number(1, default: 1)
            return .number(FormulaNumericAggregates.roundToMultiple(value, of: significance, rule: .up))
        },

        FormulaFunction(
            "FLOOR(value, [significance])", .numeric, .range(1, 2),
            summary: "Rounds down to the nearest multiple of significance (default 1)."
        ) { call in
            let value = try call.number(0)
            let significance = try call.number(1, default: 1)
            return .number(FormulaNumericAggregates.roundToMultiple(value, of: significance, rule: .down))
        },

        FormulaFunction(
            "EVEN(value)", .numeric, .exactly(1),
            summary: "Rounds away from zero to the nearest even integer."
        ) { call in
            let value = try call.number(0)
            let magnitude = (FormulaMath.snapped(value.magnitude) / 2).rounded(.up) * 2
            return .number(value < 0 ? -magnitude : magnitude)
        },

        FormulaFunction(
            "ODD(value)", .numeric, .exactly(1),
            summary: "Rounds away from zero to the nearest odd integer."
        ) { call in
            let value = try call.number(0)
            let magnitude = ((FormulaMath.snapped(value.magnitude) + 1) / 2).rounded(.up) * 2 - 1
            return .number(value < 0 ? -magnitude : magnitude)
        },

        FormulaFunction("EXP(power)", .numeric, .exactly(1), summary: "Returns e raised to the power.") { call in
            try .number(exp(call.number(0)))
        },

        FormulaFunction("INT(value)", .numeric, .exactly(1), summary: "Rounds down to the nearest integer.") { call in
            try .number(call.number(0).rounded(.down))
        },

        FormulaFunction(
            "LOG(number, [base])", .numeric, .range(1, 2),
            summary: "Returns the logarithm of the number in the given base (default 10)."
        ) { call in
            let number = try call.number(0)
            let base = try call.number(1, default: 10)
            guard number > 0 else { throw FormulaError("LOG requires a positive number") }
            guard base > 0, base != 1 else { throw FormulaError("LOG base must be positive and not equal to 1") }
            switch base {
            case 10: return .number(log10(number))
            case 2: return .number(log2(number))
            default: return .number(FormulaMath.snapped(log(number) / log(base)))
            }
        },

        FormulaFunction(
            "MOD(value, divisor)", .numeric, .exactly(2),
            summary: "Returns the remainder of value divided by divisor (with the sign of value)."
        ) { call in
            let value = try call.number(0)
            let divisor = try call.number(1)
            guard divisor != 0 else { throw FormulaError("Division by zero") }
            let remainder = value.truncatingRemainder(dividingBy: divisor)
            return .number(remainder == 0 ? 0 : remainder)
        },

        FormulaFunction(
            "POWER(base, exponent)", .numeric, .exactly(2),
            summary: "Returns base raised to the exponent."
        ) { call in
            let result = try pow(call.number(0), call.number(1))
            guard !result.isNaN else { throw FormulaError("POWER result is not a real number") }
            return .number(result)
        },

        FormulaFunction(
            "ROUND(value, [precision])", .numeric, .range(1, 2),
            summary: "Rounds to precision decimal places (default 0), halves away from zero; negative precision rounds left of the point."
        ) { call in
            try .number(FormulaMath.round(call.number(0), digits: call.integer(1, default: 0), rule: .toNearestOrAwayFromZero))
        },

        FormulaFunction(
            "ROUNDUP(value, [precision])", .numeric, .range(1, 2),
            summary: "Rounds away from zero to precision decimal places (default 0)."
        ) { call in
            try .number(FormulaMath.round(call.number(0), digits: call.integer(1, default: 0), rule: .awayFromZero))
        },

        FormulaFunction(
            "ROUNDDOWN(value, [precision])", .numeric, .range(1, 2),
            summary: "Rounds toward zero to precision decimal places (default 0)."
        ) { call in
            try .number(FormulaMath.round(call.number(0), digits: call.integer(1, default: 0), rule: .towardZero))
        },

        FormulaFunction("SQRT(number)", .numeric, .exactly(1), summary: "Returns the square root of a number.") { call in
            let number = try call.number(0)
            guard number >= 0 else { throw FormulaError("SQRT requires a number that is not negative") }
            return .number(number.squareRoot())
        },

        FormulaFunction(
            "VALUE(text)", .numeric, .exactly(1),
            summary: "Converts text to a number, ignoring currency symbols, thousands separators and whitespace; \"12%\" is 0.12."
        ) { call in
            switch FormulaCoercion.singleValue(call.value(0)) {
            case .number(let number):
                return .number(number)
            case .bool(let bool):
                return .number(bool ? 1 : 0)
            case .date:
                throw FormulaError("VALUE cannot convert a date to a number")
            default:
                let text = call.text(0)
                if text.allSatisfy(\.isWhitespace) {
                    return .blank
                }
                guard let number = FormulaNumericAggregates.lenientNumber(from: text) else {
                    throw FormulaError("Cannot convert \(FormulaCoercion.quoted(text)) to a number")
                }
                return .number(number)
            }
        },
    ]
}

enum FormulaNumericAggregates {
    /// Numbers, booleans (1/0) and numeric text from the expanded arguments; everything else is skipped.
    static func numbers(in call: FormulaCall) -> [Double] {
        call.expandedValues().compactMap { value in
            switch value {
            case .number(let number): return number
            case .bool(let bool): return bool ? 1 : 0
            case .text(let text): return FormulaNumberParsing.number(from: text)
            case .blank, .date, .array, .error: return nil
            }
        }
    }

    static func extreme(in call: FormulaCall, largest: Bool) -> FormulaValue {
        var bestNumber: Double?
        var bestDate: Date?
        for value in call.expandedValues() {
            let candidate: Double?
            switch value {
            case .number(let number): candidate = number
            case .bool(let bool): candidate = bool ? 1 : 0
            case .text(let text): candidate = FormulaNumberParsing.number(from: text)
            case .date(let date):
                if let current = bestDate {
                    bestDate = largest ? max(current, date) : min(current, date)
                } else {
                    bestDate = date
                }
                candidate = nil
            case .blank, .array, .error: candidate = nil
            }
            if let candidate {
                if let current = bestNumber {
                    bestNumber = largest ? max(current, candidate) : min(current, candidate)
                } else {
                    bestNumber = candidate
                }
            }
        }
        if let bestNumber { return .number(bestNumber) }
        if let bestDate { return .date(bestDate) }
        return .blank
    }

    static func roundToMultiple(_ value: Double, of significance: Double, rule: FloatingPointRoundingRule) -> Double {
        guard significance != 0 else { return 0 }
        let step = significance.magnitude
        let multiples = FormulaMath.snapped(value / step).rounded(rule)
        return FormulaMath.snapped(multiples * step)
    }

    /// VALUE's parser: strips whitespace, thousands separators and currency symbols, accepts a trailing
    /// percent sign and accounting-style negatives such as "(1,000)".
    static func lenientNumber(from text: String) -> Double? {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var negate = false
        if body.hasPrefix("("), body.hasSuffix(")"), body.count >= 2 {
            negate = true
            body = body.dropFirst().dropLast()
        }
        var cleaned = String.UnicodeScalarView()
        for scalar in body.unicodeScalars {
            if scalar == "," || scalar.properties.isWhitespace || scalar.properties.generalCategory == .currencySymbol {
                continue
            }
            cleaned.append(scalar)
        }
        var numeric = String(cleaned)
        var percent = false
        if numeric.hasSuffix("%") {
            percent = true
            numeric.removeLast()
        }
        guard var number = FormulaNumberParsing.number(from: numeric) else { return nil }
        if percent { number /= 100 }
        return negate ? -number : number
    }
}
