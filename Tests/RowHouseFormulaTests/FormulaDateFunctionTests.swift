import Foundation
import Testing
import RowHouseFormula

@Suite("Date functions")
struct FormulaDateFunctionTests {
    let utc = TestContext(fields: [
        "Blank": .blank,
        "Day": .date(TestDates.utc(2024, 1, 5)),
        "Moment": .date(TestDates.utc(2024, 2, 29, 13, 45, 30)),
        "Holidays": .array([.date(TestDates.utc(2024, 12, 25)), .text("2024-12-26")]),
        "Pair": .array([.date(TestDates.utc(2024, 1, 5)), .date(TestDates.utc(2024, 1, 6))]),
    ])
    let sydney = TestContext(timeZone: "Australia/Sydney")
    let newYork = TestContext(timeZone: "America/New_York")

    @Test func nowAndToday() {
        expectDate("NOW()", TestDates.utc(2024, 3, 15, 10, 30))
        expectDate("TODAY()", TestDates.utc(2024, 3, 15))
        expectDisplay("TODAY()", "2024-03-15")
        // 10:30 UTC is 21:30 in Sydney (AEDT) and 06:30 in New York (EDT).
        expectDate("TODAY()", TestDates.local("Australia/Sydney", 2024, 3, 15), sydney)
        expectDate("TODAY()", TestDates.utc(2024, 3, 15, 4), newYork)
        let lateUTC = TestContext(timeZone: "Australia/Sydney", now: TestDates.utc(2024, 3, 15, 14))
        expectDisplay("TODAY()", "2024-03-16", lateUTC)
    }

    @Test func dateAddUnits() {
        expectDisplay(#"DATEADD("2024-01-31", 1, "months")"#, "2024-02-29")
        expectDisplay(#"DATEADD("2024-01-31", 1, "M")"#, "2024-02-29")
        expectDisplay(#"DATEADD("2024-01-01", 90, "m")"#, "2024-01-01 01:30")
        expectDisplay(#"DATEADD("2024-01-01", 90, "minutes")"#, "2024-01-01 01:30")
        expectDisplay(#"DATEADD("2024-01-01", 2, "weeks")"#, "2024-01-15")
        expectDisplay(#"DATEADD("2024-01-01", 2, "w")"#, "2024-01-15")
        expectDisplay(#"DATEADD("2024-02-29", 1, "years")"#, "2025-02-28")
        expectDisplay(#"DATEADD("2024-02-29", 4, "y")"#, "2028-02-29")
        expectDisplay(#"DATEADD("2024-01-15", 1, "quarters")"#, "2024-04-15")
        expectDisplay(#"DATEADD("2024-01-15", 1, "Q")"#, "2024-04-15")
        expectDisplay(#"DATEADD("2024-03-01", -1, "days")"#, "2024-02-29")
        expectDisplay(#"DATEADD("2024-03-01", 1, "d")"#, "2024-03-02")
        expectDisplay(#"DATEADD("2024-03-01", 1, "DAYS")"#, "2024-03-02")
        expectDisplay(#"DATEADD("2024-01-01", 36, "h")"#, "2024-01-02 12:00")
        expectDisplay(#"DATEADD("2024-01-01", 3600, "s")"#, "2024-01-01 01:00")
        expectText(#"DATETIME_FORMAT(DATEADD("2024-01-01", 1500, "ms"), "ss.SSS")"#, "01.500")
        expectText(#"DATETIME_FORMAT(DATEADD("2024-01-01", 1, "milliseconds"), "ss.SSS")"#, "00.001")
        expectDisplay(#"DATEADD("2024-01-01", 1.5, "days")"#, "2024-01-03")
        expectDisplay(#"DATEADD("2024-01-01", 1.5, "years")"#, "2025-07-01")
        expectDisplay(#"DATEADD("2024-12-31", 2, "months")"#, "2025-02-28")
        expectDisplay(#"DATEADD({Day}, "3", "days")"#, "2024-01-08", utc)
    }

    @Test func dateAddErrorsAndBlanks() {
        expectError(#"DATEADD("2024-01-01", 1, "fortnights")"#, containing: #"Unknown date unit "fortnights""#)
        expectError(#"DATEADD("2024-01-01", 1e12, "years")"#, containing: "out of range")
        expectError(#"DATEADD("not a date", 1, "days")"#, containing: "Cannot interpret")
        expectError(#"DATEADD(5, 1, "days")"#, containing: "Expected a date")
        expectValue(#"DATEADD({Blank}, 1, "days")"#, .blank, utc)
    }

    @Test func dateAddAcrossDaylightSavingInSydney() {
        let springForward = TestContext(fields: [
            "Start": .date(TestDates.local("Australia/Sydney", 2024, 10, 5, 10)),
        ], timeZone: "Australia/Sydney")
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 1, "days"), "YYYY-MM-DD HH:mm Z")"#, "2024-10-06 10:00 +11:00", springForward)
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 24, "hours"), "YYYY-MM-DD HH:mm Z")"#, "2024-10-06 11:00 +11:00", springForward)

        let fallBack = TestContext(fields: [
            "Start": .date(TestDates.local("Australia/Sydney", 2024, 4, 6, 10)),
        ], timeZone: "Australia/Sydney")
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 1, "days"), "YYYY-MM-DD HH:mm Z")"#, "2024-04-07 10:00 +10:00", fallBack)
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 24, "hours"), "YYYY-MM-DD HH:mm Z")"#, "2024-04-07 09:00 +10:00", fallBack)
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 1, "months"), "YYYY-MM-DD HH:mm Z")"#, "2024-05-06 10:00 +10:00", fallBack)
    }

    @Test func dateAddAcrossDaylightSavingInNewYork() {
        let context = TestContext(fields: [
            "Start": .date(TestDates.local("America/New_York", 2024, 3, 9, 12)),
        ], timeZone: "America/New_York")
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 1, "days"), "YYYY-MM-DD HH:mm Z")"#, "2024-03-10 12:00 -04:00", context)
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 24, "hours"), "YYYY-MM-DD HH:mm Z")"#, "2024-03-10 13:00 -04:00", context)
        expectText(#"DATETIME_FORMAT(DATEADD({Start}, 1, "weeks"), "YYYY-MM-DD HH:mm Z")"#, "2024-03-16 12:00 -04:00", context)
    }

    @Test func dateTimeDiffUnits() {
        expectNumber(#"DATETIME_DIFF("2024-01-10", "2024-01-01", "days")"#, 9)
        expectNumber(#"DATETIME_DIFF("2024-01-01", "2024-01-10", "days")"#, -9)
        expectNumber(#"DATETIME_DIFF("2024-01-01 00:01", "2024-01-01")"#, 60)
        expectNumber(#"DATETIME_DIFF("2024-01-01 10:59", "2024-01-01 10:00", "hours")"#, 0)
        expectNumber(#"DATETIME_DIFF("2024-01-01 10:59", "2024-01-01 10:00", "minutes")"#, 59)
        expectNumber(#"DATETIME_DIFF("2024-01-01 10:59", "2024-01-01 10:00", "m")"#, 59)
        expectNumber(#"DATETIME_DIFF("2024-01-01 00:00:01", "2024-01-01", "ms")"#, 1000)
        expectNumber(#"DATETIME_DIFF("2024-01-15", "2024-01-01", "weeks")"#, 2)
        expectNumber(#"DATETIME_DIFF("2024-01-14", "2024-01-01", "weeks")"#, 1)
        expectNumber(#"DATETIME_DIFF("2024-01-02 06:00", "2024-01-01 12:00", "days")"#, 0)
        expectNumber(#"DATETIME_DIFF("2024-01-01", "2024-01-02 06:00", "days")"#, -1)
    }

    @Test func dateTimeDiffCalendarUnits() {
        expectNumber(#"DATETIME_DIFF("2024-03-31", "2024-02-29", "months")"#, 1)
        expectNumber(#"DATETIME_DIFF("2024-02-29", "2024-01-31", "months")"#, 0)
        expectNumber(#"DATETIME_DIFF("2024-03-01", "2024-01-31", "M")"#, 1)
        expectNumber(#"DATETIME_DIFF("2024-01-01", "2024-03-15", "months")"#, -2)
        expectNumber(#"DATETIME_DIFF("2024-07-01", "2024-01-01", "quarters")"#, 2)
        expectNumber(#"DATETIME_DIFF("2024-12-31", "2024-01-01", "years")"#, 0)
        expectNumber(#"DATETIME_DIFF("2025-01-01", "2024-01-01", "years")"#, 1)
        expectNumber(#"DATETIME_DIFF("2000-06-15", "2024-06-14", "y")"#, -23)
    }

    @Test func dateTimeDiffAcrossDaylightSaving() {
        // Sydney springs forward at 02:00 on 6 October and falls back at 03:00 on 7 April 2024.
        expectNumber(#"DATETIME_DIFF("2024-10-07", "2024-10-06", "days")"#, 1, sydney)
        expectNumber(#"DATETIME_DIFF("2024-10-07", "2024-10-06", "hours")"#, 23, sydney)
        expectNumber(#"DATETIME_DIFF("2024-10-06", "2024-10-05", "hours")"#, 24, sydney)
        expectNumber(#"DATETIME_DIFF("2024-04-08", "2024-04-07", "hours")"#, 25, sydney)
        expectNumber(#"DATETIME_DIFF("2024-04-08", "2024-04-07", "days")"#, 1, sydney)
        expectNumber(#"DATETIME_DIFF("2024-04-08 00:30", "2024-04-07 01:00", "days")"#, 0, sydney)
        // New York springs forward on 10 March and falls back on 3 November 2024.
        expectNumber(#"DATETIME_DIFF("2024-11-04", "2024-11-03", "hours")"#, 25, newYork)
        expectNumber(#"DATETIME_DIFF("2024-11-04", "2024-11-03", "days")"#, 1, newYork)
        expectNumber(#"DATETIME_DIFF("2024-03-11", "2024-03-10", "hours")"#, 23, newYork)
        expectNumber(#"DATETIME_DIFF("2024-03-17", "2024-03-10", "weeks")"#, 1, newYork)
    }

    @Test func dateTimeDiffBlanksAndErrors() {
        expectValue(#"DATETIME_DIFF({Blank}, "2024-01-01")"#, .blank, utc)
        expectError(#"DATETIME_DIFF("2024-01-01", "2024-01-01", "eons")"#, containing: "Unknown date unit")
        expectError(#"DATETIME_DIFF({Pair}, "2024-01-01")"#, containing: "single date", utc)
    }

    @Test func dateParts() {
        expectNumber("YEAR({Moment})", 2024, utc)
        expectNumber("MONTH({Moment})", 2, utc)
        expectNumber("DAY({Moment})", 29, utc)
        expectNumber("HOUR({Moment})", 13, utc)
        expectNumber("MINUTE({Moment})", 45, utc)
        expectNumber("SECOND({Moment})", 30, utc)
        let moment = TestContext(fields: ["Moment": .date(TestDates.utc(2024, 2, 29, 13, 45, 30))], timeZone: "America/New_York")
        expectNumber("HOUR({Moment})", 8, moment)
        let lateMoment = TestContext(fields: ["Moment": .date(TestDates.utc(2024, 2, 29, 13, 45, 30))], timeZone: "Australia/Sydney")
        expectNumber("DAY({Moment})", 1, lateMoment)
        expectNumber("MONTH({Moment})", 3, lateMoment)
        let kolkata = TestContext(fields: ["Moment": .date(TestDates.utc(2024, 1, 5, 10, 0, 15))], timeZone: "Asia/Kolkata")
        expectNumber("HOUR({Moment})", 15, kolkata)
        expectNumber("MINUTE({Moment})", 30, kolkata)
        expectNumber("SECOND({Moment})", 15, kolkata)
        expectNumber(#"YEAR("January 5, 2024")"#, 2024)
        expectValue("YEAR({Blank})", .blank, utc)
        expectError("YEAR(5)", containing: "Expected a date")
    }

    @Test func dateStrAndTimeStr() {
        expectText(#"DATESTR("2024-01-05T23:30:00Z")"#, "2024-01-06", sydney)
        expectText(#"TIMESTR("2024-01-05T23:30:00Z")"#, "10:30:00", sydney)
        expectText("DATESTR({Moment})", "2024-02-29", utc)
        expectText("TIMESTR({Moment})", "13:45:30", utc)
    }

    @Test func weekday() {
        expectNumber(#"WEEKDAY("2024-03-15")"#, 5)
        expectNumber(#"WEEKDAY("2024-03-17")"#, 0)
        expectNumber(#"WEEKDAY("2024-03-17", "Monday")"#, 6)
        expectNumber(#"WEEKDAY("2024-03-18", "monday")"#, 0)
        expectNumber(#"WEEKDAY("2024-03-18", "Sunday")"#, 1)
        expectError(#"WEEKDAY("2024-03-18", "Tuesday")"#, containing: "WEEKDAY start day")
    }

    @Test func weekNumber() {
        expectNumber(#"WEEKNUM("2024-01-01")"#, 1)
        expectNumber(#"WEEKNUM("2024-01-06")"#, 1)
        expectNumber(#"WEEKNUM("2024-01-07")"#, 2)
        expectNumber(#"WEEKNUM("2024-01-07", "Monday")"#, 1)
        expectNumber(#"WEEKNUM("2024-01-08", "Monday")"#, 2)
        expectNumber(#"WEEKNUM("2024-12-31")"#, 53)
        expectNumber(#"WEEKNUM("2023-01-01")"#, 1)
    }

    @Test func beforeAfterSame() {
        expectBool(#"IS_BEFORE("2024-01-01", "2024-01-02")"#, true)
        expectBool(#"IS_BEFORE("2024-01-02", "2024-01-01")"#, false)
        expectBool(#"IS_AFTER("2024-01-02", "2024-01-01")"#, true)
        expectBool(#"IS_AFTER("2024-01-01", "2024-01-01")"#, false)
        expectValue(#"IS_BEFORE({Blank}, "2024-01-01")"#, .blank, utc)

        expectBool(#"IS_SAME("2024-01-05", "2024-01-05T00:00:00Z")"#, true)
        expectBool(#"IS_SAME("2024-01-05", "2024-01-05 00:00:01")"#, false)
        expectBool(#"IS_SAME("2024-01-05 10:00", "2024-01-05 23:00", "day")"#, true)
        expectBool(#"IS_SAME("2024-01-05", "2024-01-06", "day")"#, false)
        expectBool(#"IS_SAME("2024-01-05", "2024-01-28", "month")"#, true)
        expectBool(#"IS_SAME("2024-01-05", "2024-02-01", "month")"#, false)
        expectBool(#"IS_SAME("2024-01-05", "2024-12-31", "year")"#, true)
        expectBool(#"IS_SAME("2024-01-05", "2024-03-31", "quarter")"#, true)
        expectBool(#"IS_SAME("2024-03-31", "2024-04-01", "quarter")"#, false)
        expectBool(#"IS_SAME("2024-03-17", "2024-03-23", "week")"#, true)
        expectBool(#"IS_SAME("2024-03-16", "2024-03-17", "week")"#, false)
        expectBool(#"IS_SAME("2024-01-05 10:05", "2024-01-05 10:55", "hour")"#, true)
        expectBool(#"IS_SAME("2024-01-05 10:05", "2024-01-05 10:55", "minute")"#, false)
        expectBool(#"IS_SAME("2024-01-05T12:00:00Z", "2024-01-05T14:00:00Z", "day")"#, false, sydney)
        expectBool(#"IS_SAME("2024-01-05T12:00:00Z", "2024-01-05T14:00:00Z", "day")"#, true)
    }

    @Test func workday() {
        expectDisplay(#"WORKDAY("2024-03-15", 1)"#, "2024-03-18")
        expectDisplay(#"WORKDAY("2024-03-15", 5)"#, "2024-03-22")
        expectDisplay(#"WORKDAY("2024-03-15", 10)"#, "2024-03-29")
        expectDisplay(#"WORKDAY("2024-03-16", 1)"#, "2024-03-18")
        expectDisplay(#"WORKDAY("2024-03-16", 5)"#, "2024-03-22")
        expectDisplay(#"WORKDAY("2024-03-18", -1)"#, "2024-03-15")
        expectDisplay(#"WORKDAY("2024-03-17", -5)"#, "2024-03-11")
        expectDisplay(#"WORKDAY("2024-03-15", 0)"#, "2024-03-15")
        expectDisplay(#"WORKDAY("2024-01-01", 260)"#, "2024-12-30")
        expectDisplay(#"WORKDAY("2024-03-15T15:00:00Z", 1)"#, "2024-03-18")
    }

    @Test func workdayWithHolidays() {
        expectDisplay(#"WORKDAY("2024-03-15", 1, "2024-03-18")"#, "2024-03-19")
        expectDisplay(#"WORKDAY("2024-12-20", 3, "2024-12-25, 2024-12-26")"#, "2024-12-27")
        expectDisplay(#"WORKDAY("2024-12-27", -3, "2024-12-25, 2024-12-26")"#, "2024-12-20")
        expectDisplay(#"WORKDAY("2024-12-20", 3, {Holidays})"#, "2024-12-27", utc)
        expectDisplay(#"WORKDAY("2024-03-15", 1, "2024-03-16")"#, "2024-03-18")
        expectDisplay(#"WORKDAY("2024-03-15", 2, "2024-03-18, 2024-03-19, 2024-03-20")"#, "2024-03-22")
        expectError(#"WORKDAY("2024-03-15", 1, "someday")"#, containing: "holiday")
        expectError(#"WORKDAY("2024-03-15", 1e9)"#, containing: "out of range")
    }

    @Test func workdayDiff() {
        expectNumber(#"WORKDAY_DIFF("2024-03-11", "2024-03-15")"#, 5)
        expectNumber(#"WORKDAY_DIFF("2024-03-11", "2024-03-17")"#, 5)
        expectNumber(#"WORKDAY_DIFF("2024-03-11", "2024-03-18")"#, 6)
        expectNumber(#"WORKDAY_DIFF("2024-03-15", "2024-03-11")"#, -5)
        expectNumber(#"WORKDAY_DIFF("2024-03-11", "2024-03-15", "2024-03-13")"#, 4)
        expectNumber(#"WORKDAY_DIFF("2024-03-11", "2024-03-15", "2024-03-16")"#, 5)
        expectNumber(#"WORKDAY_DIFF("2024-03-13", "2024-03-13")"#, 1)
        expectNumber(#"WORKDAY_DIFF("2024-03-16", "2024-03-16")"#, 0)
        expectNumber(#"WORKDAY_DIFF("2024-01-01", "2024-12-31")"#, 262)
        expectNumber(#"WORKDAY_DIFF("2024-12-23", "2024-12-27", {Holidays})"#, 3, utc)
    }

    @Test func toNowAndFromNow() {
        expectNumber(#"TONOW("2024-03-10")"#, 5)
        expectNumber(#"FROMNOW("2024-03-20")"#, 4)
        expectNumber(#"TONOW("2024-03-20")"#, 4)
        expectNumber(#"FROMNOW("2024-03-15 09:00")"#, 0)
        expectValue("TONOW({Blank})", .blank, utc)
    }

    @Test func setTimeZoneAndLocaleAreAcceptedForCompatibility() {
        expectDate(#"SET_TIMEZONE({Day}, "Australia/Sydney")"#, TestDates.utc(2024, 1, 5), utc)
        expectError(#"SET_TIMEZONE({Day}, "Mars/Olympus")"#, containing: "Unknown time zone", utc)
        expectDate(#"SET_LOCALE({Day}, "fr")"#, TestDates.utc(2024, 1, 5), utc)
        expectValue(#"SET_LOCALE({Blank}, "fr")"#, .blank, utc)
    }
}

@Suite("Record functions")
struct FormulaRecordFunctionTests {
    @Test func recordMetadata() {
        let context = TestContext()
        expectText("RECORD_ID()", "rec123", context)
        expectDate("CREATED_TIME()", TestDates.utc(2024, 1, 2, 3, 4, 5), context)
        expectDate("LAST_MODIFIED_TIME()", TestDates.utc(2024, 2, 3, 4, 5, 6), context)
        expectNumber(#"DATETIME_DIFF(LAST_MODIFIED_TIME(), CREATED_TIME(), "days")"#, 32, context)
        expectText(#""https://example.com/" & RECORD_ID()"#, "https://example.com/rec123", context)
    }
}
