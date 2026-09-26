import Foundation
import Testing
import RowHouseFormula

@Suite("FormulaValue")
struct FormulaValueTests {
    let sydney = TimeZone(identifier: "Australia/Sydney")!
    let utc = TimeZone(identifier: "UTC")!

    @Test func isBlank() {
        #expect(FormulaValue.blank.isBlank)
        #expect(FormulaValue.text("").isBlank)
        #expect(FormulaValue.array([]).isBlank)
        #expect(FormulaValue.array([.blank, .text(""), .array([])]).isBlank)
        #expect(!FormulaValue.text(" ").isBlank)
        #expect(!FormulaValue.number(0).isBlank)
        #expect(!FormulaValue.bool(false).isBlank)
        #expect(!FormulaValue.array([.number(0)]).isBlank)
        #expect(!FormulaValue.error(FormulaError("x")).isBlank)
    }

    @Test func isTruthy() {
        #expect(!FormulaValue.blank.isTruthy)
        #expect(!FormulaValue.number(0).isTruthy)
        #expect(FormulaValue.number(-1).isTruthy)
        #expect(!FormulaValue.text("").isTruthy)
        #expect(FormulaValue.text("0").isTruthy)
        #expect(FormulaValue.text(" ").isTruthy)
        #expect(!FormulaValue.bool(false).isTruthy)
        #expect(FormulaValue.bool(true).isTruthy)
        #expect(FormulaValue.date(Date()).isTruthy)
        #expect(!FormulaValue.array([]).isTruthy)
        #expect(!FormulaValue.array([.number(0), .blank, .text("")]).isTruthy)
        #expect(FormulaValue.array([.number(0), .number(2)]).isTruthy)
        #expect(!FormulaValue.error(FormulaError("x")).isTruthy)
    }

    @Test func asNumber() {
        #expect(FormulaValue.number(3).asNumber == 3)
        #expect(FormulaValue.bool(true).asNumber == 1)
        #expect(FormulaValue.bool(false).asNumber == 0)
        #expect(FormulaValue.text(" 3.5 ").asNumber == 3.5)
        #expect(FormulaValue.text("-1e3").asNumber == -1000)
        #expect(FormulaValue.text(".5").asNumber == 0.5)
        #expect(FormulaValue.text("abc").asNumber == nil)
        #expect(FormulaValue.text("1,000").asNumber == nil)
        #expect(FormulaValue.text("inf").asNumber == nil)
        #expect(FormulaValue.text("nan").asNumber == nil)
        #expect(FormulaValue.text("0x10").asNumber == nil)
        #expect(FormulaValue.text("").asNumber == nil)
        #expect(FormulaValue.text("1e").asNumber == nil)
        #expect(FormulaValue.date(Date()).asNumber == nil)
        #expect(FormulaValue.blank.asNumber == nil)
        #expect(FormulaValue.array([.number(4)]).asNumber == 4)
        #expect(FormulaValue.numbers(1, 2).asNumber == nil)
        #expect(FormulaValue.error(FormulaError("x")).asNumber == nil)
    }

    @Test func asText() {
        #expect(FormulaValue.blank.asText == "")
        #expect(FormulaValue.number(3).asText == "3")
        #expect(FormulaValue.number(3.5).asText == "3.5")
        #expect(FormulaValue.text("hi").asText == "hi")
        #expect(FormulaValue.bool(true).asText == "TRUE")
        #expect(FormulaValue.date(TestDates.utc(2024, 1, 5)).asText == "2024-01-05")
        #expect(FormulaValue.date(TestDates.utc(2024, 1, 5, 10, 30, 0, millisecond: 250)).asText == "2024-01-05T10:30:00.250Z")
        #expect(FormulaValue.array([.text("a"), .number(1), .blank, .array([.bool(false)])]).asText == "a, 1, FALSE")
    }

    @Test("Number rendering", arguments: [
        (3.0, "3"), (3.5, "3.5"), (-3.5, "-3.5"), (0.1 + 0.2, "0.3"), (-0.0, "0"), (1.0 / 3.0, "0.333333333333333"),
        (123456789.123, "123456789.123"), (1e21, "1e+21"), (1e20, "100000000000000000000"), (1e-7, "1e-7"),
        (0.000001, "0.000001"), (9007199254740994, "9007199254740994"), (-1.5e-10, "-1.5e-10"), (2.5e25, "2.5e+25"),
        (1234.5, "1234.5"), (0.1, "0.1"),
    ])
    func numberDisplay(value: Double, expected: String) {
        #expect(FormulaValue.number(value).displayString(timeZone: utc) == expected)
    }

    @Test func dateDisplayUsesTimeZone() {
        let midnightSydney = TestDates.local("Australia/Sydney", 2024, 1, 5)
        #expect(FormulaValue.date(midnightSydney).displayString(timeZone: sydney) == "2024-01-05")
        #expect(FormulaValue.date(midnightSydney).displayString(timeZone: utc) == "2024-01-04 13:00")
        let afternoon = TestDates.utc(2024, 1, 5, 3, 30)
        #expect(FormulaValue.date(afternoon).displayString(timeZone: sydney) == "2024-01-05 14:30")
        #expect(FormulaValue.date(TestDates.utc(2024, 1, 5, 0, 0, 1)).displayString(timeZone: utc) == "2024-01-05 00:00")
    }

    @Test func otherDisplayStrings() {
        #expect(FormulaValue.blank.displayString(timeZone: utc) == "")
        #expect(FormulaValue.text("x").displayString(timeZone: utc) == "x")
        #expect(FormulaValue.bool(true).displayString(timeZone: utc) == "TRUE")
        #expect(FormulaValue.bool(false).displayString(timeZone: utc) == "FALSE")
        #expect(FormulaValue.error(FormulaError("boom")).displayString(timeZone: utc) == "#ERROR!")
        let nested = FormulaValue.array([.number(1), .array([.text("a"), .blank]), .bool(true)])
        #expect(nested.displayString(timeZone: utc) == "1, a, TRUE")
    }

    @Test func flattened() {
        #expect(FormulaValue.blank.flattened == [])
        #expect(FormulaValue.number(1).flattened == [.number(1)])
        let nested = FormulaValue.array([.number(1), .array([.number(2), .blank, .array([.text("x")])]), .blank])
        #expect(nested.flattened == [.number(1), .number(2), .text("x")])
    }

    @Test func formulaErrorDescription() {
        let error = FormulaError("Unknown field {Foo}")
        #expect(error.description == "Unknown field {Foo}")
        #expect(error.message == "Unknown field {Foo}")
    }
}
