import Foundation

/// Wall-clock fields of an instant in a time zone, at millisecond precision. Calendar math is done on a
/// proleptic Gregorian calendar with plain integer arithmetic (like JavaScript dates), so it is fast,
/// deterministic and independent of the system locale.
struct LocalDateTime: Equatable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    let millisecond: Int
    /// Days since 1970-01-01 on the local calendar.
    let dayNumber: Int
    let utcOffsetSeconds: Int
    let epochMilliseconds: Int64

    init(_ date: Date, in timeZone: TimeZone) {
        self.init(epochMilliseconds: DateMath.epochMilliseconds(date), in: timeZone)
    }

    init(epochMilliseconds: Int64, in timeZone: TimeZone) {
        let offset = DateMath.offsetSeconds(timeZone, atEpochMilliseconds: epochMilliseconds)
        let local = epochMilliseconds + Int64(offset) * 1000
        let days = FormulaMath.floorDivide(local, DateMath.millisecondsPerDay)
        let millisecondOfDay = Int(local - days * DateMath.millisecondsPerDay)
        let civil = DateMath.civil(dayNumber: Int(days))

        self.year = civil.year
        self.month = civil.month
        self.day = civil.day
        self.hour = millisecondOfDay / 3_600_000
        self.minute = millisecondOfDay / 60_000 % 60
        self.second = millisecondOfDay / 1000 % 60
        self.millisecond = millisecondOfDay % 1000
        self.dayNumber = Int(days)
        self.utcOffsetSeconds = offset
        self.epochMilliseconds = epochMilliseconds
    }

    /// 0 = Sunday … 6 = Saturday.
    var weekday: Int { DateMath.weekday(dayNumber: dayNumber) }

    var dayOfYear: Int { dayNumber - DateMath.dayNumber(year: year, month: 1, day: 1) + 1 }

    var millisecondOfDay: Int { ((hour * 60 + minute) * 60 + second) * 1000 + millisecond }

    var isMidnight: Bool { millisecondOfDay == 0 }

    /// Milliseconds since the epoch as if the wall-clock time were UTC.
    var localMilliseconds: Int64 {
        Int64(dayNumber) * DateMath.millisecondsPerDay + Int64(millisecondOfDay)
    }
}

enum DateMath {
    static let millisecondsPerDay: Int64 = 86_400_000
    /// The ECMAScript date range, ±100,000,000 days around the epoch.
    static let maximumEpochMilliseconds: Int64 = 8_640_000_000_000_000
    static let supportedEpochMilliseconds: ClosedRange<Int64> =
        Int64(dayNumber(year: 1, month: 1, day: 1)) * millisecondsPerDay
            ... Int64(dayNumber(year: 10000, month: 1, day: 1)) * millisecondsPerDay - 1

    static func epochMilliseconds(_ date: Date) -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        if milliseconds.isNaN { return 0 }
        let limit = Double(maximumEpochMilliseconds)
        return Int64(min(max(milliseconds, -limit), limit))
    }

    static func date(epochMilliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
    }

    static func offsetSeconds(_ timeZone: TimeZone, atEpochMilliseconds milliseconds: Int64) -> Int {
        let seconds = FormulaMath.floorDivide(milliseconds, 1000)
        return timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
    }

    /// Resolves a wall-clock time to an instant. Times repeated by a backward transition resolve to the
    /// earlier instant; times skipped by a forward transition move forward by the gap (02:30 → 03:30),
    /// matching JavaScript/moment.
    static func epochMilliseconds(fromLocal local: Int64, in timeZone: TimeZone) -> Int64 {
        func offset(at instant: Int64) -> Int64 {
            Int64(offsetSeconds(timeZone, atEpochMilliseconds: instant)) * 1000
        }

        let before = offset(at: local - millisecondsPerDay)
        let after = offset(at: local + millisecondsPerDay)
        if before == after {
            let candidate = local - before
            if offset(at: candidate) == before { return candidate }
        }

        let viaBefore = local - before
        let viaAfter = local - after
        let beforeIsValid = offset(at: viaBefore) == before
        let afterIsValid = offset(at: viaAfter) == after
        switch (beforeIsValid, afterIsValid) {
        case (true, true):
            return min(viaBefore, viaAfter)
        case (true, false):
            return viaBefore
        case (false, true):
            return viaAfter
        case (false, false):
            let actual = offset(at: viaBefore)
            let candidate = local - actual
            return offset(at: candidate) == actual ? candidate : viaBefore
        }
    }

    static func epochMilliseconds(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0, millisecond: Int = 0,
        in timeZone: TimeZone
    ) -> Int64 {
        let local = Int64(dayNumber(year: year, month: month, day: day)) * millisecondsPerDay
            + Int64(((hour * 60 + minute) * 60 + second) * 1000 + millisecond)
        return epochMilliseconds(fromLocal: local, in: timeZone)
    }

    static func startOfDay(_ date: Date, in timeZone: TimeZone) -> Date {
        let local = LocalDateTime(date, in: timeZone)
        return startOfDay(dayNumber: local.dayNumber, in: timeZone)
    }

    static func startOfDay(dayNumber: Int, in timeZone: TimeZone) -> Date {
        Self.date(epochMilliseconds: epochMilliseconds(fromLocal: Int64(dayNumber) * millisecondsPerDay, in: timeZone))
    }

    /// Adds calendar months keeping the wall-clock time; the day of month is clamped (Jan 31 + 1 month = Feb 28/29).
    static func addingMonths(_ months: Int, to local: LocalDateTime, in timeZone: TimeZone) -> Int64 {
        let total = local.year * 12 + (local.month - 1) + months
        let year = FormulaMath.floorDivide(total, 12)
        let month = FormulaMath.floorModulo(total, 12) + 1
        let day = min(local.day, daysInMonth(year: year, month: month))
        let wallClock = Int64(dayNumber(year: year, month: month, day: day)) * millisecondsPerDay
            + Int64(local.millisecondOfDay)
        return epochMilliseconds(fromLocal: wallClock, in: timeZone)
    }

    static func addingDays(_ days: Int, to local: LocalDateTime, in timeZone: TimeZone) -> Int64 {
        epochMilliseconds(fromLocal: local.localMilliseconds + Int64(days) * millisecondsPerDay, in: timeZone)
    }

    // Days-from-civil and civil-from-days (Howard Hinnant's algorithms).
    static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(dayNumber: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func daysInYear(_ year: Int) -> Int {
        isLeapYear(year) ? 366 : 365
    }

    /// 0 = Sunday … 6 = Saturday.
    static func weekday(dayNumber: Int) -> Int {
        FormulaMath.floorModulo(dayNumber + 4, 7)
    }

    static func isWeekend(dayNumber: Int) -> Bool {
        let weekday = weekday(dayNumber: dayNumber)
        return weekday == 0 || weekday == 6
    }
}

enum FormulaDateUnit: Sendable, Equatable {
    case millisecond, second, minute, hour, day, week, month, quarter, year

    /// Accepts moment.js unit names. `m` is minutes and `M` is months; everything else is case-insensitive.
    init?(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name == "m" { self = .minute; return }
        if name == "M" { self = .month; return }
        switch name.lowercased() {
        case "ms", "millisecond", "milliseconds": self = .millisecond
        case "s", "second", "seconds": self = .second
        case "minute", "minutes": self = .minute
        case "h", "hour", "hours": self = .hour
        case "d", "day", "days": self = .day
        case "w", "week", "weeks": self = .week
        case "month", "months": self = .month
        case "q", "quarter", "quarters": self = .quarter
        case "y", "year", "years": self = .year
        default: return nil
        }
    }

    var fixedMilliseconds: Int64? {
        switch self {
        case .millisecond: return 1
        case .second: return 1000
        case .minute: return 60_000
        case .hour: return 3_600_000
        case .day, .week, .month, .quarter, .year: return nil
        }
    }
}
