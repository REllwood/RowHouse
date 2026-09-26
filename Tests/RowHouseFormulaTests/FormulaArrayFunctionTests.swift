import Foundation
import Testing
import RowHouseFormula

@Suite("Array functions")
struct FormulaArrayFunctionTests {
    let context = TestContext(fields: [
        "Letters": .texts("a", "b", "c", "d"),
        "Sparse": .array([.number(1), .blank, .text(""), .text("a"), .number(0), .array([])]),
        "Nested": .array([.number(1), .array([.number(2), .array([.number(3)])]), .blank]),
        "Repeats": .array([.number(1), .number(2), .number(1), .text("a"), .text("a"), .number(2), .text("1")]),
        "Dates": .array([.date(TestDates.utc(2024, 1, 5)), .date(TestDates.utc(2024, 1, 6, 12))]),
        "Blank": .blank,
    ])

    @Test func arrayCompact() {
        expectValue("ARRAYCOMPACT({Sparse})", .array([.number(1), .text("a"), .number(0)]), context)
        expectValue("ARRAYCOMPACT({Blank})", .array([]), context)
        expectValue(#"ARRAYCOMPACT("x")"#, .texts("x"))
    }

    @Test func arrayFlatten() {
        expectValue("ARRAYFLATTEN({Nested})", .array([.number(1), .number(2), .number(3), .blank]), context)
        expectValue("ARRAYFLATTEN({Letters})", .texts("a", "b", "c", "d"), context)
        expectValue("ARRAYFLATTEN(5)", .numbers(5))
    }

    @Test func arrayJoin() {
        expectText("ARRAYJOIN({Letters})", "a, b, c, d", context)
        expectText(#"ARRAYJOIN({Letters}, "; ")"#, "a; b; c; d", context)
        expectText(#"ARRAYJOIN({Letters}, "")"#, "abcd", context)
        expectText(#"ARRAYJOIN({Nested}, "|")"#, "1|2|3|", context)
        expectText(#"ARRAYJOIN(ARRAYCOMPACT({Sparse}), "-")"#, "1-a-0", context)
        expectText(#"ARRAYJOIN({Dates}, " / ")"#, "2024-01-05 / 2024-01-06T12:00:00.000Z", context)
        expectText(#"ARRAYJOIN("solo")"#, "solo")
        expectText("ARRAYJOIN({Blank})", "", context)
    }

    @Test func arrayUnique() {
        expectValue("ARRAYUNIQUE({Repeats})", .array([.number(1), .number(2), .text("a"), .text("1")]), context)
        expectValue("ARRAYUNIQUE({Letters})", .texts("a", "b", "c", "d"), context)
    }

    @Test func arraySlice() {
        expectValue("ARRAYSLICE({Letters}, 2, 3)", .texts("b", "c"), context)
        expectValue("ARRAYSLICE({Letters}, 2)", .texts("b", "c", "d"), context)
        expectValue("ARRAYSLICE({Letters}, -2)", .texts("c", "d"), context)
        expectValue("ARRAYSLICE({Letters}, 1, -2)", .texts("a", "b", "c"), context)
        expectValue("ARRAYSLICE({Letters}, 0, 1)", .texts("a"), context)
        expectValue("ARRAYSLICE({Letters}, 3, 99)", .texts("c", "d"), context)
        expectValue("ARRAYSLICE({Letters}, 5)", .array([]), context)
        expectValue("ARRAYSLICE({Letters}, 3, 2)", .array([]), context)
        expectValue("ARRAYSLICE({Letters}, -10, 1)", .texts("a"), context)
    }

    @Test func arraysFlowThroughScalarFunctions() {
        expectText("UPPER({Letters})", "A, B, C, D", context)
        expectNumber("LEN({Letters})", 10, context)
        expectNumber("COUNTA(ARRAYCOMPACT({Sparse}))", 3, context)
        expectNumber("SUM(ARRAYUNIQUE({Repeats}))", 4, context)
        expectText("ARRAYJOIN(ARRAYSLICE(ARRAYUNIQUE({Repeats}), 1, 2))", "1, 2", context)
    }

    @Test func arrayResultsDisplay() {
        let value = evaluate("ARRAYCOMPACT({Sparse})", context)
        #expect(value.displayString(timeZone: context.timeZone) == "1, a, 0")
    }
}
