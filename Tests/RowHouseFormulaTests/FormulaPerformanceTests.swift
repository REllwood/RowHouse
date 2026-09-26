import Foundation
import Testing
import RowHouseFormula

@Suite("Performance, concurrency and robustness")
struct FormulaPerformanceTests {
    static let formula = #"""
        IF(
          AND({Status} = "Active", {Amount} > 100),
          UPPER(LEFT({Name}, 3)) & "-" & ROUND({Amount} * 1.1, 2),
          DATETIME_FORMAT(DATEADD({Due}, {Days}, "days"), "YYYY-MM-DD") & " " & REGEX_REPLACE({Name}, "[aeiou]", "*")
        )
        """#

    static func context(for index: Int) -> TestContext {
        TestContext(fields: [
            "Status": .text(index % 3 == 0 ? "Active" : "Paused"),
            "Amount": .number(Double(index % 250)),
            "Name": .text("Record number \(index)"),
            "Due": .date(TestDates.utc(2024, 1, 1)),
            "Days": .number(Double(index % 30)),
        ], timeZone: "Australia/Sydney")
    }

    @Test func parseOnceEvaluateTenThousandRecords() throws {
        let expr = try FormulaParser.parse(Self.formula)
        let contexts = (0..<10_000).map(Self.context(for:))

        let start = Date()
        var errors = 0
        for context in contexts {
            if case .error = FormulaEvaluator.evaluate(expr, in: context) {
                errors += 1
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(errors == 0)
        #expect(elapsed < 10, "10,000 evaluations took \(elapsed)s")
        #expect(FormulaEvaluator.evaluate(expr, in: contexts[102]) == .text("REC-112.2"))
        #expect(FormulaEvaluator.evaluate(expr, in: contexts[1]) == .text("2024-01-02 R*c*rd n*mb*r 1"))
    }

    @Test func concurrentEvaluationIsSafe() async throws {
        let expr = try FormulaParser.parse(Self.formula)
        let expected = (0..<400).map { FormulaEvaluator.evaluate(expr, in: Self.context(for: $0)) }

        let results = await withTaskGroup(of: (Int, FormulaValue).self) { group in
            for index in 0..<400 {
                group.addTask {
                    (index, FormulaEvaluator.evaluate(expr, in: Self.context(for: index)))
                }
            }
            var collected = [FormulaValue](repeating: .blank, count: 400)
            for await (index, value) in group {
                collected[index] = value
            }
            return collected
        }
        #expect(results == expected)
    }

    @Test func manyDistinctRegexPatternsAndFormats() {
        for index in 0..<1_200 {
            expectBool("REGEX_MATCH(\"item\(index)\", \"^item\(index)$\")", true)
        }
        for index in 0..<400 {
            expectText("DATETIME_FORMAT(\"2024-01-05\", \"[\(index)] YYYY\")", "\(index) 2024")
        }
    }

    @Test func deepestAllowedFormulasWorkOnASmallStack() throws {
        let depth = FormulaParser.maximumNestingDepth
        let nested = String(repeating: "IF(TRUE, ", count: depth - 1) + "1" + String(repeating: ", 0)", count: depth - 1)
        let parentheses = String(repeating: "(", count: depth) + "{A}" + String(repeating: ")", count: depth)
        let chain = Array(repeating: "{A}", count: FormulaParser.maximumExpressionDepth).joined(separator: " + ")
        // The deepest nesting with a long operator chain at the bottom.
        let combined = String(repeating: "IF(TRUE, ", count: depth - 1)
            + Array(repeating: "{A}", count: FormulaParser.maximumExpressionDepth - depth).joined(separator: " & ")
            + String(repeating: ", 0)", count: depth - 1)
        let sources = [nested, parentheses, chain, combined]

        // Secondary threads (GCD, Swift concurrency) default to 512 KB of stack.
        let results = runOnThread(stackSize: 512 * 1024) {
            let context = TestContext(fields: ["A": .number(1)])
            return sources.map { source -> FormulaValue in
                guard let expr = try? FormulaParser.parse(source) else { return .error(FormulaError("parse failed")) }
                guard expr == (try? FormulaParser.parse(source)), expr.fieldReferences.count <= 1 else {
                    return .error(FormulaError("round trip failed"))
                }
                return FormulaEvaluator.evaluate(expr, in: context)
            }
        }
        #expect(results.count == 4)
        #expect(results.first == .number(1))
        #expect(results.dropFirst().first == .number(1))
        #expect(results.dropFirst(2).first == .number(Double(FormulaParser.maximumExpressionDepth)))
        #expect(results.last == .text(String(repeating: "1", count: FormulaParser.maximumExpressionDepth - depth)))
    }

    private func runOnThread(stackSize: Int, _ body: @escaping @Sendable () -> [FormulaValue]) -> [FormulaValue] {
        final class Box: @unchecked Sendable {
            var value: [FormulaValue] = []
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        return box.value
    }
}
