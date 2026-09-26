import Foundation

enum FormulaNumberFormatting {
    /// Renders a number the way a cell shows it, laid out like JavaScript's `Number#toString`
    /// ("3", "3.5", "1e-7", "1e+21"). Fractions are limited to 15 significant digits so binary floating
    /// point noise is hidden (0.1 + 0.2 renders as "0.3"); integers keep every digit.
    static func string(from value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }

        let magnitude = value.magnitude
        let isIntegral = magnitude.rounded(.towardZero) == magnitude
        if isIntegral, magnitude < 9_007_199_254_740_992 {
            return String(Int64(value))
        }

        var decimal = significantDigits(of: magnitude.description)
        if !isIntegral, decimal.digits.count > 15 {
            decimal = significantDigits(of: String(format: "%.14e", magnitude))
        }
        let body = layout(digits: decimal.digits, exponent: decimal.exponent)
        return value < 0 ? "-" + body : body
    }

    /// Splits a decimal rendering such as "1.25e-07" or "123.5" into significant digits and the base-10
    /// exponent of the first digit.
    private static func significantDigits(of text: String) -> (digits: String, exponent: Int) {
        let parts = text.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var integerDigits = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
            ?? mantissa.count
        var digits = mantissa.filter { $0 != "." }
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            integerDigits -= 1
        }
        while digits.count > 1, digits.last == "0" {
            digits.removeLast()
        }
        return (digits, exponent + integerDigits - 1)
    }

    private static func layout(digits: String, exponent: Int) -> String {
        let pointPosition = exponent + 1
        if digits.count <= pointPosition, pointPosition <= 21 {
            return digits + String(repeating: "0", count: pointPosition - digits.count)
        }
        if pointPosition > 0, pointPosition <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: pointPosition)
            return digits[..<split] + "." + digits[split...]
        }
        if pointPosition > -6, pointPosition <= 0 {
            return "0." + String(repeating: "0", count: -pointPosition) + digits
        }
        let tail = digits.dropFirst()
        return String(digits.prefix(1)) + (tail.isEmpty ? "" : "." + tail)
            + "e" + (exponent < 0 ? "-" : "+") + String(exponent.magnitude)
    }
}

enum FormulaNumberParsing {
    /// Strict numeric text: optional surrounding whitespace, optional sign, digits with an optional
    /// fraction and exponent. Rejects "inf", "nan", hex and anything with thousands separators.
    static func number(from text: String) -> Double? {
        let bytes = text.utf8
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start < end, isASCIIWhitespace(bytes[start]) {
            start = bytes.index(after: start)
        }
        while end > start, isASCIIWhitespace(bytes[bytes.index(before: end)]) {
            end = bytes.index(before: end)
        }
        guard start < end, isNumericLiteral(bytes[start..<end]) else { return nil }
        guard let value = Double(text[start..<end]), value.isFinite else { return nil }
        return value
    }

    static func isNumericLiteral(_ bytes: Substring.UTF8View) -> Bool {
        var index = bytes.startIndex
        let end = bytes.endIndex

        func consumeDigits() -> Int {
            var count = 0
            while index < end, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index = bytes.index(after: index)
                count += 1
            }
            return count
        }

        if index < end, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index = bytes.index(after: index)
        }
        var mantissaDigits = consumeDigits()
        if index < end, bytes[index] == UInt8(ascii: ".") {
            index = bytes.index(after: index)
            mantissaDigits += consumeDigits()
        }
        guard mantissaDigits > 0 else { return false }
        if index < end, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index = bytes.index(after: index)
            if index < end, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index = bytes.index(after: index)
            }
            guard consumeDigits() > 0 else { return false }
        }
        return index == end
    }

    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }
}

enum FormulaMath {
    /// Removes binary floating point noise by rounding to 15 significant digits, so that e.g.
    /// 1.005 * 100 is treated as 100.5 and 2.3 * 10 as 23 before rounding.
    static func snapped(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return value }
        return Double(String(format: "%.15g", value)) ?? value
    }

    static func round(_ value: Double, digits: Int, rule: FloatingPointRoundingRule) -> Double {
        let digits = min(max(digits, -308), 308)
        let factor = pow(10.0, Double(digits.magnitude))
        guard factor.isFinite else { return value }
        let scaled = digits >= 0 ? value * factor : value / factor
        guard scaled.isFinite else { return value }
        let rounded = snapped(scaled).rounded(rule)
        return digits >= 0 ? rounded / factor : rounded * factor
    }

    /// Converts to an integer, truncating toward zero and clamping to ±2^53 so that absurd inputs
    /// never trap.
    static func clampedInteger(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        let limit = 9_007_199_254_740_992.0
        return Int(min(max(value.rounded(.towardZero), -limit), limit))
    }

    static func floorDivide(_ lhs: Int, _ rhs: Int) -> Int {
        let quotient = lhs / rhs
        return (lhs % rhs != 0 && (lhs < 0) != (rhs < 0)) ? quotient - 1 : quotient
    }

    static func floorModulo(_ lhs: Int, _ rhs: Int) -> Int {
        let remainder = lhs % rhs
        return remainder != 0 && (remainder < 0) != (rhs < 0) ? remainder + rhs : remainder
    }

    static func floorDivide(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let quotient = lhs / rhs
        return (lhs % rhs != 0 && (lhs < 0) != (rhs < 0)) ? quotient - 1 : quotient
    }
}
