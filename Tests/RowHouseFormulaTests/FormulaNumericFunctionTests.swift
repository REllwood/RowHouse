import Foundation
import Testing
import RowHouseFormula

@Suite("Numeric functions")
struct FormulaNumericFunctionTests {
    let context = TestContext(fields: [
        "Mixed": .array([.number(1), .number(2), .text("3"), .text("x"), .blank, .bool(true)]),
        "Pair": .numbers(2, 4),
        "Big": .numbers(1, 9),
        "Nested": .array([.number(1), .array([.number(2), .array([.number(3)])])]),
        "Dates": .array([.date(TestDates.utc(2024, 5, 1)), .date(TestDates.utc(2023, 1, 1)), .date(TestDates.utc(2024, 2, 1))]),
        "Counted": .array([.number(1), .blank, .text("x"), .text(""), .number(2)]),
        "NoItems": .array([]),
    ])

    @Test func abs() {
        expectNumber("ABS(-3)", 3)
        expectNumber("ABS(2.5)", 2.5)
        expectNumber(#"ABS("-2")"#, 2)
        expectNumber("ABS(BLANK())", 0)
        expectError(#"ABS("x")"#, containing: "Cannot convert")
    }

    @Test func sum() {
        expectNumber("SUM(1, 2, 3)", 6)
        expectNumber("SUM({Mixed})", 7, context)
        expectNumber("SUM({Nested}, 4)", 10, context)
        expectNumber("SUM(BLANK())", 0)
        expectNumber("SUM({NoItems})", 0, context)
        expectDisplay("SUM(0.1, 0.2)", "0.3")
        expectError(#"SUM(1, ERROR("bad"))"#, containing: "bad")
    }

    @Test func average() {
        expectNumber("AVERAGE(1, 2, 3, 4)", 2.5)
        expectNumber("AVERAGE({Pair}, 6)", 4, context)
        expectNumber("AVERAGE(1, BLANK())", 1)
        expectValue("AVERAGE(BLANK())", .blank)
        expectValue("AVERAGE({NoItems})", .blank, context)
    }

    @Test func maxMin() {
        expectNumber("MAX(1, 5, 3)", 5)
        expectNumber("MIN(1, 5, -3)", -3)
        expectNumber("MAX({Big}, 4)", 9, context)
        expectNumber("MIN({Big}, 4)", 1, context)
        expectNumber(#"MAX("10", 9)"#, 10)
        expectValue("MAX(BLANK())", .blank)
        expectValue("MIN({NoItems})", .blank, context)
        expectDate("MAX({Dates})", TestDates.utc(2024, 5, 1), context)
        expectDate("MIN({Dates})", TestDates.utc(2023, 1, 1), context)
    }

    @Test func counts() {
        expectNumber(#"COUNT(1, "2", "a", BLANK(), TRUE(), 3.5)"#, 2)
        expectNumber("COUNT({Counted})", 2, context)
        expectNumber(#"COUNTA(1, "", BLANK(), "a", 0)"#, 3)
        expectNumber("COUNTA({Counted})", 3, context)
        expectNumber(#"COUNTALL(1, "", BLANK(), "a")"#, 4)
        expectNumber("COUNTALL({Counted})", 5, context)
        expectNumber("COUNTALL({NoItems})", 0, context)
    }

    @Test func ceilingAndFloor() {
        expectNumber("CEILING(2.1)", 3)
        expectNumber("CEILING(2.5, 2)", 4)
        expectNumber("CEILING(-2.5, 1)", -2)
        expectNumber("CEILING(1.1, 0.1)", 1.1)
        expectNumber("CEILING(0.25, 0.1)", 0.3)
        expectNumber("CEILING(12, 5)", 15)
        expectNumber("CEILING(5, 0)", 0)
        expectNumber("CEILING(7, -2)", 8)
        expectNumber("FLOOR(2.9)", 2)
        expectNumber("FLOOR(7, 5)", 5)
        expectNumber("FLOOR(-2.5)", -3)
        expectNumber("FLOOR(1.3, 0.1)", 1.3)
        expectNumber("FLOOR(0.7, 0.1)", 0.7)
    }

    @Test func evenAndOdd() {
        expectNumber("EVEN(1.5)", 2)
        expectNumber("EVEN(3)", 4)
        expectNumber("EVEN(2)", 2)
        expectNumber("EVEN(-1)", -2)
        expectNumber("EVEN(0)", 0)
        expectNumber("ODD(1.5)", 3)
        expectNumber("ODD(2)", 3)
        expectNumber("ODD(1)", 1)
        expectNumber("ODD(0)", 1)
        expectNumber("ODD(-2)", -3)
    }

    @Test func expIntLog() {
        expectNumber("EXP(0)", 1)
        expectNumber("EXP(1)", 2.718281828459045, accuracy: 1e-12)
        expectNumber("INT(2.7)", 2)
        expectNumber("INT(-2.3)", -3)
        expectNumber("LOG(100)", 2)
        expectNumber("LOG(1000)", 3)
        expectNumber("LOG(8, 2)", 3)
        expectNumber("LOG(125, 5)", 3)
        expectNumber("LOG(1)", 0)
        expectError("LOG(0)", containing: "positive")
        expectError("LOG(-1)", containing: "positive")
        expectError("LOG(10, 1)", containing: "base")
    }

    @Test func mod() {
        expectNumber("MOD(7, 3)", 1)
        expectNumber("MOD(-7, 3)", -1)
        expectNumber("MOD(7, -3)", 1)
        expectNumber("MOD(7.5, 2)", 1.5)
        expectNumber("MOD(6, 3)", 0)
        expectError("MOD(1, 0)", containing: "Division by zero")
    }

    @Test func powerAndSqrt() {
        expectNumber("POWER(2, 10)", 1024)
        expectNumber("POWER(4, 0.5)", 2)
        expectNumber("POWER(2, -1)", 0.5)
        expectError("POWER(-8, 1/3)", containing: "not a real number")
        expectError("POWER(10, 400)", containing: "out of range")
        expectNumber("SQRT(16)", 4)
        expectNumber("SQRT(0)", 0)
        expectError("SQRT(-1)", containing: "SQRT")
    }

    @Test("ROUND rounds half away from zero", arguments: [
        ("ROUND(2.5)", 3.0), ("ROUND(-2.5)", -3), ("ROUND(2.4)", 2), ("ROUND(1.005, 2)", 1.01),
        ("ROUND(2.345, 2)", 2.35), ("ROUND(3.14159, 3)", 3.142), ("ROUND(1234.5678, -2)", 1200),
        ("ROUND(1250, -2)", 1300), ("ROUND(-1250, -2)", -1300), ("ROUND(0.285, 2)", 0.29), ("ROUND(5, 2)", 5),
        ("ROUND(1.5, BLANK())", 2),
    ])
    func round(source: String, expected: Double) {
        expectNumber(source, expected)
    }

    @Test("ROUNDUP rounds away from zero", arguments: [
        ("ROUNDUP(3.2)", 4.0), ("ROUNDUP(-3.2)", -4), ("ROUNDUP(1.1, 1)", 1.1), ("ROUNDUP(3.14159, 2)", 3.15),
        ("ROUNDUP(1234, -2)", 1300), ("ROUNDUP(0.1 + 0.2, 1)", 0.3), ("ROUNDUP(5)", 5),
    ])
    func roundUp(source: String, expected: Double) {
        expectNumber(source, expected)
    }

    @Test("ROUNDDOWN rounds toward zero", arguments: [
        ("ROUNDDOWN(3.9)", 3.0), ("ROUNDDOWN(-3.9)", -3), ("ROUNDDOWN(2.3, 1)", 2.3), ("ROUNDDOWN(3.14159, 3)", 3.141),
        ("ROUNDDOWN(1299, -2)", 1200), ("ROUNDDOWN(4.35, 2)", 4.35),
    ])
    func roundDown(source: String, expected: Double) {
        expectNumber(source, expected)
    }

    @Test func value() {
        expectNumber(#"VALUE("$1,234.50")"#, 1234.5)
        expectNumber(#"VALUE("12%")"#, 0.12)
        expectNumber(#"VALUE(" 42 ")"#, 42)
        expectNumber(#"VALUE("(1,000)")"#, -1000)
        expectNumber(#"VALUE("€ 5")"#, 5)
        expectNumber(#"VALUE("-$3")"#, -3)
        expectNumber(#"VALUE("1e3")"#, 1000)
        expectNumber(#"VALUE("£1 000.25")"#, 1000.25)
        expectNumber("VALUE(7)", 7)
        expectNumber("VALUE(TRUE())", 1)
        expectValue(#"VALUE("")"#, .blank)
        expectError(#"VALUE("abc")"#, containing: #"Cannot convert "abc""#)
        expectError(#"VALUE("1.2.3")"#, containing: "Cannot convert")
        expectError(#"VALUE(DATETIME_PARSE("2024-01-01"))"#, containing: "date")
    }
}
