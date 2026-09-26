import Foundation

/// A moment.js format token.
enum MomentField: Sendable, Equatable {
    case year, yearTwoDigit
    case weekYear, weekYearTwoDigit, isoWeekYear, isoWeekYearTwoDigit
    case quarter, quarterOrdinal
    case month, monthPadded, monthOrdinal, monthShortName, monthLongName
    case dayOfMonth, dayOfMonthPadded, dayOfMonthOrdinal
    case dayOfYear, dayOfYearPadded, dayOfYearOrdinal
    case weekday, weekdayOrdinal, weekdayMinName, weekdayShortName, weekdayLongName, localeWeekday, isoWeekday
    case week, weekPadded, weekOrdinal, isoWeek, isoWeekPadded, isoWeekOrdinal
    case hour, hourPadded, hour12, hour12Padded, hourFrom1, hourFrom1Padded
    case minute, minutePadded, second, secondPadded
    case fraction(digits: Int)
    case meridiemUpper, meridiemLower
    case offsetWithColon, offsetWithoutColon
    case unixSeconds, unixMilliseconds
}

enum MomentToken: Sendable, Equatable {
    case literal(String)
    case field(MomentField)
}

/// moment.js-compatible formatting with the English (en) locale, independent of the system locale.
enum FormulaDateFormatting {
    static let defaultFormat = "YYYY-MM-DDTHH:mm:ss.SSSZ"

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    static let monthShortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdayShortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let weekdayMinNames = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private static let localizedPresets: [(pattern: [Character], expansion: String)] = {
        let table: [(String, String)] = [
            ("LTS", "h:mm:ss A"),
            ("LT", "h:mm A"),
            ("LLLL", "dddd, MMMM D, YYYY h:mm A"),
            ("LLL", "MMMM D, YYYY h:mm A"),
            ("LL", "MMMM D, YYYY"),
            ("L", "MM/DD/YYYY"),
            ("llll", "ddd, MMM D, YYYY h:mm A"),
            ("lll", "MMM D, YYYY h:mm A"),
            ("ll", "MMM D, YYYY"),
            ("l", "M/D/YYYY"),
        ]
        return table.map { (pattern: Array($0.0), expansion: $0.1) }
    }()

    /// Ordered so that the first prefix match is the one moment.js would pick.
    private static let fieldPatterns: [(pattern: [Character], field: MomentField)] = {
        let table: [(String, MomentField)] = [
            ("YYYY", .year), ("YY", .yearTwoDigit),
            ("gggg", .weekYear), ("gg", .weekYearTwoDigit), ("GGGG", .isoWeekYear), ("GG", .isoWeekYearTwoDigit),
            ("Qo", .quarterOrdinal), ("Q", .quarter),
            ("Mo", .monthOrdinal), ("MMMM", .monthLongName), ("MMM", .monthShortName), ("MM", .monthPadded), ("M", .month),
            ("DDDo", .dayOfYearOrdinal), ("DDDD", .dayOfYearPadded), ("DDD", .dayOfYear),
            ("Do", .dayOfMonthOrdinal), ("DD", .dayOfMonthPadded), ("D", .dayOfMonth),
            ("dddd", .weekdayLongName), ("ddd", .weekdayShortName), ("dd", .weekdayMinName), ("do", .weekdayOrdinal),
            ("d", .weekday), ("e", .localeWeekday), ("E", .isoWeekday),
            ("wo", .weekOrdinal), ("ww", .weekPadded), ("w", .week),
            ("Wo", .isoWeekOrdinal), ("WW", .isoWeekPadded), ("W", .isoWeek),
            ("HH", .hourPadded), ("H", .hour), ("hh", .hour12Padded), ("h", .hour12), ("kk", .hourFrom1Padded), ("k", .hourFrom1),
            ("mm", .minutePadded), ("m", .minute), ("ss", .secondPadded), ("s", .second),
            ("A", .meridiemUpper), ("a", .meridiemLower),
            ("ZZ", .offsetWithoutColon), ("Z", .offsetWithColon),
            ("X", .unixSeconds), ("x", .unixMilliseconds),
        ]
        return table.map { (pattern: Array($0.0), field: $0.1) }
    }()

    private static let tokenCache = FormulaCache<[MomentToken]>(capacity: 256)

    static func tokens(for format: String) -> [MomentToken] {
        tokenCache.value(for: format) {
            tokenize(expandLocalizedPresets(Array(format)))
        }
    }

    static func format(_ date: Date, as format: String, in timeZone: TimeZone) -> String {
        let local = LocalDateTime(date, in: timeZone)
        var output = ""
        for token in tokens(for: format) {
            switch token {
            case .literal(let text):
                output += text
            case .field(let field):
                output += render(field, local)
            }
        }
        return output
    }

    // MARK: Fixed renderings

    static func dateString(_ local: LocalDateTime) -> String {
        pad(local.year, 4) + "-" + pad(local.month, 2) + "-" + pad(local.day, 2)
    }

    static func timeString(_ local: LocalDateTime) -> String {
        pad(local.hour, 2) + ":" + pad(local.minute, 2) + ":" + pad(local.second, 2)
    }

    /// `YYYY-MM-DDTHH:mm:ss.SSSZ` in UTC with a literal `Z`, like JavaScript's `toISOString`.
    static func isoUTCString(_ date: Date) -> String {
        let local = LocalDateTime(date, in: .gmt)
        return dateString(local) + "T" + timeString(local) + "." + pad(local.millisecond, 3) + "Z"
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value.magnitude)
        let padded = digits.count < width ? String(repeating: "0", count: width - digits.count) + digits : digits
        return value < 0 ? "-" + padded : padded
    }

    static func ordinal(_ value: Int) -> String {
        let lastTwo = value % 100
        let suffix: String
        if (11...13).contains(lastTwo) {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return String(value) + suffix
    }

    /// moment's week numbering: weeks start on `firstWeekday` (0 = Sunday) and week 1 is the week that
    /// contains January `7 + firstWeekday - dayOfYearAnchor`. en uses (0, 6); ISO 8601 uses (1, 4).
    static func weekOfYear(_ local: LocalDateTime, firstWeekday: Int, dayOfYearAnchor: Int) -> (week: Int, year: Int) {
        let offset = firstWeekOffset(year: local.year, firstWeekday: firstWeekday, anchor: dayOfYearAnchor)
        let week = FormulaMath.floorDivide(local.dayOfYear - offset - 1, 7) + 1
        if week < 1 {
            let year = local.year - 1
            return (week + weeksInYear(year, firstWeekday: firstWeekday, anchor: dayOfYearAnchor), year)
        }
        let weeksThisYear = weeksInYear(local.year, firstWeekday: firstWeekday, anchor: dayOfYearAnchor)
        if week > weeksThisYear {
            return (week - weeksThisYear, local.year + 1)
        }
        return (week, local.year)
    }

    private static func firstWeekOffset(year: Int, firstWeekday: Int, anchor: Int) -> Int {
        let firstWeekDay = 7 + firstWeekday - anchor
        let weekdayOfAnchor = DateMath.weekday(dayNumber: DateMath.dayNumber(year: year, month: 1, day: firstWeekDay))
        let daysIntoWeek = (7 + weekdayOfAnchor - firstWeekday) % 7
        return -daysIntoWeek + firstWeekDay - 1
    }

    private static func weeksInYear(_ year: Int, firstWeekday: Int, anchor: Int) -> Int {
        let offset = firstWeekOffset(year: year, firstWeekday: firstWeekday, anchor: anchor)
        let nextOffset = firstWeekOffset(year: year + 1, firstWeekday: firstWeekday, anchor: anchor)
        return (DateMath.daysInYear(year) - offset + nextOffset) / 7
    }

    // MARK: Tokenizing

    private static func expandLocalizedPresets(_ format: [Character]) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(format.count)
        var index = 0
        while index < format.count {
            let character = format[index]
            if character == "[", let close = closingBracket(in: format, from: index) {
                output.append(contentsOf: format[index...close])
                index = close + 1
                continue
            }
            if character == "\\", index + 1 < format.count {
                output.append(character)
                if let preset = localizedPresets.first(where: { matches($0.pattern, in: format, at: index + 1) }) {
                    output.append(contentsOf: preset.pattern)
                    index += 1 + preset.pattern.count
                } else {
                    output.append(format[index + 1])
                    index += 2
                }
                continue
            }
            if let preset = localizedPresets.first(where: { matches($0.pattern, in: format, at: index) }) {
                output.append(contentsOf: preset.expansion)
                index += preset.pattern.count
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func tokenize(_ format: [Character]) -> [MomentToken] {
        var tokens: [MomentToken] = []
        var pendingLiteral = ""

        func flushLiteral() {
            if !pendingLiteral.isEmpty {
                tokens.append(.literal(pendingLiteral))
                pendingLiteral = ""
            }
        }

        var index = 0
        while index < format.count {
            let character = format[index]
            if character == "[" {
                if let close = closingBracket(in: format, from: index) {
                    pendingLiteral += String(format[(index + 1)..<close])
                    index = close + 1
                } else {
                    pendingLiteral.append(character)
                    index += 1
                }
                continue
            }
            if character == "\\", index + 1 < format.count {
                // A backslash makes the following token literal text.
                let length = fieldLength(in: format, at: index + 1) ?? 1
                pendingLiteral += String(format[(index + 1)..<(index + 1 + length)])
                index += 1 + length
                continue
            }
            if let (field, length) = field(in: format, at: index) {
                flushLiteral()
                tokens.append(.field(field))
                index += length
                continue
            }
            pendingLiteral.append(character)
            index += 1
        }
        flushLiteral()
        return tokens
    }

    private static func field(in format: [Character], at index: Int) -> (MomentField, Int)? {
        if format[index] == "S" {
            var length = 0
            while index + length < format.count, format[index + length] == "S", length < 9 {
                length += 1
            }
            return (.fraction(digits: length), length)
        }
        for candidate in fieldPatterns where matches(candidate.pattern, in: format, at: index) {
            return (candidate.field, candidate.pattern.count)
        }
        return nil
    }

    private static func fieldLength(in format: [Character], at index: Int) -> Int? {
        field(in: format, at: index)?.1
    }

    private static func matches(_ pattern: [Character], in format: [Character], at index: Int) -> Bool {
        guard index + pattern.count <= format.count else { return false }
        for offset in 0..<pattern.count where format[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// moment treats `[...]` as an escape only when no other `[` occurs before the closing `]`.
    private static func closingBracket(in format: [Character], from open: Int) -> Int? {
        var index = open + 1
        while index < format.count {
            switch format[index] {
            case "]": return index
            case "[": return nil
            default: index += 1
            }
        }
        return nil
    }

    // MARK: Rendering

    private static func render(_ field: MomentField, _ local: LocalDateTime) -> String {
        switch field {
        case .year:
            return pad(local.year, 4)
        case .yearTwoDigit:
            return pad(FormulaMath.floorModulo(local.year, 100), 2)
        case .weekYear:
            return pad(weekOfYear(local, firstWeekday: 0, dayOfYearAnchor: 6).year, 4)
        case .weekYearTwoDigit:
            return pad(FormulaMath.floorModulo(weekOfYear(local, firstWeekday: 0, dayOfYearAnchor: 6).year, 100), 2)
        case .isoWeekYear:
            return pad(weekOfYear(local, firstWeekday: 1, dayOfYearAnchor: 4).year, 4)
        case .isoWeekYearTwoDigit:
            return pad(FormulaMath.floorModulo(weekOfYear(local, firstWeekday: 1, dayOfYearAnchor: 4).year, 100), 2)
        case .quarter:
            return String((local.month - 1) / 3 + 1)
        case .quarterOrdinal:
            return ordinal((local.month - 1) / 3 + 1)
        case .month:
            return String(local.month)
        case .monthPadded:
            return pad(local.month, 2)
        case .monthOrdinal:
            return ordinal(local.month)
        case .monthShortName:
            return monthShortNames[local.month - 1]
        case .monthLongName:
            return monthNames[local.month - 1]
        case .dayOfMonth:
            return String(local.day)
        case .dayOfMonthPadded:
            return pad(local.day, 2)
        case .dayOfMonthOrdinal:
            return ordinal(local.day)
        case .dayOfYear:
            return String(local.dayOfYear)
        case .dayOfYearPadded:
            return pad(local.dayOfYear, 3)
        case .dayOfYearOrdinal:
            return ordinal(local.dayOfYear)
        case .weekday, .localeWeekday:
            return String(local.weekday)
        case .weekdayOrdinal:
            return ordinal(local.weekday)
        case .weekdayMinName:
            return weekdayMinNames[local.weekday]
        case .weekdayShortName:
            return weekdayShortNames[local.weekday]
        case .weekdayLongName:
            return weekdayNames[local.weekday]
        case .isoWeekday:
            return String(local.weekday == 0 ? 7 : local.weekday)
        case .week:
            return String(weekOfYear(local, firstWeekday: 0, dayOfYearAnchor: 6).week)
        case .weekPadded:
            return pad(weekOfYear(local, firstWeekday: 0, dayOfYearAnchor: 6).week, 2)
        case .weekOrdinal:
            return ordinal(weekOfYear(local, firstWeekday: 0, dayOfYearAnchor: 6).week)
        case .isoWeek:
            return String(weekOfYear(local, firstWeekday: 1, dayOfYearAnchor: 4).week)
        case .isoWeekPadded:
            return pad(weekOfYear(local, firstWeekday: 1, dayOfYearAnchor: 4).week, 2)
        case .isoWeekOrdinal:
            return ordinal(weekOfYear(local, firstWeekday: 1, dayOfYearAnchor: 4).week)
        case .hour:
            return String(local.hour)
        case .hourPadded:
            return pad(local.hour, 2)
        case .hour12:
            return String(twelveHour(local.hour))
        case .hour12Padded:
            return pad(twelveHour(local.hour), 2)
        case .hourFrom1:
            return String(local.hour == 0 ? 24 : local.hour)
        case .hourFrom1Padded:
            return pad(local.hour == 0 ? 24 : local.hour, 2)
        case .minute:
            return String(local.minute)
        case .minutePadded:
            return pad(local.minute, 2)
        case .second:
            return String(local.second)
        case .secondPadded:
            return pad(local.second, 2)
        case .fraction(let digits):
            let milliseconds = pad(local.millisecond, 3)
            return digits <= 3
                ? String(milliseconds.prefix(digits))
                : milliseconds + String(repeating: "0", count: digits - 3)
        case .meridiemUpper:
            return local.hour < 12 ? "AM" : "PM"
        case .meridiemLower:
            return local.hour < 12 ? "am" : "pm"
        case .offsetWithColon:
            return offsetString(local.utcOffsetSeconds, separator: ":")
        case .offsetWithoutColon:
            return offsetString(local.utcOffsetSeconds, separator: "")
        case .unixSeconds:
            return String(FormulaMath.floorDivide(local.epochMilliseconds, 1000))
        case .unixMilliseconds:
            return String(local.epochMilliseconds)
        }
    }

    private static func twelveHour(_ hour: Int) -> Int {
        hour % 12 == 0 ? 12 : hour % 12
    }

    private static func offsetString(_ seconds: Int, separator: String) -> String {
        let totalMinutes = (seconds.magnitude + 30) / 60
        let sign = seconds < 0 ? "-" : "+"
        return sign + pad(Int(totalMinutes / 60), 2) + separator + pad(Int(totalMinutes % 60), 2)
    }
}
