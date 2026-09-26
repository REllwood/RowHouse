import Foundation
import Testing
import RowHouseFormula

@Suite("Logical functions")
struct FormulaLogicalFunctionTests {
    let context = TestContext(fields: [
        "Blank": .blank,
        "Zeroes": .numbers(0, 0),
        "Mixed": .numbers(0, 1),
        "Ones": .numbers(1, 1),
        "OneZero": .numbers(0),
        "NoItems": .array([]),
        "Status": .text("Done"),
    ])

    @Test func ifChoosesBranch() {
        expectNumber("IF(TRUE, 1, 2)", 1)
        expectNumber("IF(0, 1, 2)", 2)
        expectNumber(#"IF("", 1, 2)"#, 2)
        expectNumber(#"IF("x", 1, 2)"#, 1)
        expectNumber("IF({Blank}, 1, 2)", 2, context)
        expectValue("IF(FALSE, 1)", .blank)
        expectText(#"if({Status} = "Done", "✓", "…")"#, "✓", context)
    }

    @Test func ifTreatsArraysByTheirElements() {
        expectNumber("IF({Zeroes}, 1, 2)", 2, context)
        expectNumber("IF({Mixed}, 1, 2)", 1, context)
        expectNumber("IF({OneZero}, 1, 2)", 2, context)
        expectNumber("IF({NoItems}, 1, 2)", 2, context)
    }

    @Test func ifIsLazy() {
        expectNumber("IF(FALSE, 1/0, 2)", 2)
        expectNumber("IF(TRUE, 2, ERROR())", 2)
        expectNumber("IF(TRUE, 1, {Missing})", 1)
        expectError(#"IF(ERROR("cond"), 1, 2)"#, containing: "cond")
        expectError("IF(TRUE, 1/0, 2)", containing: "Division by zero")
    }

    @Test func switchMatchesPatterns() {
        expectText(#"SWITCH(2, 1, "one", 2, "two", "other")"#, "two")
        expectText(#"SWITCH(3, 1, "one", 2, "two", "other")"#, "other")
        expectValue(#"SWITCH(3, 1, "one", 2, "two")"#, .blank)
        expectNumber(#"SWITCH("b", "a", 1, "b", 2)"#, 2)
        expectText(#"SWITCH({Status}, "Todo", "⏳", "Done", "✓", "?")"#, "✓", context)
        expectText(#"SWITCH({Blank}, "", "empty", "full")"#, "empty", context)
        expectText(#"SWITCH("2", 2, "numeric match")"#, "numeric match")
    }

    @Test func switchIsLazy() {
        expectText(#"SWITCH(1, 1, "ok", 2, 1/0)"#, "ok")
        expectText(#"SWITCH(1, 1, "ok", 1/0, "never")"#, "ok")
        expectError("SWITCH(ERROR(\"subject\"), 1, 2)", containing: "subject")
        expectError(#"SWITCH(2, 1/0, "x")"#, containing: "Division by zero")
    }

    @Test func andOr() {
        expectBool("AND(1, 1)", true)
        expectBool("AND(1, 0)", false)
        expectBool("AND(1, BLANK())", false)
        expectBool(#"AND("a", TRUE, 5)"#, true)
        expectBool(#"OR(0, "", 1)"#, true)
        expectBool("OR(0, 0)", false)
        expectBool("OR(BLANK())", false)
    }

    @Test func andOrShortCircuit() {
        expectBool(#"AND(FALSE, ERROR("x"))"#, false)
        expectBool("OR(TRUE, 1/0)", true)
        expectError(#"AND(TRUE, ERROR("late"))"#, containing: "late")
        expectError(#"OR(FALSE, ERROR("late"))"#, containing: "late")
    }

    @Test func andOrExpandArrays() {
        expectBool("AND({Ones})", true, context)
        expectBool("AND({Mixed})", false, context)
        expectBool("OR({Mixed})", true, context)
        expectBool("OR({Zeroes})", false, context)
        expectBool("AND({NoItems})", false, context)
        expectBool("AND({Ones}, {NoItems})", true, context)
    }

    @Test func xor() {
        expectBool("XOR(1, 0)", true)
        expectBool("XOR(1, 1)", false)
        expectBool("XOR(1, 1, 1)", true)
        expectBool("XOR(0, BLANK())", false)
        expectBool("XOR({Mixed})", true, context)
        expectBool("XOR({Ones})", false, context)
        expectError(#"XOR(1, ERROR("x"))"#, containing: "x")
    }

    @Test func notTrueFalseBlank() {
        expectBool("NOT(0)", true)
        expectBool(#"NOT("x")"#, false)
        expectBool("NOT(BLANK())", true)
        expectBool("TRUE()", true)
        expectBool("FALSE()", false)
        expectValue("BLANK()", .blank)
        expectBool("BLANK() = \"\"", true)
    }

    @Test func errorAndIsError() {
        expectValue("ERROR()", .error(FormulaError("Error")))
        expectValue(#"ERROR("Custom message")"#, .error(FormulaError("Custom message")))
        expectBool("ISERROR(1/0)", true)
        expectBool("ISERROR(1)", false)
        expectBool("ISERROR({Missing})", true)
        expectBool("ISERROR(ERROR())", true)
        expectBool("ISERROR(BLANK())", false)
        let broken = TestContext(fields: ["List": .array([.number(1), .error(FormulaError("bad"))])])
        expectBool("ISERROR({List})", true, broken)
        expectNumber("IF(ISERROR(1/0), -1, 1/0)", -1)
    }
}
