import Foundation

/// Encoding of date cells: date-only values are stored as "YYYY-MM-DD" (a calendar day, independent of
/// time zone) and date-times as ISO-8601 instants in UTC.
public enum DateCoding {
    public static func encode(_ date: Date, includeTime: Bool, timeZone: TimeZone = .current) -> String {
        if includeTime {
            return iso8601String(date)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    public static func decode(_ string: String, timeZone: TimeZone = .current) -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count == 10, let d = dayDate(s, timeZone: timeZone) { return d }
        return parseISO(s)
    }

    public static func dayDate(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              cal.component(.day, from: date) == d else { return nil }
        return date
    }

    public static func iso8601String(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
            .replacingOccurrences(of: "+0000", with: "Z")
    }

    public static func parseISO(_ s: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
        return nil
    }

    /// Parses free-form user input ("tomorrow", "2026-09-26", "26/9/2026", "Sep 26", "9/26/2026 3:30pm").
    public static func parseUserInput(_ input: String, timeZone: TimeZone = .current, now: Date = Date()) -> Date? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        switch s.lowercased() {
        case "today", "now": return s.lowercased() == "now" ? now : today
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        if let d = decode(s, timeZone: timeZone) { return d }
        let patterns = [
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy/MM/dd", "yyyy/MM/dd HH:mm",
            "d/M/yyyy", "d/M/yyyy HH:mm", "d/M/yyyy h:mma", "d/M/yyyy h:mm a",
            "M/d/yyyy", "M/d/yyyy HH:mm", "M/d/yyyy h:mma", "M/d/yyyy h:mm a",
            "d/M/yy", "M/d/yy", "d.M.yyyy", "d-M-yyyy",
            "MMM d, yyyy", "MMMM d, yyyy", "MMM d yyyy", "d MMM yyyy", "d MMMM yyyy",
            "MMM d, yyyy h:mm a", "MMMM d, yyyy h:mm a", "EEE, d MMM yyyy HH:mm:ss Z",
            "MMM d", "d MMM",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        // Prefer day-first parsing when the user's locale is day-first.
        let dayFirst = Locale.current.measurementSystem != .us
        let ordered = dayFirst ? patterns : patterns.sorted { a, b in a.hasPrefix("M/") && b.hasPrefix("d/") }
        for p in ordered {
            formatter.dateFormat = p
            if let d = formatter.date(from: s) {
                if !p.contains("y") {
                    var comps = cal.dateComponents([.month, .day, .hour, .minute], from: d)
                    comps.year = cal.component(.year, from: now)
                    return cal.date(from: comps)
                }
                return d
            }
        }
        return nil
    }
}

public enum CellFormatter {
    public static func number(_ n: Double, precision: Int?) -> String {
        guard n.isFinite else { return "" }
        if let p = precision {
            return n.formatted(.number.precision(.fractionLength(max(0, min(8, p)))).grouping(.automatic))
        }
        // Automatic: show as many decimals as needed, up to 8.
        return n.formatted(.number.precision(.fractionLength(0...8)).grouping(.automatic))
    }

    public static func duration(_ seconds: Double, format: DurationFormat) -> String {
        let negative = seconds < 0
        let total = Int(abs(seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let body = format == .hoursMinutesSeconds
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", h, m)
        return negative ? "-" + body : body
    }

    public static func date(_ date: Date, includeTime: Bool, format: DateDisplayFormat, use24Hour: Bool, timeZone: TimeZone = .current) -> String {
        var style: Date.FormatStyle
        switch format {
        case .local:
            style = Date.FormatStyle(date: .numeric, time: .omitted)
        case .friendly:
            style = Date.FormatStyle().month(.abbreviated).day().year()
        case .us:
            style = Date.FormatStyle(date: .omitted, time: .omitted).month(.defaultDigits).day(.defaultDigits).year()
            style = style.locale(Locale(identifier: "en_US"))
        case .european:
            style = Date.FormatStyle(date: .omitted, time: .omitted).day(.defaultDigits).month(.defaultDigits).year()
            style = style.locale(Locale(identifier: "en_GB"))
        case .iso:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            guard includeTime else { return day }
            return day + " " + time(date, use24Hour: use24Hour, timeZone: timeZone)
        }
        style.timeZone = timeZone
        let day = date.formatted(style)
        guard includeTime else { return day }
        return day + " " + time(date, use24Hour: use24Hour, timeZone: timeZone)
    }

    public static func time(_ date: Date, use24Hour: Bool, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0
        let m = c.minute ?? 0
        if use24Hour { return String(format: "%02d:%02d", h, m) }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d%@", h12, m, h < 12 ? "am" : "pm")
    }

    /// Plain-text rendering of a value for a field — used by the grid, CSV export, search and copy.
    public static func string(_ value: CellValue, field: FieldModel?, timeZone: TimeZone = .current) -> String {
        let options = field?.options ?? FieldOptions()
        let type = field?.type
        switch value {
        case .empty:
            return ""
        case .text(let s):
            if type == .multilineText, options.richText == true { return RichText.plainText(from: s) }
            return s
        case .number(let n):
            let fmt: FormulaResultFormat? = type == .formula || type == .rollup ? options.resultFormat : nil
            switch (type, fmt) {
            case (.currency, _), (_, .currency?):
                return (options.currencySymbol ?? "$") + number(n, precision: options.precision ?? 2)
            case (.percent, _), (_, .percent?):
                return number(n * 100, precision: options.precision ?? 0) + "%"
            case (.duration, _), (_, .duration?):
                return duration(n, format: options.durationFormat ?? .hoursMinutes)
            case (.rating, _), (.autoNumber, _), (.count, _):
                return n.isFinite && abs(n) < 1e15 ? String(Int64(n)) : number(n, precision: 0)
            default:
                return number(n, precision: options.precision)
            }
        case .bool(let b):
            if type == .checkbox { return b ? "checked" : "" }
            return b ? "true" : "false"
        case .date(let d, let includesTime):
            let fmt = options.resultFormat
            let showTime = fmt == .date ? false : (fmt == .dateTime ? true : includesTime)
            return date(d, includeTime: showTime, format: options.dateFormat ?? .friendly, use24Hour: options.use24HourClock ?? false, timeZone: timeZone)
        case .choice(let c):
            return c.name
        case .choices(let c):
            return c.map(\.name).joined(separator: ", ")
        case .attachments(let a):
            return a.map(\.filename).joined(separator: ", ")
        case .links(let l):
            return l.map(\.title).joined(separator: ", ")
        case .collaborators(let people):
            return people.map(\.displayName).joined(separator: ", ")
        case .list(let items):
            return items.map { string($0, field: nil, timeZone: timeZone) }.filter { !$0.isEmpty }.joined(separator: ", ")
        case .error:
            return "#ERROR!"
        }
    }
}
