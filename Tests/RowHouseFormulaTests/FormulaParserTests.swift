import Foundation
import Testing
import RowHouseFormula

@Suite("Parser: literals and references")
struct FormulaParserLiteralTests {
    @Test("Number literals", arguments: [
        ("3", 3.0), ("3.25", 3.25), (".5", 0.5), ("1e3", 1000), ("1.5E-2", 0.015), ("2e+2", 200), ("1.", 1), ("007", 7),
    ])
    func numbers(source: String, expected: Double) {
        #expect(parse(source) == .number(expected))
    }

    @Test func stringsWithEitherQuote() {
        #expect(parse(#""hello""#) == .text("hello"))
        #expect(parse("'single'") == .text("single"))
        #expect(parse(#"'mixed "quotes"'"#) == .text(#"mixed "quotes""#))
        #expect(parse(#""it's""#) == .text("it's"))
        #expect(parse(#""""#) == .text(""))
    }

    @Test func stringEscapes() {
        #expect(parse(#""a\"b""#) == .text(#"a"b"#))
        #expect(parse(#"'it\'s'"#) == .text("it's"))
        #expect(parse(#""back\\slash""#) == .text(#"back\slash"#))
        #expect(parse(#""line\nbreak""#) == .text("line\nbreak"))
        #expect(parse(#""tab\there""#) == .text("tab\there"))
        // Unknown escapes are kept so regular expressions can be written naturally.
        #expect(parse(#""\d+\.\w""#) == .text(#"\d+\.\w"#))
    }

    @Test func smartQuotesAreStringDelimiters() {
        #expect(parse("\u{201C}curly\u{201D}") == .text("curly"))
        #expect(parse("\u{2018}single\u{2019}") == .text("single"))
    }

    @Test func booleanLiteralsAreCaseInsensitive() {
        #expect(parse("TRUE") == .bool(true))
        #expect(parse("false") == .bool(false))
        #expect(parse("True") == .bool(true))
        #expect(parse("TRUE()") == .call(name: "TRUE", args: []))
        #expect(parse("false()") == .call(name: "FALSE", args: []))
    }

    @Test func bracedFieldReferences() {
        #expect(parse("{Field Name}") == .fieldRef("Field Name"))
        #expect(parse("{a+b (c), 'd'}") == .fieldRef("a+b (c), 'd'"))
        #expect(parse("{fldAbc123}") == .fieldRef("fldAbc123"))
        #expect(parse("{ spaced }") == .fieldRef(" spaced "))
    }

    @Test func bareIdentifiersAreFieldReferences() {
        #expect(parse("Price") == .fieldRef("Price"))
        #expect(parse("price_2") == .fieldRef("price_2"))
        #expect(parse("_hidden") == .fieldRef("_hidden"))
        #expect(parse("Café") == .fieldRef("Café"))
        #expect(parse("NOW") == .fieldRef("NOW"))
    }

    @Test func declaredVariables() {
        #expect(parse("values", variables: ["values"]) == .variable("values"))
        #expect(parse("VALUES", variables: ["values"]) == .variable("values"))
        #expect(parse("values") == .fieldRef("values"))
        // Braces always mean a field, even when the name is also a variable.
        #expect(parse("{values}", variables: ["values"]) == .fieldRef("values"))
        #expect(parse("SUM(values)", variables: ["values"]) == .call(name: "SUM", args: [.variable("values")]))
    }

    @Test func functionNamesAreUppercased() {
        #expect(parse("if(1, 2)") == .call(name: "IF", args: [.number(1), .number(2)]))
        #expect(parse("Sum(1)") == .call(name: "SUM", args: [.number(1)]))
        #expect(parse("now()") == .call(name: "NOW", args: []))
    }

    @Test func fieldReferencesAreCollected() {
        let expr = parse(#"{A} + B * IF({C}, D, 1) & "{E}" & LEN(values)"#, variables: ["values"])
        #expect(expr?.fieldReferences == ["A", "B", "C", "D"])
        #expect(parse("1 + 2")?.fieldReferences == [])
    }
}

@Suite("Parser: precedence and structure")
struct FormulaParserStructureTests {
    @Test func multiplicationBindsTighterThanAddition() {
        #expect(parse("1 + 2 * 3") == .binary(op: "+", .number(1), .binary(op: "*", .number(2), .number(3))))
        #expect(parse("(1 + 2) * 3") == .binary(op: "*", .binary(op: "+", .number(1), .number(2)), .number(3)))
    }

    @Test func concatenationBindsLooserThanArithmetic() {
        #expect(parse("1 & 2 + 3") == .binary(op: "&", .number(1), .binary(op: "+", .number(2), .number(3))))
    }

    @Test func comparisonBindsLoosest() {
        #expect(parse("1 = 2 & 3") == .binary(op: "=", .number(1), .binary(op: "&", .number(2), .number(3))))
        #expect(parse("a < b = c") == .binary(op: "=", .binary(op: "<", .fieldRef("a"), .fieldRef("b")), .fieldRef("c")))
    }

    @Test func unaryBindsTighterThanMultiplication() {
        #expect(parse("-2 * 3") == .binary(op: "*", .unary(op: "-", .number(2)), .number(3)))
        #expect(parse("- -1") == .unary(op: "-", .unary(op: "-", .number(1))))
        #expect(parse("+1") == .unary(op: "+", .number(1)))
        #expect(parse("2 * -3") == .binary(op: "*", .number(2), .unary(op: "-", .number(3))))
    }

    @Test func operatorsAreLeftAssociative() {
        #expect(parse("8 - 3 - 2") == .binary(op: "-", .binary(op: "-", .number(8), .number(3)), .number(2)))
        #expect(parse("8 / 4 / 2") == .binary(op: "/", .binary(op: "/", .number(8), .number(4)), .number(2)))
        #expect(parse(#""a" & "b" & "c""#) == .binary(op: "&", .binary(op: "&", .text("a"), .text("b")), .text("c")))
        expectNumber("8 - 3 - 2", 3)
        expectNumber("8 / 4 / 2", 1)
    }

    @Test func allComparisonOperators() {
        for op in ["=", "!=", "<", ">", "<=", ">="] {
            #expect(parse("1 \(op) 2") == .binary(op: op, .number(1), .number(2)))
        }
        #expect(parse("1 <> 2") == .binary(op: "!=", .number(1), .number(2)))
    }

    @Test func commentsAreWhitespace() {
        #expect(parse("1 /* one */ + /* two */ 2") == parse("1+2"))
        #expect(parse("/* leading */ 1") == .number(1))
        #expect(parse("1 /* trailing */") == .number(1))
        #expect(parse("IF(/* c */ TRUE, /* multi\nline */ 1)") == .call(name: "IF", args: [.bool(true), .number(1)]))
        #expect(syntaxError("1/*x*/2")?.message == "Unexpected 2")
    }

    @Test func whitespaceAndNewlines() {
        #expect(parse("IF(\n\tTRUE,\n  1\r\n)") == .call(name: "IF", args: [.bool(true), .number(1)]))
        #expect(parse("\u{00A0}1\u{00A0}+\u{00A0}2") == .binary(op: "+", .number(1), .number(2)))
    }

    @Test func expressionEquality() {
        #expect(parse("1 + 2") == parse("1+2"))
        #expect(parse("1 + 2") != parse("1 + 3"))
        #expect(parse("1 + 2") != parse("1 - 2"))
        #expect(parse("1 + 2") != parse("2 + 1"))
        #expect(parse("SUM(1, 2)") != parse("SUM(1)"))
        #expect(parse("SUM(1, 2)") != parse("MAX(1, 2)"))
        #expect(parse("-{A}") != parse("+{A}"))
        #expect(parse("{A}") != parse("A", variables: ["A"]))
        #expect(FormulaExpr.number(1) != .text("1"))
    }

    @Test func nestedCalls() {
        let expected = FormulaExpr.call(name: "IF", args: [
            .binary(op: ">", .call(name: "LEN", args: [.fieldRef("Name")]), .number(3)),
            .call(name: "UPPER", args: [.fieldRef("Name")]),
            .text("short"),
        ])
        #expect(parse(#"IF(LEN({Name}) > 3, UPPER(Name), "short")"#) == expected)
    }
}

@Suite("Parser: syntax errors")
struct FormulaParserErrorTests {
    @Test("Errors carry a message and character offset", arguments: [
        ("", "Formula is empty", 0),
        ("   ", "Formula is empty", 3),
        ("1 +", "Unexpected end of formula", 3),
        ("(1 + 2", "Expected \")\" but found end of formula", 6),
        ("1 2", "Unexpected 2", 2),
        (")", "Unexpected \")\"", 0),
        ("FOO(1)", "Unknown function FOO", 0),
        ("1 + foo(2)", "Unknown function FOO", 4),
        ("IFERROR(1, 2)", "Unknown function IFERROR", 0),
        ("\"abc", "Unterminated string", 0),
        ("1 & 'abc", "Unterminated string", 4),
        ("\"abc\\", "Unterminated string", 0),
        ("{abc", "Unterminated field reference", 0),
        ("{}", "Empty field reference", 0),
        ("1 # 2", "Unexpected character \"#\"", 2),
        ("1 ! 2", "Unexpected character \"!\"", 2),
        ("1 /* abc", "Unterminated comment", 2),
        ("SUM(1,)", "Unexpected \")\"", 6),
        ("SUM(1 2)", "Expected \",\" or \")\" but found 2", 6),
        ("{A}(1)", "Unexpected \"(\"", 3),
        ("SUM(,1)", "Unexpected \",\"", 4),
        ("1e999", "Number 1e999 is out of range", 0),
    ])
    func syntaxErrors(source: String, message: String, offset: Int) {
        let error = syntaxError(source)
        #expect(error?.message == message)
        #expect(error?.offset == offset)
    }

    @Test("Argument counts are validated at parse time", arguments: [
        ("IF(1)", "IF expects 2 or 3 arguments"),
        ("IF(1, 2, 3, 4)", "IF expects 2 or 3 arguments"),
        ("LEN()", "LEN expects 1 argument"),
        ("LEN(1, 2)", "LEN expects 1 argument"),
        ("NOW(1)", "NOW expects no arguments"),
        ("SUM()", "SUM expects at least 1 argument"),
        ("ERROR(1, 2)", "ERROR expects at most 1 argument"),
        ("DATETIME_PARSE()", "DATETIME_PARSE expects 1 to 3 arguments"),
        ("SWITCH(1, 2)", "SWITCH expects at least 3 arguments"),
        ("MID(\"a\", 1)", "MID expects 3 arguments"),
    ])
    func arity(source: String, message: String) {
        let error = syntaxError(source)
        #expect(error?.message == message)
        #expect(error?.offset == 0)
    }

    @Test func arityErrorPointsAtTheFunctionName() {
        #expect(syntaxError("1 + LEN()")?.offset == 4)
    }

    @Test func earliestProblemIsReported() {
        // The parse error at "2" comes before the unterminated string.
        #expect(syntaxError("(1 2 \"abc") == FormulaSyntaxError(message: "Expected \")\" but found 2", offset: 3))
    }

    @Test func offsetsCountCharacters() {
        #expect(syntaxError("\"é😀\" + 😀")?.offset == 7)
        #expect(syntaxError("\"👨‍👩‍👧\" #")?.offset == 4)
    }

    @Test func descriptionIsTheMessage() {
        #expect(syntaxError("FOO()")?.description == "Unknown function FOO")
    }

    @Test func nestingLimit() {
        let allowed = String(repeating: "(", count: FormulaParser.maximumNestingDepth) + "1"
            + String(repeating: ")", count: FormulaParser.maximumNestingDepth)
        #expect(syntaxError(allowed) == nil)

        let tooDeep = "(" + allowed + ")"
        #expect(syntaxError(tooDeep)?.message == "Formula is nested too deeply")

        let deepUnary = String(repeating: "-", count: FormulaParser.maximumNestingDepth + 1) + "1"
        #expect(syntaxError(deepUnary)?.message == "Formula is nested too deeply")
    }

    @Test func expressionDepthLimit() {
        let allowed = Array(repeating: "1", count: FormulaParser.maximumExpressionDepth).joined(separator: " + ")
        #expect(syntaxError(allowed) == nil)
        let tooLong = allowed + " + 1"
        #expect(syntaxError(tooLong)?.message == "Formula is too complex")
    }
}
