import Foundation
import Testing
import RowHouseFormula

@Suite("FormulaSource.rewriteFieldReferences")
struct FormulaSourceTests {
    let namesToIDs: [String: String] = [
        "Name": "fldName001",
        "Status": "fldStatus02",
        "Sum": "fldSum00003",
        "Flag": "fldFlag0004",
        "Extra": "fldExtra005",
        "Café": "fldCafe0006",
        "Unit Price": "fldPrice007",
    ]

    var idsToNames: [String: String] {
        Dictionary(uniqueKeysWithValues: namesToIDs.map { ($0.value, $0.key) })
    }

    func toIDs(_ source: String, variables: Set<String> = []) -> String {
        FormulaSource.rewriteFieldReferences(in: source, variables: variables) { namesToIDs[$0] }
    }

    @Test func bracedAndBareReferencesBecomeBracedIDs() {
        let source = #"{Name} & " {Name} " /* {Name} Name */ & Name & LOWER(Status)"#
        #expect(toIDs(source) == #"{fldName001} & " {Name} " /* {Name} Name */ & {fldName001} & LOWER({fldStatus02})"#)
    }

    @Test func namesWithSpacesAndSymbols() {
        #expect(toIDs("{Unit Price} * 2") == "{fldPrice007} * 2")
        #expect(toIDs("  {Café}\n\t& 'ü'  ") == "  {fldCafe0006}\n\t& 'ü'  ")
        #expect(toIDs("Café + 1") == "{fldCafe0006} + 1")
    }

    @Test func unknownReferencesAreLeftUntouched() {
        #expect(toIDs("{Unknown} + Other + {Name}") == "{Unknown} + Other + {fldName001}")
    }

    @Test func functionNamesBooleansAndVariablesAreNotReferences() {
        #expect(toIDs("Sum + SUM(Sum)") == "{fldSum00003} + SUM({fldSum00003})")
        #expect(toIDs("IF(TRUE, Flag, false)") == "IF(TRUE, {fldFlag0004}, false)")
        #expect(toIDs("SUM(values) + Extra", variables: ["values"]) == "SUM(values) + {fldExtra005}")
        #expect(toIDs("LEN /* call */ (Name)") == "LEN /* call */ ({fldName001})")
    }

    @Test func stringsAndCommentsArePreservedExactly() {
        let source = #"'Name' & "Status \"Name\"" /* Status */ & {Status}"#
        #expect(toIDs(source) == #"'Name' & "Status \"Name\"" /* Status */ & {fldStatus02}"#)
    }

    @Test func roundTripBetweenNamesAndIDs() {
        let original = "IF({Status} = \"Done\", Name & \" ✓\", {Unit Price} * 2) /* keep */"
        let withIDs = toIDs(original)
        #expect(withIDs == "IF({fldStatus02} = \"Done\", {fldName001} & \" ✓\", {fldPrice007} * 2) /* keep */")
        let backToNames = FormulaSource.rewriteFieldReferences(in: withIDs) { idsToNames[$0] }
        #expect(backToNames == "IF({Status} = \"Done\", {Name} & \" ✓\", {Unit Price} * 2) /* keep */")
        #expect(parse(withIDs)?.fieldReferences == ["fldStatus02", "fldName001", "fldPrice007"])
    }

    @Test func rewrittenFormulaEvaluatesAgainstIDs() {
        let withIDs = toIDs("Name & \": \" & {Unit Price}")
        let context = TestContext(fields: ["fldName001": .text("Widget"), "fldPrice007": .number(9.5)])
        #expect(evaluate(withIDs, context) == .text("Widget: 9.5"))
    }

    @Test func malformedSourceIsRewrittenUpToTheError() {
        #expect(toIDs(#"{Name} & "unterminated {Status}"#) == #"{fldName001} & "unterminated {Status}"#)
        #expect(toIDs("Name + {Status") == "{fldName001} + {Status")
        #expect(toIDs("Name /* open comment Status") == "{fldName001} /* open comment Status")
        #expect(toIDs("Name # Status") == "{fldName001} # Status")
    }

    @Test func unrepresentableReplacementsAreSkipped() {
        let rewritten = FormulaSource.rewriteFieldReferences(in: "{A} + {B} + {C}") { name in
            switch name {
            case "A": return "has } brace"
            case "B": return ""
            default: return "fine"
            }
        }
        #expect(rewritten == "{A} + {B} + {fine}")
    }

    @Test func emptyAndReferenceFreeSources() {
        #expect(toIDs("") == "")
        #expect(toIDs("1 + 2 /* x */") == "1 + 2 /* x */")
        #expect(toIDs("NOW()") == "NOW()")
    }
}
