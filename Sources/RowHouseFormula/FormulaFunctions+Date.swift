import Foundation

// Every date function returns blank when its date argument is blank, so formulas over optional date
// fields don't need an IF guard.
extension FormulaFunctionRegistry {
    static let dateFunctions: [FormulaFunction] = [
        FormulaFunction("NOW()", .date, .exactly(0), summary: "Returns the current date and time.") { call in
            .date(call.context.now)
        },

        FormulaFunction("TODAY()", .date, .exactly(0), summary: "Returns today's date at midnight.") { call in
            .date(DateMath.startOfDay(call.context.now, in: call.timeZone))
        },

        FormulaFunction(
            "DATEADD(date, count, unit)", .date, .exactly(3),
            summary: "Adds count units (e.g. \"days\", \"months\", \"hours\") to a date."
        ) { call in
            guard let date = try call.date(0) else { return .blank }
            let count = try call.number(1)
            let unit = try FormulaDateFunctions.unit(call, 2)
            return try .date(FormulaDateFunctions.adding(count, unit, to: date, in: call.timeZone))
        },

        FormulaFunction(
            "DATETIME_DIFF(date1, date2, [unit])", .date, .range(2, 3),
            summary: "Returns date1 minus date2 in whole units (default \"seconds\")."
        ) { call in
            guard let first = try call.date(0), let second = try call.date(1) else { return .blank }
            let unit: FormulaDateUnit = try call.hasValue(2) ? FormulaDateFunctions.unit(call, 2) : .second
            return .number(Double(FormulaDateFunctions.difference(first, second, unit, in: call.timeZone)))
        },

        FormulaFunction(
            "DATETIME_FORMAT(date, [format])", .date, .range(1, 2),
            summary: "Formats a date with moment.js tokens such as \"YYYY-MM-DD\" or \"LL\"."
        ) { call in
            guard let date = try call.date(0) else { return .blank }
            let format = call.hasValue(1) ? call.text(1) : FormulaDateFormatting.defaultFormat
            return .text(FormulaDateFormatting.format(date, as: format, in: call.timeZone))
        },

        FormulaFunction(
            "DATETIME_PARSE(text, [format], [locale])", .date, .range(1, 3),
            summary: "Interprets text as a date, optionally with a moment.js format string."
        ) { call in
            let input = FormulaCoercion.singleValue(call.value(0))
            if case .date(let date) = input {
                return .date(date)
            }
            let text = call.text(0)
            if text.allSatisfy(\.isWhitespace) {
                return .blank
            }
            if call.hasValue(1) {
                return try .date(FormulaDateParsing.parse(text, format: call.text(1), timeZone: call.timeZone, now: call.context.now))
            }
            guard let date = FormulaDateParsing.parseDefault(text, timeZone: call.timeZone) else {
                throw FormulaError("Cannot parse \(FormulaCoercion.quoted(text)) as a date")
            }
            return .date(date)
        },

        FormulaFunction("DATESTR(date)", .date, .exactly(1), summary: "Formats a date as YYYY-MM-DD.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .text(FormulaDateFormatting.dateString($0)) }
        },

        FormulaFunction("TIMESTR(date)", .date, .exactly(1), summary: "Formats the time of a date as HH:mm:ss.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .text(FormulaDateFormatting.timeString($0)) }
        },

        FormulaFunction("YEAR(date)", .date, .exactly(1), summary: "Returns the four-digit year of a date.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .number(Double($0.year)) }
        },

        FormulaFunction("MONTH(date)", .date, .exactly(1), summary: "Returns the month of a date, 1 (January) to 12.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .number(Double($0.month)) }
        },

        FormulaFunction("DAY(date)", .date, .exactly(1), summary: "Returns the day of the month, 1 to 31.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .number(Double($0.day)) }
        },

        FormulaFunction("HOUR(date)", .date, .exactly(1), summary: "Returns the hour of a date, 0 to 23.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .number(Double($0.hour)) }
        },

        FormulaFunction("MINUTE(date)", .date, .exactly(1), summary: "Returns the minute of a date, 0 to 59.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .number(Double($0.minute)) }
        },

        FormulaFunction("SECOND(date)", .date, .exactly(1), summary: "Returns the second of a date, 0 to 59.") { call in
            try FormulaDateFunctions.withLocalDate(call) { .number(Double($0.second)) }
        },

        FormulaFunction(
            "WEEKDAY(date, [startDay])", .date, .range(1, 2),
            summary: "Returns the day of the week, 0-based from startDay (\"Sunday\" by default, or \"Monday\")."
        ) { call in
            let startDay = try FormulaDateFunctions.weekStart(call, 1)
            return try FormulaDateFunctions.withLocalDate(call) { local in
                .number(Double((local.weekday - startDay + 7) % 7))
            }
        },

        FormulaFunction(
            "WEEKNUM(date, [startDay])", .date, .range(1, 2),
            summary: "Returns the week of the year; week 1 contains January 1st and weeks start on startDay."
        ) { call in
            let startDay = try FormulaDateFunctions.weekStart(call, 1)
            return try FormulaDateFunctions.withLocalDate(call) { local in
                let januaryFirst = DateMath.dayNumber(year: local.year, month: 1, day: 1)
                let leadingDays = (DateMath.weekday(dayNumber: januaryFirst) - startDay + 7) % 7
                return .number(Double((local.dayNumber - januaryFirst + leadingDays) / 7 + 1))
            }
        },

        FormulaFunction(
            "IS_BEFORE(date1, date2)", .date, .exactly(2),
            summary: "Returns true if date1 is earlier than date2."
        ) { call in
            guard let first = try call.date(0), let second = try call.date(1) else { return .blank }
            return .bool(DateMath.epochMilliseconds(first) < DateMath.epochMilliseconds(second))
        },

        FormulaFunction(
            "IS_AFTER(date1, date2)", .date, .exactly(2),
            summary: "Returns true if date1 is later than date2."
        ) { call in
            guard let first = try call.date(0), let second = try call.date(1) else { return .blank }
            return .bool(DateMath.epochMilliseconds(first) > DateMath.epochMilliseconds(second))
        },

        FormulaFunction(
            "IS_SAME(date1, date2, [unit])", .date, .range(2, 3),
            summary: "Returns true if the dates are equal, or fall in the same unit (e.g. \"day\", \"month\") when given."
        ) { call in
            guard let first = try call.date(0), let second = try call.date(1) else { return .blank }
            let unit: FormulaDateUnit = try call.hasValue(2) ? FormulaDateFunctions.unit(call, 2) : .millisecond
            return .bool(FormulaDateFunctions.isSame(first, second, unit, in: call.timeZone))
        },

        FormulaFunction(
            "WORKDAY(startDate, numDays, [holidays])", .date, .range(2, 3),
            summary: "Returns the date numDays working days (Monday–Friday) from startDate, skipping holidays."
        ) { call in
            guard let start = try call.date(0) else { return .blank }
            let days = try call.integer(1)
            guard days.magnitude <= 3_000_000 else { throw FormulaError("Date is out of range") }
            let holidays = try FormulaDateFunctions.holidays(call, 2)
            let startDay = LocalDateTime(start, in: call.timeZone).dayNumber
            let resultDay = FormulaWorkdays.workday(from: startDay, adding: days, holidays: holidays)
            let result = DateMath.startOfDay(dayNumber: resultDay, in: call.timeZone)
            guard DateMath.supportedEpochMilliseconds.contains(DateMath.epochMilliseconds(result)) else {
                throw FormulaError("Date is out of range")
            }
            return .date(result)
        },

        FormulaFunction(
            "WORKDAY_DIFF(startDate, endDate, [holidays])", .date, .range(2, 3),
            summary: "Counts working days (Monday–Friday) from startDate to endDate inclusive, excluding holidays."
        ) { call in
            guard let start = try call.date(0), let end = try call.date(1) else { return .blank }
            let holidays = try FormulaDateFunctions.holidays(call, 2)
            let count = FormulaWorkdays.workingDays(
                from: LocalDateTime(start, in: call.timeZone).dayNumber,
                to: LocalDateTime(end, in: call.timeZone).dayNumber,
                holidays: holidays
            )
            return .number(Double(count))
        },

        FormulaFunction(
            "TONOW(date)", .date, .exactly(1),
            summary: "Returns the number of whole days between the date and now."
        ) { call in
            try FormulaDateFunctions.daysFromNow(call)
        },

        FormulaFunction(
            "FROMNOW(date)", .date, .exactly(1),
            summary: "Returns the number of whole days between now and the date."
        ) { call in
            try FormulaDateFunctions.daysFromNow(call)
        },

        FormulaFunction(
            "SET_TIMEZONE(date, timeZone)", .date, .exactly(2),
            summary: "Accepted for compatibility; returns the date unchanged (dates use the base time zone)."
        ) { call in
            guard let date = try call.date(0) else { return .blank }
            let identifier = call.text(1).trimmingCharacters(in: .whitespaces)
            guard TimeZone(identifier: identifier) != nil else {
                throw FormulaError("Unknown time zone \(FormulaCoercion.quoted(identifier))")
            }
            return .date(date)
        },

        FormulaFunction(
            "SET_LOCALE(date, locale)", .date, .exactly(2),
            summary: "Accepted for compatibility; returns the date unchanged (formatting is always English)."
        ) { call in
            guard let date = try call.date(0) else { return .blank }
            return .date(date)
        },
    ]
}

enum FormulaDateFunctions {
    static func unit(_ call: FormulaCall, _ index: Int) throws(FormulaError) -> FormulaDateUnit {
        let name = call.text(index)
        guard let unit = FormulaDateUnit(name) else {
            throw FormulaError("Unknown date unit \(FormulaCoercion.quoted(name))")
        }
        return unit
    }

    static func withLocalDate(
        _ call: FormulaCall, _ body: (LocalDateTime) -> FormulaValue
    ) throws(FormulaError) -> FormulaValue {
        guard let date = try call.date(0) else { return .blank }
        return body(LocalDateTime(date, in: call.timeZone))
    }

    /// 0 for Sunday, 1 for Monday.
    static func weekStart(_ call: FormulaCall, _ index: Int) throws(FormulaError) -> Int {
        guard call.hasValue(index) else { return 0 }
        switch call.text(index).trimmingCharacters(in: .whitespaces).lowercased() {
        case "sunday": return 0
        case "monday": return 1
        default: throw FormulaError("\(call.name) start day must be \"Sunday\" or \"Monday\"")
        }
    }

    static func daysFromNow(_ call: FormulaCall) throws(FormulaError) -> FormulaValue {
        guard let date = try call.date(0) else { return .blank }
        let now = LocalDateTime(call.context.now, in: call.timeZone)
        let then = LocalDateTime(date, in: call.timeZone)
        let days = (now.localMilliseconds - then.localMilliseconds) / DateMath.millisecondsPerDay
        return .number(Double(days.magnitude))
    }

    /// Fixed units are exact durations; days and weeks keep the wall-clock time across DST changes;
    /// months, quarters and years clamp the day of month. Fractional day and month counts are rounded
    /// like moment.js.
    static func adding(_ count: Double, _ unit: FormulaDateUnit, to date: Date, in timeZone: TimeZone) throws(FormulaError) -> Date {
        let outOfRange = FormulaError("Date is out of range")
        let result: Int64
        if let unitMilliseconds = unit.fixedMilliseconds {
            let target = Double(DateMath.epochMilliseconds(date)) + count * Double(unitMilliseconds)
            guard target.isFinite, target.magnitude <= Double(DateMath.maximumEpochMilliseconds) else { throw outOfRange }
            result = Int64(target.rounded())
        } else {
            let local = LocalDateTime(date, in: timeZone)
            switch unit {
            case .week, .day:
                let days = (unit == .week ? count * 7 : count).rounded(.toNearestOrAwayFromZero)
                guard days.magnitude <= 4_000_000 else { throw outOfRange }
                result = DateMath.addingDays(Int(days), to: local, in: timeZone)
            default:
                let monthsPerUnit: Double = unit == .year ? 12 : (unit == .quarter ? 3 : 1)
                let months = (count * monthsPerUnit).rounded(.toNearestOrAwayFromZero)
                guard months.magnitude <= 130_000 else { throw outOfRange }
                result = DateMath.addingMonths(Int(months), to: local, in: timeZone)
            }
        }
        guard DateMath.supportedEpochMilliseconds.contains(result) else { throw outOfRange }
        return DateMath.date(epochMilliseconds: result)
    }

    /// `first - second` truncated toward zero, following moment's `diff`: hours and smaller are exact
    /// durations, days and weeks use wall-clock time, months and longer are calendar months.
    static func difference(_ first: Date, _ second: Date, _ unit: FormulaDateUnit, in timeZone: TimeZone) -> Int64 {
        if let unitMilliseconds = unit.fixedMilliseconds {
            return (DateMath.epochMilliseconds(first) - DateMath.epochMilliseconds(second)) / unitMilliseconds
        }
        let a = LocalDateTime(first, in: timeZone)
        let b = LocalDateTime(second, in: timeZone)
        switch unit {
        case .day:
            return (a.localMilliseconds - b.localMilliseconds) / DateMath.millisecondsPerDay
        case .week:
            return (a.localMilliseconds - b.localMilliseconds) / (7 * DateMath.millisecondsPerDay)
        case .quarter:
            return Int64((monthDifference(a, b, in: timeZone) / 3).rounded(.towardZero))
        case .year:
            return Int64((monthDifference(a, b, in: timeZone) / 12).rounded(.towardZero))
        default:
            return Int64(monthDifference(a, b, in: timeZone).rounded(.towardZero))
        }
    }

    /// moment's fractional month difference `a - b`, interpolating linearly within the partial month.
    private static func monthDifference(_ a: LocalDateTime, _ b: LocalDateTime, in timeZone: TimeZone) -> Double {
        let wholeMonths = (b.year - a.year) * 12 + (b.month - a.month)
        let anchor = DateMath.addingMonths(wholeMonths, to: a, in: timeZone)
        let target = b.epochMilliseconds
        let adjustment: Double
        if target - anchor < 0 {
            let previous = DateMath.addingMonths(wholeMonths - 1, to: a, in: timeZone)
            adjustment = Double(target - anchor) / Double(anchor - previous)
        } else {
            let next = DateMath.addingMonths(wholeMonths + 1, to: a, in: timeZone)
            adjustment = Double(target - anchor) / Double(next - anchor)
        }
        let result = -(Double(wholeMonths) + adjustment)
        return result == 0 ? 0 : result
    }

    static func isSame(_ first: Date, _ second: Date, _ unit: FormulaDateUnit, in timeZone: TimeZone) -> Bool {
        if unit == .millisecond {
            return DateMath.epochMilliseconds(first) == DateMath.epochMilliseconds(second)
        }
        let a = LocalDateTime(first, in: timeZone)
        let b = LocalDateTime(second, in: timeZone)
        switch unit {
        case .year:
            return a.year == b.year
        case .quarter:
            return a.year == b.year && (a.month - 1) / 3 == (b.month - 1) / 3
        case .month:
            return a.year == b.year && a.month == b.month
        case .week:
            return a.dayNumber - a.weekday == b.dayNumber - b.weekday
        case .day:
            return a.dayNumber == b.dayNumber
        case .hour:
            return a.dayNumber == b.dayNumber && a.hour == b.hour
        case .minute:
            return a.dayNumber == b.dayNumber && a.hour == b.hour && a.minute == b.minute
        default:
            return a.dayNumber == b.dayNumber && a.hour == b.hour && a.minute == b.minute && a.second == b.second
        }
    }

    /// Holidays may be comma-separated date text, dates, or arrays of either.
    static func holidays(_ call: FormulaCall, _ index: Int) throws(FormulaError) -> Set<Int> {
        guard call.has(index) else { return [] }
        var days = Set<Int>()
        for value in FormulaArrays.expand([call.value(index)]) {
            switch value {
            case .blank:
                continue
            case .date(let date):
                days.insert(LocalDateTime(date, in: call.timeZone).dayNumber)
            case .text(let text):
                for part in text.split(separator: ",") {
                    let entry = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if entry.isEmpty { continue }
                    guard let date = FormulaDateParsing.parseDefault(entry, timeZone: call.timeZone) else {
                        throw FormulaError("Cannot interpret holiday \(FormulaCoercion.quoted(entry)) as a date")
                    }
                    days.insert(LocalDateTime(date, in: call.timeZone).dayNumber)
                }
            case .number, .bool:
                throw FormulaError("Holidays must be dates")
            case .array, .error:
                continue
            }
        }
        return days
    }
}

/// Working-day arithmetic on local day numbers (days since 1970-01-01), Monday–Friday.
enum FormulaWorkdays {
    /// Excel's WORKDAY: the start day itself is never counted.
    static func workday(from start: Int, adding days: Int, holidays: Set<Int>) -> Int {
        guard days != 0 else { return start }
        let step = days > 0 ? 1 : -1
        let weekdayHolidays = holidays.filter { !DateMath.isWeekend(dayNumber: $0) }

        func holidaysBetween(_ from: Int, _ to: Int) -> Int {
            // Holidays strictly after `from` up to and including `to`, in the direction of travel.
            weekdayHolidays.reduce(0) { count, holiday in
                let inRange = step > 0 ? (holiday > from && holiday <= to) : (holiday < from && holiday >= to)
                return count + (inRange ? 1 : 0)
            }
        }

        var current = advance(from: start, by: abs(days), step: step)
        var pending = holidaysBetween(start, current)
        while pending > 0 {
            let next = advance(from: current, by: pending, step: step)
            pending = holidaysBetween(current, next)
            current = next
        }
        return current
    }

    /// Excel's NETWORKDAYS: both ends inclusive; negative when `end` is before `start`.
    static func workingDays(from start: Int, to end: Int, holidays: Set<Int>) -> Int {
        if start > end {
            return -workingDays(from: end, to: start, holidays: holidays)
        }
        let span = end - start + 1
        let fullWeeks = span / 7
        var count = fullWeeks * 5
        var day = start + fullWeeks * 7
        while day <= end {
            if !DateMath.isWeekend(dayNumber: day) { count += 1 }
            day += 1
        }
        for holiday in holidays where holiday >= start && holiday <= end && !DateMath.isWeekend(dayNumber: holiday) {
            count -= 1
        }
        return count
    }

    private static func advance(from start: Int, by count: Int, step: Int) -> Int {
        var day = start
        // A weekend start behaves like the adjacent weekday on the side we're moving away from.
        switch DateMath.weekday(dayNumber: day) {
        case 6: day += step > 0 ? -1 : 2
        case 0: day += step > 0 ? -2 : 1
        default: break
        }
        var remaining = count
        let weeks = remaining / 5
        day += step * weeks * 7
        remaining -= weeks * 5
        while remaining > 0 {
            day += step
            if !DateMath.isWeekend(dayNumber: day) {
                remaining -= 1
            }
        }
        return day
    }
}
