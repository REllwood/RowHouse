import Foundation

enum FormulaOperators {
    static func applyUnary(_ op: String, _ operand: FormulaValue) -> FormulaValue {
        if let error = operand.firstError {
            return .error(error)
        }
        do throws(FormulaError) {
            let number = try arithmeticOperand(operand)
            switch op {
            case "-": return .checkedNumber(-number)
            case "+": return .checkedNumber(number)
            default: return .error(FormulaError("Unknown operator \(op)"))
            }
        } catch {
            return .error(error)
        }
    }

    static func applyBinary(_ op: String, _ lhs: FormulaValue, _ rhs: FormulaValue, timeZone: TimeZone) -> FormulaValue {
        if let error = lhs.firstError {
            return .error(error)
        }
        if let error = rhs.firstError {
            return .error(error)
        }
        switch op {
        case "&":
            return .text(lhs.textValue(in: timeZone) + rhs.textValue(in: timeZone))
        case "+", "-", "*", "/":
            do throws(FormulaError) {
                let a = try arithmeticOperand(lhs)
                let b = try arithmeticOperand(rhs)
                switch op {
                case "+": return .checkedNumber(a + b)
                case "-": return .checkedNumber(a - b)
                case "*": return .checkedNumber(a * b)
                default:
                    guard b != 0 else { return .error(FormulaError("Division by zero")) }
                    return .checkedNumber(a / b)
                }
            } catch {
                return .error(error)
            }
        case "=":
            return .bool(FormulaComparison.compare(lhs, rhs, timeZone: timeZone) == .orderedSame)
        case "!=", "<>":
            return .bool(FormulaComparison.compare(lhs, rhs, timeZone: timeZone) != .orderedSame)
        case "<":
            return .bool(FormulaComparison.compare(lhs, rhs, timeZone: timeZone) == .orderedAscending)
        case ">":
            return .bool(FormulaComparison.compare(lhs, rhs, timeZone: timeZone) == .orderedDescending)
        case "<=":
            let order = FormulaComparison.compare(lhs, rhs, timeZone: timeZone)
            return .bool(order == .orderedAscending || order == .orderedSame)
        case ">=":
            let order = FormulaComparison.compare(lhs, rhs, timeZone: timeZone)
            return .bool(order == .orderedDescending || order == .orderedSame)
        default:
            return .error(FormulaError("Unknown operator \(op)"))
        }
    }

    private static func arithmeticOperand(_ value: FormulaValue) throws(FormulaError) -> Double {
        if case .date = FormulaCoercion.singleValue(value) {
            throw FormulaError("Dates can't be used in arithmetic; use DATEADD or DATETIME_DIFF")
        }
        return try FormulaCoercion.number(value)
    }
}

enum FormulaCoercion {
    /// Unwraps single-element arrays (e.g. a lookup of one record); anything else is returned unchanged.
    static func singleValue(_ value: FormulaValue) -> FormulaValue {
        guard case .array = value else { return value }
        let items = value.flattened
        switch items.count {
        case 0: return .blank
        case 1: return items[0]
        default: return value
        }
    }

    static func number(_ value: FormulaValue) throws(FormulaError) -> Double {
        switch value {
        case .blank:
            return 0
        case .number(let number):
            return number
        case .bool(let bool):
            return bool ? 1 : 0
        case .text(let text):
            if let number = FormulaNumberParsing.number(from: text) {
                return number
            }
            if text.allSatisfy(\.isWhitespace) {
                return 0
            }
            throw FormulaError("Cannot convert \(quoted(text)) to a number")
        case .date:
            throw FormulaError("Expected a number but got a date")
        case .array:
            let items = value.flattened
            switch items.count {
            case 0: return 0
            case 1: return try number(items[0])
            default: throw FormulaError("Expected a single value but got a list of \(items.count) values")
            }
        case .error(let error):
            throw error
        }
    }

    /// Returns nil for blank input; date functions then return blank.
    static func date(_ value: FormulaValue, timeZone: TimeZone) throws(FormulaError) -> Date? {
        switch value {
        case .blank:
            return nil
        case .date(let date):
            return date
        case .text(let text):
            if text.allSatisfy(\.isWhitespace) {
                return nil
            }
            if let date = FormulaDateParsing.parseDefault(text, timeZone: timeZone) {
                return date
            }
            throw FormulaError("Cannot interpret \(quoted(text)) as a date")
        case .array:
            let items = value.flattened
            switch items.count {
            case 0: return nil
            case 1: return try date(items[0], timeZone: timeZone)
            default: throw FormulaError("Expected a single date but got a list of \(items.count) values")
            }
        case .number, .bool:
            throw FormulaError("Expected a date but got a number")
        case .error(let error):
            throw error
        }
    }

    static func quoted(_ text: String) -> String {
        let limit = 40
        if text.count > limit {
            return "\"\(text.prefix(limit))…\""
        }
        return "\"\(text)\""
    }
}

enum FormulaComparison {
    private enum Operand {
        case blank
        case number(Double)
        case text(String)
        case bool(Bool)
        case date(Int64)
    }

    /// Orders two values, or returns nil when they are not comparable (e.g. a date and a number): then
    /// `=` is false, `!=` is true and every ordering comparison is false. Blank equals "", 0 and FALSE.
    static func compare(_ lhs: FormulaValue, _ rhs: FormulaValue, timeZone: TimeZone) -> ComparisonResult? {
        compare(operand(lhs, timeZone: timeZone), operand(rhs, timeZone: timeZone), timeZone: timeZone)
    }

    private static func operand(_ value: FormulaValue, timeZone: TimeZone) -> Operand {
        switch value {
        case .blank, .error:
            return .blank
        case .number(let number):
            return .number(number)
        case .text(let text):
            return text.isEmpty ? .blank : .text(text)
        case .bool(let bool):
            return .bool(bool)
        case .date(let date):
            return .date(DateMath.epochMilliseconds(date))
        case .array:
            let items = value.flattened
            switch items.count {
            case 0: return .blank
            case 1: return operand(items[0], timeZone: timeZone)
            default: return .text(value.textValue(in: timeZone))
            }
        }
    }

    private static func compare(_ lhs: Operand, _ rhs: Operand, timeZone: TimeZone) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (.blank, .blank):
            return .orderedSame
        case (.blank, _):
            guard let equivalent = blankEquivalent(for: rhs) else { return nil }
            return compare(equivalent, rhs, timeZone: timeZone)
        case (_, .blank):
            guard let equivalent = blankEquivalent(for: lhs) else { return nil }
            return compare(lhs, equivalent, timeZone: timeZone)

        case let (.number(a), .number(b)):
            return order(a, b)
        case let (.number(a), .text(b)):
            if let number = FormulaNumberParsing.number(from: b) { return order(a, number) }
            return order(FormulaNumberFormatting.string(from: a), b)
        case let (.text(a), .number(b)):
            if let number = FormulaNumberParsing.number(from: a) { return order(number, b) }
            return order(a, FormulaNumberFormatting.string(from: b))
        case let (.number(a), .bool(b)):
            return order(a, b ? 1 : 0)
        case let (.bool(a), .number(b)):
            return order(a ? 1 : 0, b)

        case let (.text(a), .text(b)):
            return order(a, b)
        case let (.text(a), .bool(b)):
            if let number = FormulaNumberParsing.number(from: a) { return order(number, b ? 1 : 0) }
            return order(a, b ? "TRUE" : "FALSE")
        case let (.bool(a), .text(b)):
            if let number = FormulaNumberParsing.number(from: b) { return order(a ? 1 : 0, number) }
            return order(a ? "TRUE" : "FALSE", b)
        case let (.bool(a), .bool(b)):
            return order(a ? 1 : 0, b ? 1 : 0)

        case let (.date(a), .date(b)):
            return order(a, b)
        case let (.date(a), .text(b)):
            if let date = FormulaDateParsing.parseDefault(b, timeZone: timeZone) {
                return order(a, DateMath.epochMilliseconds(date))
            }
            return order(FormulaValue.date(DateMath.date(epochMilliseconds: a)).textValue(in: timeZone), b)
        case let (.text(a), .date(b)):
            if let date = FormulaDateParsing.parseDefault(a, timeZone: timeZone) {
                return order(DateMath.epochMilliseconds(date), b)
            }
            return order(a, FormulaValue.date(DateMath.date(epochMilliseconds: b)).textValue(in: timeZone))

        case (.date, .number), (.number, .date), (.date, .bool), (.bool, .date):
            return nil
        }
    }

    private static func blankEquivalent(for operand: Operand) -> Operand? {
        switch operand {
        case .blank: return .blank
        case .number: return .number(0)
        case .text: return .text("")
        case .bool: return .bool(false)
        case .date: return nil
        }
    }

    private static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a == b ? .orderedSame : .orderedDescending)
    }
}
