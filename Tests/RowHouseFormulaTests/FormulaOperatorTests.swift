import Foundation
import Testing
import RowHouseFormula

@Suite("Operators and coercion")
struct FormulaOperatorTests {
    let context = TestContext(fields: [
        "Blank": .blank,
        "Empty": .text(""),
        "Num": .number(4),
        "NumText": .text("3"),
        "Word": .text("abc"),
        "Flag": .bool(true),
        "Day": .date(TestDates.utc(2024, 1, 5)),
        "Later": .date(TestDates.utc(2024, 1, 6)),
        "Moment": .date(TestDates.utc(2024, 1, 5, 10, 30)),
        "Single": .numbers(5),
        "Pair": .texts("a", "b"),
        "Numbers": .numbers(1, 2),
        "NoItems": .array([]),
        "Broken": .error(FormulaError("upstream failure")),
        "BrokenList": .array([.number(1), .error(FormulaError("inner failure"))]),
    ])

    @Test func arithmetic() {
        expectNumber("1 + 2", 3)
        expectNumber("7 - 10", -3)
        expectNumber("6 * 7", 42)
        expectNumber("7 / 2", 3.5)
        expectNumber("2 + 3 * 4", 14)
        expectNumber("(2 + 3) * 4", 20)
        expectNumber("-2 * -3", 6)
        expectNumber("10 / 4 * 2", 5)
        expectNumber("-(1 + 2)", -3)
        expectNumber(#"+"3""#, 3)
    }

    @Test func arithmeticCoercion() {
        expectNumber("{Blank} + 1", 1, context)
        expectNumber("{Empty} + 1", 1, context)
        expectNumber("{NumText} + 4", 7, context)
        expectNumber(#"" 2.5 " * 2"#, 5)
        expectNumber("TRUE() + 1", 2)
        expectNumber("{Flag} * 10", 10, context)
        expectNumber("FALSE() + 1", 1)
        expectError(#""abc" + 1"#, containing: #"Cannot convert "abc" to a number"#)
        expectError("{Word} * 2", containing: "Cannot convert", context)
    }

    @Test func divisionByZero() {
        expectError("1 / 0", containing: "Division by zero")
        expectError("1 / {Blank}", containing: "Division by zero", context)
        expectNumber("0 / 5", 0)
    }

    @Test func datesAreRejectedInArithmetic() {
        expectError("{Day} + 1", containing: "DATEADD", context)
        expectError("{Later} - {Day}", containing: "DATETIME_DIFF", context)
        expectError("-{Day}", containing: "DATEADD", context)
    }

    @Test func overflowIsAnError() {
        expectError("1e308 * 10", containing: "out of range")
        expectError("-1e308 - 1e308", containing: "out of range")
    }

    @Test func concatenation() {
        expectText(#""a" & 1"#, "a1")
        expectText(#"1.5 & """#, "1.5")
        expectText(#"(0.1 + 0.2) & """#, "0.3")
        expectText(#"{Blank} & "x""#, "x", context)
        expectText(#"TRUE() & """#, "TRUE")
        expectText(#"{Day} & """#, "2024-01-05", context)
        expectText(#"{Moment} & """#, "2024-01-05T10:30:00.000Z", context)
        expectText(#"{Pair} & "!""#, "a, b!", context)
        expectText(#"{Numbers} & """#, "1, 2", context)
        expectText("1 & 2 + 3", "15")
    }

    @Test func dateConcatenationUsesTheContextTimeZone() {
        let sydney = TestContext(fields: ["Day": .date(TestDates.local("Australia/Sydney", 2024, 1, 5))], timeZone: "Australia/Sydney")
        expectText(#"{Day} & """#, "2024-01-05", sydney)
        let utc = TestContext(fields: ["Day": .date(TestDates.local("Australia/Sydney", 2024, 1, 5))])
        expectText(#"{Day} & """#, "2024-01-04T13:00:00.000Z", utc)
    }

    @Test func numericComparisons() {
        expectBool("1 < 2", true)
        expectBool("2 <= 2", true)
        expectBool("3 > 2", true)
        expectBool("2 >= 3", false)
        expectBool("1 = 1.0", true)
        expectBool("1 != 2", true)
        expectBool("1 <> 1", false)
    }

    @Test func textComparisons() {
        expectBool(#""a" = "a""#, true)
        expectBool(#""a" = "A""#, false)
        expectBool(#""a" < "b""#, true)
        expectBool(#""b" > "a""#, true)
        expectBool(#""10" < "9""#, true)
    }

    @Test func mixedComparisons() {
        expectBool(#""10" = 10"#, true)
        expectBool(#""10" > 9"#, true)
        expectBool(#"9 < "10""#, true)
        expectBool(#""abc" = 1"#, false)
        expectBool("TRUE() = 1", true)
        expectBool("FALSE() = 0", true)
        expectBool("{Flag} = TRUE()", true, context)
        expectBool(#"TRUE() = "TRUE""#, true)
        expectBool(#"TRUE() = "1""#, true)
    }

    @Test func blankComparisons() {
        expectBool(#"{Blank} = """#, true, context)
        expectBool("{Blank} = 0", true, context)
        expectBool("{Blank} = BLANK()", true, context)
        expectBool("{Blank} = FALSE()", true, context)
        expectBool(#""" = 0"#, true)
        expectBool("{Empty} = BLANK()", true, context)
        expectBool("{Blank} != 1", true, context)
        expectBool("{Blank} < 1", true, context)
        expectBool(#"{Blank} = "x""#, false, context)
        expectBool("{Blank} = {Day}", false, context)
        expectBool("{Blank} != {Day}", true, context)
        expectBool("{NoItems} = BLANK()", true, context)
    }

    @Test func dateComparisons() {
        expectBool("{Day} < {Later}", true, context)
        expectBool("{Day} = {Day}", true, context)
        expectBool("{Later} >= {Day}", true, context)
        expectBool(#"{Day} = "2024-01-05""#, true, context)
        expectBool(#"{Day} < "January 6, 2024""#, true, context)
        expectBool(#"{Day} = "not a date""#, false, context)
        expectBool("{Day} = 5", false, context)
        expectBool("{Day} != 5", true, context)
        expectBool("{Day} < 5", false, context)
        expectBool("{Day} > 5", false, context)
    }

    @Test func arrayOperands() {
        expectNumber("{Single} + 1", 6, context)
        expectBool("{Single} = 5", true, context)
        expectError("{Numbers} + 1", containing: "list of 2 values", context)
        expectNumber("{NoItems} + 1", 1, context)
        expectBool(#"{Pair} = "a, b""#, true, context)
    }

    @Test func errorsPropagate() {
        expectError(#"ERROR("boom") + 1"#, containing: "boom")
        expectError(#"1 & ERROR("text")"#, containing: "text")
        expectError(#"ERROR("cmp") = 1"#, containing: "cmp")
        expectError(#"-ERROR("neg")"#, containing: "neg")
        expectError("{Missing}", containing: "Unknown field {Missing}")
        expectError("LEN({Missing})", containing: "Unknown field {Missing}")
        expectError("Missing + 1", containing: "Unknown field {Missing}")
        expectError("{Broken} = 1", containing: "upstream failure", context)
        expectError("{BrokenList} & \"\"", containing: "inner failure", context)
        expectError("UPPER({BrokenList})", containing: "inner failure", context)
    }

    @Test func variables() {
        let rollup = TestContext(variables: ["values": .numbers(1, 2, 3)])
        #expect(evaluate("SUM(values) * 2", rollup, variables: ["values"]) == .number(12))
        #expect(evaluate("values & \"\"", rollup, variables: ["values"]) == .text("1, 2, 3"))
        let missing = evaluate("values", TestContext(), variables: ["values"])
        #expect(missing == .error(FormulaError("Unknown variable values")))
    }

    @Test func fieldReferencesByIdOrName() {
        let byID = TestContext(fields: ["fldPrice123": .number(10)])
        expectNumber("{fldPrice123} * 2", 20, byID)
        expectNumber("fldPrice123 * 2", 20, byID)
    }

    @Test func manuallyBuiltExpressionsAreValidated() {
        let context = TestContext()
        #expect(FormulaEvaluator.evaluate(.call(name: "NOPE", args: []), in: context) == .error(FormulaError("Unknown function NOPE")))
        #expect(FormulaEvaluator.evaluate(.call(name: "LEN", args: []), in: context) == .error(FormulaError("LEN expects 1 argument")))
        #expect(FormulaEvaluator.evaluate(.call(name: "len", args: [.text("ab")]), in: context) == .number(2))
        #expect(FormulaEvaluator.evaluate(.binary(op: "^", .number(1), .number(2)), in: context) == .error(FormulaError("Unknown operator ^")))
        #expect(FormulaEvaluator.evaluate(.binary(op: "<>", .number(1), .number(2)), in: context) == .bool(true))
    }
}
