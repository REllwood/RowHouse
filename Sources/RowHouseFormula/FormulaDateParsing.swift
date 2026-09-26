import Foundation

enum FormulaDateParsing {
    /// Parses the formats accepted without an explicit format string:
    /// ISO 8601 (`2024-01-05`, `2024-01-05T10:30`, `…:45.123Z`, `…+05:30`), `YYYY/MM/DD`, `M/D/YYYY`,
    /// `MMMM D, YYYY` (optionally preceded by a weekday) and `D MMMM YYYY`, each optionally followed by a
    /// time (`H:mm[:ss[.SSS]] [AM|PM]`) and a UTC offset. Times without an offset are wall-clock times in
    /// `timeZone`.
    static func parseDefault(_ text: String, timeZone: TimeZone) -> Date? {
        var scanner = DateScanner(text)
        guard let first = scanner.peek(), DateScanner.isDigit(first) || DateScanner.isLetter(first) else {
            return nil
        }
        var fields = DateFields()
        guard let dateStyle = scanDate(&scanner, into: &fields) else { return nil }

        if !scanner.isAtEnd {
            let hasSeparator: Bool
            if dateStyle == .iso, scanner.consume(UInt8(ascii: "T")) || scanner.consume(UInt8(ascii: "t")) {
                hasSeparator = true
            } else {
                let hadComma = scanner.consume(UInt8(ascii: ","))
                hasSeparator = scanner.skipWhitespace() || hadComma
            }
            guard hasSeparator, scanTime(&scanner, into: &fields) else { return nil }
            scanner.skipWhitespace()
            if !scanner.isAtEnd {
                guard let offset = scanner.utcOffset() else { return nil }
                fields.offsetSeconds = offset
                scanner.skipWhitespace()
            }
            guard scanner.isAtEnd else { return nil }
        }

        guard let epoch = fields.resolve(timeZone: timeZone, now: Date(timeIntervalSince1970: 0)) else { return nil }
        return DateMath.date(epochMilliseconds: epoch)
    }

    /// Parses with a moment.js format string (the same tokens as DATETIME_FORMAT). Parsing is lenient
    /// like moment's non-strict mode: numbers may have fewer digits than the token, any punctuation
    /// matches any punctuation, and trailing tokens may be missing.
    static func parse(_ text: String, format: String, timeZone: TimeZone, now: Date) throws(FormulaError) -> Date {
        let failure = FormulaError(
            "Cannot parse \(FormulaCoercion.quoted(text)) with format \(FormulaCoercion.quoted(format))"
        )
        var scanner = DateScanner(text)
        var fields = DateFields()

        tokenLoop: for token in FormulaDateFormatting.tokens(for: format) {
            if scanner.isAtEnd { break }
            switch token {
            case .literal(let literal):
                for byte in literal.utf8 {
                    if FormulaNumberParsing.isASCIIWhitespace(byte) {
                        scanner.skipWhitespace()
                        continue
                    }
                    if scanner.isAtEnd { break tokenLoop }
                    guard scanner.consumeLiteral(byte) else { throw failure }
                }
            case .field(let field):
                guard try scanField(field, &scanner, into: &fields) else { throw failure }
            }
        }
        scanner.skipWhitespace()
        guard scanner.isAtEnd, let epoch = fields.resolve(timeZone: timeZone, now: now) else { throw failure }
        return DateMath.date(epochMilliseconds: epoch)
    }

    private enum DateStyle {
        case iso, other
    }

    private static func scanDate(_ scanner: inout DateScanner, into fields: inout DateFields) -> DateStyle? {
        let start = scanner.index
        // YYYY-MM-DD or YYYY/MM/DD
        if let year = scanner.digits(min: 4, max: 4),
           let separator = scanner.peek(), separator == UInt8(ascii: "-") || separator == UInt8(ascii: "/") {
            scanner.index += 1
            guard let month = scanner.digits(min: 1, max: 2),
                  scanner.consume(separator),
                  let day = scanner.digits(min: 1, max: 2)
            else { return nil }
            fields.year = year
            fields.month = month
            fields.day = day
            return separator == UInt8(ascii: "-") ? .iso : .other
        }
        scanner.index = start

        // Optional leading weekday: "Thursday, September 4, 1986".
        let beforeWeekday = scanner.index
        if scanner.weekdayName(allowMinimal: false) != nil {
            let hadComma = scanner.consume(UInt8(ascii: ","))
            if !(scanner.skipWhitespace() || hadComma) {
                scanner.index = beforeWeekday
            }
        }

        if let month = scanner.monthName() {
            // MMMM D, YYYY
            scanner.skipWhitespace()
            guard let day = scanner.digits(min: 1, max: 2) else { return nil }
            _ = scanner.ordinalSuffix()
            let hadComma = scanner.consume(UInt8(ascii: ","))
            guard scanner.skipWhitespace() || hadComma, let year = scanner.digits(min: 4, max: 4) else { return nil }
            fields.year = year
            fields.month = month
            fields.day = day
            return .other
        }

        guard let leading = scanner.digits(min: 1, max: 2) else { return nil }
        if scanner.consume(UInt8(ascii: "/")) {
            // M/D/YYYY
            guard let day = scanner.digits(min: 1, max: 2),
                  scanner.consume(UInt8(ascii: "/")),
                  let year = scanner.digits(min: 4, max: 4)
            else { return nil }
            fields.year = year
            fields.month = leading
            fields.day = day
            return .other
        }

        // D MMMM YYYY
        _ = scanner.ordinalSuffix()
        guard scanner.skipWhitespace(), let month = scanner.monthName() else { return nil }
        let hadComma = scanner.consume(UInt8(ascii: ","))
        guard scanner.skipWhitespace() || hadComma, let year = scanner.digits(min: 4, max: 4) else { return nil }
        fields.year = year
        fields.month = month
        fields.day = leading
        return .other
    }

    private static func scanTime(_ scanner: inout DateScanner, into fields: inout DateFields) -> Bool {
        guard let hour = scanner.digits(min: 1, max: 2),
              scanner.consume(UInt8(ascii: ":")),
              let minute = scanner.digits(min: 2, max: 2)
        else { return false }
        fields.hour = hour
        fields.minute = minute
        if scanner.consume(UInt8(ascii: ":")) {
            guard let second = scanner.digits(min: 2, max: 2) else { return false }
            fields.second = second
            if scanner.consume(UInt8(ascii: ".")) || scanner.consume(UInt8(ascii: ",")) {
                guard let fraction = scanner.digitBytes(min: 1, max: 9) else { return false }
                fields.millisecond = DateScanner.milliseconds(fromFraction: fraction)
            }
        }
        let beforeMeridiem = scanner.index
        scanner.skipWhitespace()
        if let isPM = scanner.meridiem() {
            fields.isPM = isPM
        } else {
            scanner.index = beforeMeridiem
        }
        return true
    }

    private static func scanField(
        _ field: MomentField, _ scanner: inout DateScanner, into fields: inout DateFields
    ) throws(FormulaError) -> Bool {
        switch field {
        case .year:
            fields.year = scanner.digits(min: 1, max: 4)
            return fields.year != nil
        case .yearTwoDigit:
            guard let value = scanner.digits(min: 1, max: 2) else { return false }
            fields.year = value + (value > 68 ? 1900 : 2000)
            return true
        case .quarter, .quarterOrdinal:
            guard let value = scanner.digits(min: 1, max: 1) else { return false }
            if field == .quarterOrdinal { _ = scanner.ordinalSuffix() }
            fields.quarter = value
            return (1...4).contains(value)
        case .month, .monthPadded, .monthOrdinal:
            fields.month = scanner.digits(min: 1, max: 2)
            if field == .monthOrdinal { _ = scanner.ordinalSuffix() }
            return fields.month != nil
        case .monthShortName, .monthLongName:
            fields.month = scanner.monthName()
            return fields.month != nil
        case .dayOfMonth, .dayOfMonthPadded, .dayOfMonthOrdinal:
            fields.day = scanner.digits(min: 1, max: 2)
            if field == .dayOfMonthOrdinal { _ = scanner.ordinalSuffix() }
            return fields.day != nil
        case .dayOfYear, .dayOfYearPadded, .dayOfYearOrdinal:
            fields.dayOfYear = scanner.digits(min: 1, max: 3)
            if field == .dayOfYearOrdinal { _ = scanner.ordinalSuffix() }
            return fields.dayOfYear != nil
        case .weekday, .localeWeekday, .isoWeekday, .weekdayOrdinal:
            guard scanner.digits(min: 1, max: 1) != nil else { return false }
            if field == .weekdayOrdinal { _ = scanner.ordinalSuffix() }
            return true
        case .weekdayMinName, .weekdayShortName, .weekdayLongName:
            return scanner.weekdayName(allowMinimal: true) != nil
        case .hour, .hourPadded, .hour12, .hour12Padded, .hourFrom1, .hourFrom1Padded:
            fields.hour = scanner.digits(min: 1, max: 2)
            return fields.hour != nil
        case .minute, .minutePadded:
            fields.minute = scanner.digits(min: 1, max: 2)
            return fields.minute != nil
        case .second, .secondPadded:
            fields.second = scanner.digits(min: 1, max: 2)
            return fields.second != nil
        case .fraction(let digits):
            guard let fraction = scanner.digitBytes(min: 1, max: digits <= 3 ? digits : 9) else { return false }
            fields.millisecond = DateScanner.milliseconds(fromFraction: fraction)
            return true
        case .meridiemUpper, .meridiemLower:
            fields.isPM = scanner.meridiem()
            return fields.isPM != nil
        case .offsetWithColon, .offsetWithoutColon:
            fields.offsetSeconds = scanner.utcOffset()
            return fields.offsetSeconds != nil
        case .unixSeconds, .unixMilliseconds:
            let negative = scanner.consume(UInt8(ascii: "-"))
            guard let whole = scanner.digits(min: 1, max: field == .unixSeconds ? 13 : 16) else { return false }
            var milliseconds = Int64(whole)
            if field == .unixSeconds {
                milliseconds *= 1000
                if scanner.consume(UInt8(ascii: ".")) {
                    guard let fraction = scanner.digitBytes(min: 1, max: 9) else { return false }
                    milliseconds += Int64(DateScanner.milliseconds(fromFraction: fraction))
                }
            }
            fields.epochMilliseconds = negative ? -milliseconds : milliseconds
            return true
        case .week, .weekPadded, .weekOrdinal, .isoWeek, .isoWeekPadded, .isoWeekOrdinal,
             .weekYear, .weekYearTwoDigit, .isoWeekYear, .isoWeekYearTwoDigit:
            throw FormulaError("DATETIME_PARSE does not support week-based format tokens")
        }
    }
}

/// Date and time fields collected while parsing; missing fields are defaulted like moment.js.
private struct DateFields {
    var year: Int?
    var month: Int?
    var day: Int?
    var dayOfYear: Int?
    var quarter: Int?
    var hour: Int?
    var minute: Int?
    var second: Int?
    var millisecond: Int?
    var isPM: Bool?
    var offsetSeconds: Int?
    var epochMilliseconds: Int64?

    /// Returns epoch milliseconds, or nil if a field is out of range.
    func resolve(timeZone: TimeZone, now: Date) -> Int64? {
        if let epochMilliseconds {
            return DateMath.supportedEpochMilliseconds.contains(epochMilliseconds) ? epochMilliseconds : nil
        }

        let today = LocalDateTime(now, in: timeZone)
        var parts: [Int?] = [year, month ?? quarter.map { ($0 - 1) * 3 + 1 }, day]
        if let dayOfYear {
            let year = year ?? today.year
            guard dayOfYear >= 1, dayOfYear <= DateMath.daysInYear(year) else { return nil }
            let civil = DateMath.civil(dayNumber: DateMath.dayNumber(year: year, month: 1, day: 1) + dayOfYear - 1)
            parts = [civil.year, civil.month, civil.day]
        }
        // Leading missing parts come from today; later ones start at 1 (moment's rule, so "HH:mm" is today
        // and "YYYY" is January 1st).
        let current = [today.year, today.month, today.day]
        var index = 0
        while index < 3, parts[index] == nil {
            parts[index] = current[index]
            index += 1
        }
        let year = parts[0] ?? today.year
        let month = parts[1] ?? 1
        let day = parts[2] ?? 1
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...DateMath.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }

        var hour = hour ?? 0
        let minute = minute ?? 0
        let second = second ?? 0
        let millisecond = millisecond ?? 0
        if let isPM {
            if isPM && hour < 12 {
                hour += 12
            } else if !isPM && hour == 12 {
                hour = 0
            }
        }
        var extraDays = 0
        if hour == 24, minute == 0, second == 0, millisecond == 0 {
            hour = 0
            extraDays = 1
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }

        let local = Int64(DateMath.dayNumber(year: year, month: month, day: day) + extraDays) * DateMath.millisecondsPerDay
            + Int64(((hour * 60 + minute) * 60 + second) * 1000 + millisecond)
        let epoch: Int64
        if let offsetSeconds {
            epoch = local - Int64(offsetSeconds) * 1000
        } else {
            epoch = DateMath.epochMilliseconds(fromLocal: local, in: timeZone)
        }
        return DateMath.supportedEpochMilliseconds.contains(epoch) ? epoch : nil
    }
}

private struct DateScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ text: String) {
        bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    var isAtEnd: Bool { index >= bytes.count }

    func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    @discardableResult
    mutating func skipWhitespace() -> Bool {
        let start = index
        while let byte = peek(), FormulaNumberParsing.isASCIIWhitespace(byte) {
            index += 1
        }
        return index > start
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
    }

    /// Matches a literal from a format string: exact bytes, ASCII letters case-insensitively, and any
    /// punctuation for any punctuation.
    mutating func consumeLiteral(_ byte: UInt8) -> Bool {
        guard let next = peek() else { return false }
        if next == byte
            || (Self.isLetter(byte) && Self.lowercased(next) == Self.lowercased(byte))
            || (Self.isPunctuation(byte) && Self.isPunctuation(next)) {
            index += 1
            return true
        }
        return false
    }

    mutating func digits(min: Int, max: Int) -> Int? {
        guard let bytes = digitBytes(min: min, max: max) else { return nil }
        return bytes.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
    }

    mutating func digitBytes(min: Int, max: Int) -> ArraySlice<UInt8>? {
        let start = index
        while index - start < max, let byte = peek(), Self.isDigit(byte) {
            index += 1
        }
        guard index - start >= min else {
            index = start
            return nil
        }
        return bytes[start..<index]
    }

    static func milliseconds(fromFraction digits: ArraySlice<UInt8>) -> Int {
        var value = 0
        for position in 0..<3 {
            let index = digits.startIndex + position
            value = value * 10 + (index < digits.endIndex ? Int(digits[index] - UInt8(ascii: "0")) : 0)
        }
        return value
    }

    mutating func ordinalSuffix() -> Bool {
        for suffix in ["st", "nd", "rd", "th"] where matches(suffix) {
            index += 2
            return true
        }
        return false
    }

    mutating func monthName() -> Int? {
        let names = FormulaDateFormatting.monthNames + FormulaDateFormatting.monthShortNames + ["Sept"]
        guard let match = longestMatch(names) else { return nil }
        _ = consume(UInt8(ascii: "."))
        switch match {
        case 0..<12: return match + 1
        case 12..<24: return match - 11
        default: return 9
        }
    }

    mutating func weekdayName(allowMinimal: Bool) -> Int? {
        var names = FormulaDateFormatting.weekdayNames + FormulaDateFormatting.weekdayShortNames
        if allowMinimal {
            names += FormulaDateFormatting.weekdayMinNames
        }
        guard let match = longestMatch(names) else { return nil }
        _ = consume(UInt8(ascii: "."))
        return match % 7
    }

    /// Returns true for PM, false for AM. Accepts "am", "pm", "a", "p", "a.m.", "p.m." in any case.
    mutating func meridiem() -> Bool? {
        guard let first = peek() else { return nil }
        let letter = Self.lowercased(first)
        guard letter == UInt8(ascii: "a") || letter == UInt8(ascii: "p") else { return nil }
        let start = index
        index += 1
        _ = consume(UInt8(ascii: "."))
        if let next = peek(), Self.lowercased(next) == UInt8(ascii: "m") {
            index += 1
            _ = consume(UInt8(ascii: "."))
        }
        if let next = peek(), Self.isLetter(next) {
            index = start
            return nil
        }
        return letter == UInt8(ascii: "p")
    }

    /// `Z`, `UTC`, `GMT`, `±HH`, `±HHmm` or `±HH:mm`, in seconds east of UTC.
    mutating func utcOffset() -> Int? {
        guard let first = peek() else { return nil }
        if first == UInt8(ascii: "Z") || first == UInt8(ascii: "z") {
            index += 1
            return 0
        }
        if matches("UTC") || matches("GMT") {
            index += 3
            if peek() != UInt8(ascii: "+") && peek() != UInt8(ascii: "-") {
                return 0
            }
        }
        guard let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") else { return nil }
        index += 1
        guard let hours = digits(min: 1, max: 2) else { return nil }
        var minutes = 0
        if consume(UInt8(ascii: ":")) {
            guard let value = digits(min: 2, max: 2) else { return nil }
            minutes = value
        } else if let value = digits(min: 2, max: 2) {
            minutes = value
        }
        guard hours <= 23, minutes <= 59 else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == UInt8(ascii: "-") ? -seconds : seconds
    }

    private mutating func longestMatch(_ words: [String]) -> Int? {
        var best: (index: Int, length: Int)?
        for (position, word) in words.enumerated() where matches(word) {
            let length = word.utf8.count
            if length > (best?.length ?? 0) {
                best = (position, length)
            }
        }
        guard let best else { return nil }
        index += best.length
        return best.index
    }

    private func matches(_ word: String) -> Bool {
        var position = index
        for byte in word.utf8 {
            guard position < bytes.count, Self.lowercased(bytes[position]) == Self.lowercased(byte) else { return false }
            position += 1
        }
        return true
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    static func isPunctuation(_ byte: UInt8) -> Bool {
        byte < 0x80 && !isDigit(byte) && !isLetter(byte) && !FormulaNumberParsing.isASCIIWhitespace(byte) && byte > 0x20
    }

    static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
    }
}
