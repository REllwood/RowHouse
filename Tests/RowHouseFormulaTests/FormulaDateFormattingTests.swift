import Foundation
import Testing
import RowHouseFormula

@Suite("DATETIME_FORMAT")
struct FormulaDateFormattingTests {
    /// Thursday 4 September 1986, 20:30:25.123 UTC — the date moment.js uses in its documentation.
    let context = TestContext(fields: [
        "D": .date(TestDates.utc(1986, 9, 4, 20, 30, 25, millisecond: 123)),
        "Midnight": .date(TestDates.utc(2024, 1, 5)),
        "Noon": .date(TestDates.utc(2024, 1, 5, 12, 5, 9)),
        "Sunday": .date(TestDates.utc(2024, 3, 17)),
        "YearEnd": .date(TestDates.utc(2024, 12, 31)),
        "NewYear2021": .date(TestDates.utc(2021, 1, 1)),
        "Blank": .blank,
    ])

    @Test("Tokens", arguments: [
        ("YYYY", "1986"), ("YY", "86"), ("Q", "3"), ("Qo", "3rd"),
        ("M", "9"), ("MM", "09"), ("Mo", "9th"), ("MMM", "Sep"), ("MMMM", "September"),
        ("D", "4"), ("DD", "04"), ("Do", "4th"), ("DDD", "247"), ("DDDD", "247"), ("DDDo", "247th"),
        ("d", "4"), ("do", "4th"), ("dd", "Th"), ("ddd", "Thu"), ("dddd", "Thursday"), ("e", "4"), ("E", "4"),
        ("w", "36"), ("ww", "36"), ("wo", "36th"), ("W", "36"), ("WW", "36"), ("gggg", "1986"), ("GGGG", "1986"),
        ("H", "20"), ("HH", "20"), ("h", "8"), ("hh", "08"), ("k", "20"), ("kk", "20"),
        ("m", "30"), ("mm", "30"), ("s", "25"), ("ss", "25"),
        ("S", "1"), ("SS", "12"), ("SSS", "123"), ("SSSS", "1230"),
        ("A", "PM"), ("a", "pm"), ("Z", "+00:00"), ("ZZ", "+0000"),
        ("X", "526249825"), ("x", "526249825123"),
    ])
    func token(format: String, expected: String) {
        expectText("DATETIME_FORMAT({D}, \"\(format)\")", expected, context)
    }

    @Test("Localized presets", arguments: [
        ("L", "09/04/1986"),
        ("LL", "September 4, 1986"),
        ("LLL", "September 4, 1986 8:30 PM"),
        ("LLLL", "Thursday, September 4, 1986 8:30 PM"),
        ("LT", "8:30 PM"),
        ("LTS", "8:30:25 PM"),
        ("l", "9/4/1986"),
        ("ll", "Sep 4, 1986"),
        ("lll", "Sep 4, 1986 8:30 PM"),
        ("llll", "Thu, Sep 4, 1986 8:30 PM"),
    ])
    func preset(format: String, expected: String) {
        expectText("DATETIME_FORMAT({D}, \"\(format)\")", expected, context)
    }

    @Test func combinedFormats() {
        expectText(#"DATETIME_FORMAT({D}, "YYYY-MM-DD HH:mm:ss")"#, "1986-09-04 20:30:25", context)
        expectText(#"DATETIME_FORMAT({D}, "dddd, MMMM Do YYYY, h:mm:ss a")"#, "Thursday, September 4th 1986, 8:30:25 pm", context)
        expectText(#"DATETIME_FORMAT({D}, "ddd, hA")"#, "Thu, 8PM", context)
        expectText(#"DATETIME_FORMAT({D}, "[Today is] dddd")"#, "Today is Thursday", context)
        expectText(#"DATETIME_FORMAT({D}, "[Q]Q YYYY")"#, "Q3 1986", context)
        expectText(#"DATETIME_FORMAT({D}, "[[YYYY]")"#, "[YYYY", context)
        expectText(#"DATETIME_FORMAT({D}, "YYYY [no")"#, "1986 [no", context)
        expectText(#"DATETIME_FORMAT({D}, "\\YYYY")"#, "YYYY", context)
        expectText(#"DATETIME_FORMAT({D}, "[L] L")"#, "L 09/04/1986", context)
        expectText(#"DATETIME_FORMAT({D}, "YYYY年M月D日")"#, "1986年9月4日", context)
    }

    @Test func defaultFormat() {
        expectText("DATETIME_FORMAT({D})", "1986-09-04T20:30:25.123+00:00", context)
        expectText(#"DATETIME_FORMAT({D}, "")"#, "1986-09-04T20:30:25.123+00:00", context)
    }

    @Test func clockEdgeCases() {
        expectText(#"DATETIME_FORMAT({Midnight}, "h hh k kk H A")"#, "12 12 24 24 0 AM", context)
        expectText(#"DATETIME_FORMAT({Noon}, "h hh k H A a m s")"#, "12 12 12 12 PM pm 5 9", context)
    }

    @Test func ordinals() {
        let expectations: [(Int, String)] = [
            (1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (11, "11th"), (12, "12th"), (13, "13th"),
            (21, "21st"), (22, "22nd"), (23, "23rd"), (31, "31st"),
        ]
        for (day, expected) in expectations {
            let dayContext = TestContext(fields: ["X": .date(TestDates.utc(2024, 1, day))])
            expectText(#"DATETIME_FORMAT({X}, "Do")"#, expected, dayContext)
        }
    }

    @Test func weekdayTokensOnSunday() {
        expectText(#"DATETIME_FORMAT({Sunday}, "d e E dd ddd dddd")"#, "0 0 7 Su Sun Sunday", context)
    }

    @Test func weekYearBoundaries() {
        expectText(#"DATETIME_FORMAT({YearEnd}, "w gggg W GGGG DDDD")"#, "1 2025 1 2025 366", context)
        expectText(#"DATETIME_FORMAT({NewYear2021}, "w gggg W GGGG DDDD")"#, "1 2021 53 2020 001", context)
    }

    @Test func formatsInTheContextTimeZone() {
        let sydney = TestContext(fields: ["T": .date(TestDates.utc(2024, 1, 5, 10, 30))], timeZone: "Australia/Sydney")
        expectText(#"DATETIME_FORMAT({T}, "YYYY-MM-DD HH:mm Z")"#, "2024-01-05 21:30 +11:00", sydney)
        expectText(#"DATETIME_FORMAT({T}, "ZZ")"#, "+1100", sydney)
        let newYork = TestContext(fields: ["T": .date(TestDates.utc(2024, 1, 5, 10, 30))], timeZone: "America/New_York")
        expectText(#"DATETIME_FORMAT({T}, "YYYY-MM-DD HH:mm ZZ")"#, "2024-01-05 05:30 -0500", newYork)
        let kolkata = TestContext(fields: ["T": .date(TestDates.utc(2024, 1, 5, 10, 30))], timeZone: "Asia/Kolkata")
        expectText(#"DATETIME_FORMAT({T}, "HH:mm Z")"#, "16:00 +05:30", kolkata)
    }

    @Test func textAndBlankInputs() {
        expectText(#"DATETIME_FORMAT("2024-07-04", "MMMM D")"#, "July 4")
        expectValue("DATETIME_FORMAT({Blank}, \"YYYY\")", .blank, context)
        expectError(#"DATETIME_FORMAT("soon", "YYYY")"#, containing: "Cannot interpret")
    }
}

@Suite("DATETIME_PARSE")
struct FormulaDateParsingTests {
    let utc = TestContext()
    let sydney = TestContext(timeZone: "Australia/Sydney")
    let newYork = TestContext(timeZone: "America/New_York")

    @Test("Formats accepted without a format string", arguments: [
        ("2024-01-05", TestDates.utc(2024, 1, 5)),
        ("2024-1-5", TestDates.utc(2024, 1, 5)),
        ("2024-01-05T10:30", TestDates.utc(2024, 1, 5, 10, 30)),
        ("2024-01-05t10:30:15", TestDates.utc(2024, 1, 5, 10, 30, 15)),
        ("2024-01-05 10:30:15.250", TestDates.utc(2024, 1, 5, 10, 30, 15, millisecond: 250)),
        ("2024-01-05T10:30:15.250Z", TestDates.utc(2024, 1, 5, 10, 30, 15, millisecond: 250)),
        ("2024-01-05T10:30:15.123456Z", TestDates.utc(2024, 1, 5, 10, 30, 15, millisecond: 123)),
        ("2024-01-05T10:30:00+02:00", TestDates.utc(2024, 1, 5, 8, 30)),
        ("2024-01-05 10:30:00 -0500", TestDates.utc(2024, 1, 5, 15, 30)),
        ("2024-01-05T10:30:00+05", TestDates.utc(2024, 1, 5, 5, 30)),
        ("2024-01-05 10:30 UTC", TestDates.utc(2024, 1, 5, 10, 30)),
        ("2024/01/05", TestDates.utc(2024, 1, 5)),
        ("2024/1/5 7:05", TestDates.utc(2024, 1, 5, 7, 5)),
        ("1/5/2024", TestDates.utc(2024, 1, 5)),
        ("12/31/2024", TestDates.utc(2024, 12, 31)),
        ("1/5/2024 3:45 pm", TestDates.utc(2024, 1, 5, 15, 45)),
        ("January 5, 2024", TestDates.utc(2024, 1, 5)),
        ("Jan 5 2024", TestDates.utc(2024, 1, 5)),
        ("jan. 5, 2024", TestDates.utc(2024, 1, 5)),
        ("Sept 4, 1986", TestDates.utc(1986, 9, 4)),
        ("September 4th, 1986", TestDates.utc(1986, 9, 4)),
        ("5 January 2024", TestDates.utc(2024, 1, 5)),
        ("5th Jan 2024", TestDates.utc(2024, 1, 5)),
        ("Thursday, September 4, 1986 8:30 PM", TestDates.utc(1986, 9, 4, 20, 30)),
        ("Thu, Sep 4, 1986 8:30 PM", TestDates.utc(1986, 9, 4, 20, 30)),
        ("2024-01-05 12:00 AM", TestDates.utc(2024, 1, 5)),
        ("2024-01-05 12:15 PM", TestDates.utc(2024, 1, 5, 12, 15)),
        ("  2024-01-05  ", TestDates.utc(2024, 1, 5)),
    ])
    func defaultFormats(text: String, expected: Date) {
        expectDate("DATETIME_PARSE(\"\(text)\")", expected, utc)
    }

    @Test("Invalid input is an error", arguments: [
        "2024-02-30", "2023-02-29", "13/1/2024", "not a date", "2024-01-05 25:00", "2024-01-05 10:60",
        "2024-01-05T", "2024-13-01", "January 32, 2024", "2024-01-05 10:30 +25:00", "2024-01-05 extra",
    ])
    func invalid(text: String) {
        expectError("DATETIME_PARSE(\"\(text)\")", containing: "Cannot parse", utc)
    }

    @Test func timesWithoutOffsetUseTheContextTimeZone() {
        expectDate(#"DATETIME_PARSE("2024-01-05 10:30")"#, TestDates.local("Australia/Sydney", 2024, 1, 5, 10, 30), sydney)
        expectDate(#"DATETIME_PARSE("2024-01-05 10:30Z")"#, TestDates.utc(2024, 1, 5, 10, 30), sydney)
        expectDisplay(#"DATETIME_PARSE("2024-07-01")"#, "2024-07-01", sydney)
    }

    @Test func daylightSavingGapsAndOverlaps() {
        // 02:30 does not exist on spring-forward day; it resolves forward to 03:30.
        expectText(#"DATETIME_FORMAT(DATETIME_PARSE("2024-03-10 02:30"), "HH:mm Z")"#, "03:30 -04:00", newYork)
        expectText(#"DATETIME_FORMAT(DATETIME_PARSE("2024-10-06 02:30"), "HH:mm Z")"#, "03:30 +11:00", sydney)
        // 01:30 happens twice on fall-back day; the earlier (daylight time) instant is used.
        expectText(#"DATETIME_FORMAT(DATETIME_PARSE("2024-11-03 01:30"), "HH:mm Z")"#, "01:30 -04:00", newYork)
        expectText(#"DATETIME_FORMAT(DATETIME_PARSE("2024-04-07 02:30"), "HH:mm Z")"#, "02:30 +11:00", sydney)
        expectText(#"DATETIME_FORMAT(DATETIME_PARSE("2024-11-03 03:30"), "HH:mm Z")"#, "03:30 -05:00", newYork)
    }

    @Test("Explicit formats", arguments: [
        ("05/01/2024", "DD/MM/YYYY", TestDates.utc(2024, 1, 5)),
        ("4 Sep 86 8:30 pm", "D MMM YY h:mm a", TestDates.utc(1986, 9, 4, 20, 30)),
        ("4 Sep 68", "D MMM YY", TestDates.utc(2068, 9, 4)),
        ("4 Sep 69", "D MMM YY", TestDates.utc(1969, 9, 4)),
        ("20240105", "YYYYMMDD", TestDates.utc(2024, 1, 5)),
        ("2024-01-05 10:30 +05:30", "YYYY-MM-DD HH:mm Z", TestDates.utc(2024, 1, 5, 5, 0)),
        ("2024-01-05 10:30 +0530", "YYYY-MM-DD HH:mm ZZ", TestDates.utc(2024, 1, 5, 5, 0)),
        ("2024", "YYYY", TestDates.utc(2024, 1, 1)),
        ("March 2024", "MMMM YYYY", TestDates.utc(2024, 3, 1)),
        ("Q3 2024", "[Q]Q YYYY", TestDates.utc(2024, 7, 1)),
        ("2024-01-05", "YYYY-MM-DD HH:mm", TestDates.utc(2024, 1, 5)),
        ("2024/01/05", "YYYY-MM-DD", TestDates.utc(2024, 1, 5)),
        ("2024-01-05 24:00", "YYYY-MM-DD HH:mm", TestDates.utc(2024, 1, 6)),
        ("Thursday 4th September 1986", "dddd Do MMMM YYYY", TestDates.utc(1986, 9, 4)),
        ("1986-247", "YYYY-DDDD", TestDates.utc(1986, 9, 4)),
        ("10:30:15.5", "HH:mm:ss.S", TestDates.utc(2024, 3, 15, 10, 30, 15, millisecond: 500)),
        ("09/04/1986", "L", TestDates.utc(1986, 9, 4)),
        ("September 4, 1986 8:30 PM", "LLL", TestDates.utc(1986, 9, 4, 20, 30)),
        ("1700000000", "X", Date(timeIntervalSince1970: 1_700_000_000)),
        ("1700000000.5", "X", Date(timeIntervalSince1970: 1_700_000_000.5)),
        ("1700000000123", "x", Date(timeIntervalSince1970: 1_700_000_000.123)),
    ])
    func explicitFormats(text: String, format: String, expected: Date) {
        expectDate("DATETIME_PARSE(\"\(text)\", \"\(format)\")", expected, utc)
    }

    @Test func missingDatePartsDefaultLikeMoment() {
        // Only a time: today's date (the context's "now" is 2024-03-15).
        expectDate(#"DATETIME_PARSE("10:30", "HH:mm")"#, TestDates.utc(2024, 3, 15, 10, 30), utc)
        expectDate(#"DATETIME_PARSE("12:00 AM", "hh:mm A")"#, TestDates.utc(2024, 3, 15), utc)
        // Only a day of month: this month and year.
        expectDate(#"DATETIME_PARSE("20", "D")"#, TestDates.utc(2024, 3, 20), utc)
    }

    @Test func explicitFormatFailures() {
        expectError(#"DATETIME_PARSE("05-01-2024 extra", "DD-MM-YYYY")"#, containing: "Cannot parse")
        expectError(#"DATETIME_PARSE("31/02/2024", "DD/MM/YYYY")"#, containing: "Cannot parse")
        expectError(#"DATETIME_PARSE("abc", "YYYY")"#, containing: "Cannot parse")
        expectError(#"DATETIME_PARSE("2024 10", "YYYY w")"#, containing: "week-based")
    }

    @Test func passThroughAndBlanks() {
        let context = TestContext(fields: ["D": .date(TestDates.utc(2024, 1, 5, 1, 2, 3)), "Blank": .blank])
        expectDate("DATETIME_PARSE({D})", TestDates.utc(2024, 1, 5, 1, 2, 3), context)
        expectDate(#"DATETIME_PARSE({D}, "YYYY")"#, TestDates.utc(2024, 1, 5, 1, 2, 3), context)
        expectValue("DATETIME_PARSE({Blank})", .blank, context)
        expectValue(#"DATETIME_PARSE("")"#, .blank, context)
        expectValue(#"DATETIME_PARSE("   ")"#, .blank, context)
        expectDate(#"DATETIME_PARSE(1700000000, "X")"#, Date(timeIntervalSince1970: 1_700_000_000), context)
        expectDate(#"DATETIME_PARSE("2024-01-05", "", "en")"#, TestDates.utc(2024, 1, 5), context)
    }

    @Test func formatThenParseRoundTrips() {
        let context = TestContext(fields: ["D": .date(TestDates.utc(1986, 9, 4, 20, 30))])
        for format in ["LLLL", "LLL", "lll", "YYYY-MM-DDTHH:mm:ssZ", "X", "x", "DD/MM/YYYY HH:mm", "Do MMMM YYYY h:mm a"] {
            expectDate(
                "DATETIME_PARSE(DATETIME_FORMAT({D}, \"\(format)\"), \"\(format)\")",
                TestDates.utc(1986, 9, 4, 20, 30),
                context
            )
        }
        expectDate(#"DATETIME_PARSE(DATETIME_FORMAT({D}, "LLLL"))"#, TestDates.utc(1986, 9, 4, 20, 30), context)
        expectDate("DATETIME_PARSE(DATETIME_FORMAT({D}))", TestDates.utc(1986, 9, 4, 20, 30), context)
    }
}
