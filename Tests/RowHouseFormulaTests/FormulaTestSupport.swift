import Foundation
import Testing
import RowHouseFormula

struct TestContext: FormulaContext, Sendable {
    var fields: [String: FormulaValue]
    var variables: [String: FormulaValue]
    var recordID = "rec123"
    var createdTime = TestDates.utc(2024, 1, 2, 3, 4, 5)
    var lastModifiedTime = TestDates.utc(2024, 2, 3, 4, 5, 6)
    var now: Date
    var timeZone: TimeZone

    init(
        fields: [String: FormulaValue] = [:],
        variables: [String: FormulaValue] = [:],
        timeZone: String = "UTC",
        now: Date = TestDates.utc(2024, 3, 15, 10, 30)
    ) {
        self.fields = fields
        self.variables = variables
        self.timeZone = TimeZone(identifier: timeZone)!
        self.now = now
    }

    func value(forField reference: String) -> FormulaValue? {
        fields[reference]
    }

    func variable(_ name: String) -> FormulaValue? {
        variables[name]
    }
}

enum TestDates {
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, millisecond: Int = 0) -> Date {
        local("UTC", year, month, day, hour, minute, second, millisecond: millisecond)
    }

    /// Built with Foundation's Calendar, independently of the engine's own date arithmetic.
    static func local(
        _ timeZone: String, _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, millisecond: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        let whole = calendar.date(from: components)!
        return whole.addingTimeInterval(Double(millisecond) / 1000)
    }
}

func parse(_ source: String, variables: Set<String> = [], sourceLocation: SourceLocation = #_sourceLocation) -> FormulaExpr? {
    do throws(FormulaSyntaxError) {
        return try FormulaParser.parse(source, variables: variables)
    } catch {
        Issue.record("Unexpected syntax error in \(source): \(error.message) at \(error.offset)", sourceLocation: sourceLocation)
        return nil
    }
}

func syntaxError(_ source: String, variables: Set<String> = []) -> FormulaSyntaxError? {
    do throws(FormulaSyntaxError) {
        _ = try FormulaParser.parse(source, variables: variables)
        return nil
    } catch {
        return error
    }
}

func evaluate(
    _ source: String,
    _ context: TestContext = TestContext(),
    variables: Set<String> = [],
    sourceLocation: SourceLocation = #_sourceLocation
) -> FormulaValue {
    guard let expr = parse(source, variables: variables, sourceLocation: sourceLocation) else {
        return .error(FormulaError("syntax error"))
    }
    return FormulaEvaluator.evaluate(expr, in: context)
}

func expectValue(
    _ source: String,
    _ expected: FormulaValue,
    _ context: TestContext = TestContext(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = evaluate(source, context, sourceLocation: sourceLocation)
    #expect(actual == expected, "\(source)", sourceLocation: sourceLocation)
}

func expectNumber(
    _ source: String,
    _ expected: Double,
    accuracy: Double = 0,
    _ context: TestContext = TestContext(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = evaluate(source, context, sourceLocation: sourceLocation)
    guard case .number(let number) = actual else {
        Issue.record("\(source) returned \(actual), expected \(expected)", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(number - expected) <= accuracy, "\(source) returned \(number), expected \(expected)", sourceLocation: sourceLocation)
}

func expectText(
    _ source: String,
    _ expected: String,
    _ context: TestContext = TestContext(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectValue(source, .text(expected), context, sourceLocation: sourceLocation)
}

func expectBool(
    _ source: String,
    _ expected: Bool,
    _ context: TestContext = TestContext(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectValue(source, .bool(expected), context, sourceLocation: sourceLocation)
}

func expectDate(
    _ source: String,
    _ expected: Date,
    _ context: TestContext = TestContext(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = evaluate(source, context, sourceLocation: sourceLocation)
    guard case .date(let date) = actual else {
        Issue.record("\(source) returned \(actual), expected a date", sourceLocation: sourceLocation)
        return
    }
    #expect(
        abs(date.timeIntervalSince(expected)) < 0.0005,
        "\(source) returned \(date), expected \(expected)",
        sourceLocation: sourceLocation
    )
}

/// Checks the cell rendering, which is how most date results are easiest to state.
func expectDisplay(
    _ source: String,
    _ expected: String,
    _ context: TestContext = TestContext(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = evaluate(source, context, sourceLocation: sourceLocation)
    #expect(
        actual.displayString(timeZone: context.timeZone) == expected,
        "\(source) displayed \(actual.displayString(timeZone: context.timeZone)) (\(actual))",
        sourceLocation: sourceLocation
    )
}

func expectError(
    _ source: String,
    containing fragment: String? = nil,
    _ context: TestContext = TestContext(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = evaluate(source, context, sourceLocation: sourceLocation)
    guard case .error(let error) = actual else {
        Issue.record("\(source) returned \(actual), expected an error", sourceLocation: sourceLocation)
        return
    }
    if let fragment {
        #expect(
            error.message.contains(fragment),
            "\(source) error \"\(error.message)\" does not contain \"\(fragment)\"",
            sourceLocation: sourceLocation
        )
    }
}

extension FormulaValue {
    static func numbers(_ values: Double...) -> FormulaValue {
        .array(values.map { .number($0) })
    }

    static func texts(_ values: String...) -> FormulaValue {
        .array(values.map { .text($0) })
    }
}
