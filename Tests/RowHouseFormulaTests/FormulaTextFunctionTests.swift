import Foundation
import Testing
import RowHouseFormula

@Suite("Text functions")
struct FormulaTextFunctionTests {
    let context = TestContext(fields: [
        "Blank": .blank,
        "Tags": .texts("x", "y"),
        "One": .texts("only"),
        "Name": .text("Ada Lovelace"),
    ])

    @Test func concatenate() {
        expectText(#"CONCATENATE("a", 1, TRUE(), BLANK(), "b")"#, "a1TRUEb")
        expectText(#"CONCATENATE({Tags}, "-")"#, "xy-", context)
        expectText(#"CONCATENATE("")"#, "")
        expectText("CONCATENATE(DATETIME_PARSE(\"2024-01-05\"), \"!\")", "2024-01-05!")
    }

    @Test func len() {
        expectNumber(#"LEN("hello")"#, 5)
        expectNumber(#"LEN("")"#, 0)
        expectNumber(#"LEN("é😀👨‍👩‍👧")"#, 3)
        expectNumber("LEN(123.5)", 5)
        expectNumber("LEN({Blank})", 0, context)
        expectNumber("LEN({Tags})", 4, context)
    }

    @Test func caseConversion() {
        expectText(#"LOWER("AbC Ü")"#, "abc ü")
        expectText(#"UPPER("straße")"#, "STRASSE")
        expectText("UPPER({Tags})", "X, Y", context)
    }

    @Test func trim() {
        expectText(#"TRIM("  a   b  ")"#, "a b")
        expectText("TRIM(\"\\ta  b\\n\")", "a b")
        expectText("TRIM(\"a\\t\\tb\")", "a\t\tb")
        expectText(#"TRIM("   ")"#, "")
    }

    @Test func leftRightMid() {
        expectText(#"LEFT("hello", 2)"#, "he")
        expectText(#"LEFT("hi", 10)"#, "hi")
        expectText(#"LEFT("hi", 0)"#, "")
        expectText(#"LEFT("😀ab", 1)"#, "😀")
        expectText(#"LEFT("hello", 2.9)"#, "he")
        expectError(#"LEFT("hi", -1)"#, containing: "LEFT count")
        expectText(#"RIGHT("hello", 3)"#, "llo")
        expectText(#"RIGHT("hi", 5)"#, "hi")
        expectError(#"RIGHT("hi", -2)"#, containing: "RIGHT count")
        expectText(#"MID("hello world", 7, 5)"#, "world")
        expectText(#"MID("hello", 2, 100)"#, "ello")
        expectText(#"MID("hello", 10, 2)"#, "")
        expectText(#"MID("hello", 1, 0)"#, "")
        expectError(#"MID("hello", 0, 1)"#, containing: "MID start")
        expectError(#"MID("abc", 1, -1)"#, containing: "MID count")
        expectText(#"MID("hello", 1e300, 1)"#, "")
    }

    @Test func find() {
        expectNumber(#"FIND("l", "hello")"#, 3)
        expectNumber(#"FIND("L", "hello")"#, 0)
        expectNumber(#"FIND("lo", "hello")"#, 4)
        expectNumber(#"FIND("l", "hello", 4)"#, 4)
        expectNumber(#"FIND("l", "hello", 5)"#, 0)
        expectNumber(#"FIND("h", "hello", 0)"#, 1)
        expectNumber(#"FIND("", "abc")"#, 1)
        expectNumber(#"FIND("x", "")"#, 0)
        expectNumber(#"FIND("world", "hello")"#, 0)
        expectNumber(#"FIND("😀", "a😀b😀", 3)"#, 4)
    }

    @Test func search() {
        expectNumber(#"SEARCH("L", "hello")"#, 3)
        expectValue(#"SEARCH("x", "hello")"#, .blank)
        expectNumber(#"SEARCH("WORLD", "Hello World", 2)"#, 7)
        expectNumber(#"SEARCH("ß", "STRAßE")"#, 5)
        expectValue(#"SEARCH("o", "Hello World", 9)"#, .blank)
    }

    @Test func substitute() {
        expectText(#"SUBSTITUTE("a-b-c", "-", "+")"#, "a+b+c")
        expectText(#"SUBSTITUTE("a-b-c", "-", "+", 2)"#, "a-b+c")
        expectText(#"SUBSTITUTE("a-b-c", "-", "+", 5)"#, "a-b-c")
        expectText(#"SUBSTITUTE("abc", "", "x")"#, "abc")
        expectText(#"SUBSTITUTE("aaa", "aa", "b")"#, "ba")
        expectText(#"SUBSTITUTE("Hello", "l", "")"#, "Heo")
        expectText(#"SUBSTITUTE("a.b", ".", "\\")"#, #"a\b"#)
        expectError(#"SUBSTITUTE("x", "x", "y", 0)"#, containing: "SUBSTITUTE index")
    }

    @Test func replace() {
        expectText(#"REPLACE("abcdef", 2, 3, "XY")"#, "aXYef")
        expectText(#"REPLACE("abc", 4, 0, "d")"#, "abcd")
        expectText(#"REPLACE("abc", 10, 1, "z")"#, "abcz")
        expectText(#"REPLACE("abc", 1, 10, "z")"#, "z")
        expectError(#"REPLACE("abc", 0, 1, "z")"#, containing: "REPLACE start")
        expectError(#"REPLACE("abc", 1, -1, "z")"#, containing: "REPLACE count")
    }

    @Test func rept() {
        expectText(#"REPT("ab", 3)"#, "ababab")
        expectText(#"REPT("x", 0)"#, "")
        expectText(#"REPT("", 1000)"#, "")
        expectError(#"REPT("x", -1)"#, containing: "REPT count")
        expectError(#"REPT("abc", 1e9)"#, containing: "too long")
    }

    @Test func t() {
        expectText(#"T("abc")"#, "abc")
        expectValue("T(1)", .blank)
        expectValue("T(TRUE())", .blank)
        expectText("T({One})", "only", context)
        expectValue("T({Tags})", .blank, context)
    }

    @Test func encodeURLComponent() {
        expectText(#"ENCODE_URL_COMPONENT("a b&c=d/é?")"#, "a%20b%26c%3Dd%2F%C3%A9%3F")
        expectText(#"ENCODE_URL_COMPONENT("A-Z_a.z!~*'()09")"#, "A-Z_a.z!~*'()09")
        expectText(#"ENCODE_URL_COMPONENT("100%")"#, "100%25")
    }

    @Test func regexMatch() {
        expectBool(#"REGEX_MATCH("abc123", "\d+")"#, true)
        expectBool(#"REGEX_MATCH("abc123", "\\d+")"#, true)
        expectBool(#"REGEX_MATCH("abc", "\d")"#, false)
        expectBool(#"REGEX_MATCH("ABC", "^abc$")"#, false)
        expectBool(#"REGEX_MATCH("ABC", "(?i)^abc$")"#, true)
        expectBool(#"REGEX_MATCH({Name}, "^Ada\s")"#, true, context)
        expectError(#"REGEX_MATCH("x", "[")"#, containing: "Invalid regular expression")
    }

    @Test func regexExtract() {
        expectText(#"REGEX_EXTRACT("Order #123-456", "\d+")"#, "123")
        expectText(#"REGEX_EXTRACT("user@example.com", "@(.+)$")"#, "@example.com")
        expectValue(#"REGEX_EXTRACT("abc", "\d")"#, .blank)
        expectError(#"REGEX_EXTRACT("x", "(")"#, containing: "Invalid regular expression")
    }

    @Test func regexReplace() {
        expectText(#"REGEX_REPLACE("John Smith", "(\w+) (\w+)", "$2, $1")"#, "Smith, John")
        expectText(##"REGEX_REPLACE("a1b22c333", "\d+", "#")"##, "a#b#c#")
        expectText(##"REGEX_REPLACE("no digits", "\d", "#")"##, "no digits")
        expectText(#"REGEX_REPLACE("  spaced   out ", "\s+", " ")"#, " spaced out ")
    }

    @Test func textFunctionsCoerceNumbersAndDates() {
        expectText("LEFT(12345, 2)", "12")
        expectText("UPPER(TRUE())", "TRUE")
        expectText(#"LEFT(DATETIME_PARSE("2024-06-01"), 4)"#, "2024")
    }
}
