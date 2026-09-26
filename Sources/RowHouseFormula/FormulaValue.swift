import Foundation

public enum FormulaValue: Hashable, Sendable {
    case blank
    case number(Double)
    case text(String)
    case bool(Bool)
    case date(Date)
    case array([FormulaValue])
    case error(FormulaError)
}

public struct FormulaError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

extension FormulaValue {
    public var isBlank: Bool {
        switch self {
        case .blank:
            return true
        case .text(let string):
            return string.isEmpty
        case .array(let items):
            return items.allSatisfy(\.isBlank)
        case .number, .bool, .date, .error:
            return false
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .blank, .error:
            return false
        case .number(let number):
            return number != 0
        case .text(let string):
            return !string.isEmpty
        case .bool(let bool):
            return bool
        case .date:
            return true
        case .array(let items):
            return items.contains(where: \.isTruthy)
        }
    }

    public var asNumber: Double? {
        switch self {
        case .number(let number):
            return number
        case .bool(let bool):
            return bool ? 1 : 0
        case .text(let string):
            return FormulaNumberParsing.number(from: string)
        case .array:
            let items = flattened
            return items.count == 1 ? items[0].asNumber : nil
        case .blank, .date, .error:
            return nil
        }
    }

    /// Time-zone independent rendering: date-only values (midnight UTC) render as `YYYY-MM-DD`,
    /// everything else as an ISO 8601 UTC timestamp.
    public var asText: String {
        textValue(in: .gmt)
    }

    public func displayString(timeZone: TimeZone) -> String {
        switch self {
        case .blank:
            return ""
        case .number(let number):
            return FormulaNumberFormatting.string(from: number)
        case .text(let string):
            return string
        case .bool(let bool):
            return bool ? "TRUE" : "FALSE"
        case .date(let date):
            let local = LocalDateTime(date, in: timeZone)
            if local.isMidnight {
                return FormulaDateFormatting.dateString(local)
            }
            return FormulaDateFormatting.dateString(local) + " "
                + FormulaDateFormatting.pad(local.hour, 2) + ":" + FormulaDateFormatting.pad(local.minute, 2)
        case .array:
            return flattened.map { $0.displayString(timeZone: timeZone) }.joined(separator: ", ")
        case .error:
            return "#ERROR!"
        }
    }

    public var flattened: [FormulaValue] {
        switch self {
        case .blank:
            return []
        case .array(let items):
            var result: [FormulaValue] = []
            result.reserveCapacity(items.count)
            for item in items {
                result.append(contentsOf: item.flattened)
            }
            return result
        case .number, .text, .bool, .date, .error:
            return [self]
        }
    }
}

extension FormulaValue {
    /// Text coercion used by `&` and text functions. Dates at local midnight render as `YYYY-MM-DD`,
    /// other dates as `YYYY-MM-DDTHH:mm:ss.SSSZ` in UTC.
    func textValue(in timeZone: TimeZone) -> String {
        switch self {
        case .blank:
            return ""
        case .number(let number):
            return FormulaNumberFormatting.string(from: number)
        case .text(let string):
            return string
        case .bool(let bool):
            return bool ? "TRUE" : "FALSE"
        case .date(let date):
            let local = LocalDateTime(date, in: timeZone)
            if local.isMidnight {
                return FormulaDateFormatting.dateString(local)
            }
            return FormulaDateFormatting.isoUTCString(date)
        case .array:
            return flattened.map { $0.textValue(in: timeZone) }.joined(separator: ", ")
        case .error:
            return "#ERROR!"
        }
    }

    /// The first error found in this value, searching nested arrays.
    var firstError: FormulaError? {
        switch self {
        case .error(let error):
            return error
        case .array(let items):
            for item in items {
                if let error = item.firstError { return error }
            }
            return nil
        case .blank, .number, .text, .bool, .date:
            return nil
        }
    }

    static func checkedNumber(_ number: Double) -> FormulaValue {
        number.isFinite ? .number(number) : .error(FormulaError("Number is out of range"))
    }
}
