import Foundation

public enum FormulaParser: Sendable {
    /// Maximum depth of parentheses, function calls and prefix operators.
    public static let maximumNestingDepth = 100
    /// Maximum height of the expression tree; each binary operator in a chain adds one level.
    public static let maximumExpressionDepth = 1000

    public static func parse(_ source: String, variables: Set<String> = []) throws(FormulaSyntaxError) -> FormulaExpr {
        var parser = Parser(tokens: FormulaLexer.tokenize(Array(source)), variables: variables)
        return try parser.parseFormula()
    }
}

/// A precedence-climbing parser. Functions on the recursive path (parseExpression → parseOperand →
/// parseParenthesized/parseCall) keep few locals and refer to tokens by index, so deeply nested formulas
/// stay well within a secondary thread's stack even in unoptimized builds.
private struct Parser {
    private struct Node {
        var expr: FormulaExpr
        var height: Int
    }

    private let tokens: [FormulaToken]
    private let variables: [String: String]
    private var position = 0
    private var nesting = 0

    init(tokens: [FormulaToken], variables: Set<String>) {
        self.tokens = tokens
        var lookup: [String: String] = [:]
        for name in variables {
            lookup[name.uppercased()] = name
        }
        self.variables = lookup
    }

    mutating func parseFormula() throws(FormulaSyntaxError) -> FormulaExpr {
        if case .end = tokens[position].kind {
            throw FormulaSyntaxError(message: "Formula is empty", offset: tokens[position].start)
        }
        let node = try parseExpression(minimumPrecedence: 0)
        guard case .end = tokens[position].kind else {
            throw unexpected(at: position)
        }
        return node.expr
    }

    // MARK: Recursive path

    private mutating func parseExpression(minimumPrecedence: Int) throws(FormulaSyntaxError) -> Node {
        var lhs = try parseOperand()
        while let precedence = currentBinaryPrecedence(), precedence >= minimumPrecedence {
            let operatorIndex = position
            advance()
            let rhs = try parseExpression(minimumPrecedence: precedence + 1)
            lhs = try binaryNode(operatorIndex: operatorIndex, lhs, rhs)
        }
        return lhs
    }

    private mutating func parseOperand() throws(FormulaSyntaxError) -> Node {
        let firstPrefix = position
        let prefixCount = try consumePrefixOperators()
        var node: Node
        if currentIsLeftParenthesis() {
            node = try parseParenthesized()
        } else if currentStartsCall() {
            node = try parseCall()
        } else {
            node = try parseAtom()
        }
        if prefixCount > 0 {
            node = try applyPrefixOperators(from: firstPrefix, count: prefixCount, to: node)
        }
        return node
    }

    private mutating func parseParenthesized() throws(FormulaSyntaxError) -> Node {
        try enterNesting(at: position)
        advance()
        let inner = try parseExpression(minimumPrecedence: 0)
        try consumeClosingParenthesis()
        nesting -= 1
        return inner
    }

    private mutating func parseCall() throws(FormulaSyntaxError) -> Node {
        let nameIndex = position
        let name = try functionName(at: nameIndex)
        advance()
        try enterNesting(at: nameIndex)
        advance()
        var arguments: [FormulaExpr] = []
        var height = 0
        if !consumeEmptyArgumentList() {
            repeat {
                let argument = try parseExpression(minimumPrecedence: 0)
                arguments.append(argument.expr)
                height = max(height, argument.height)
            } while try consumeArgumentSeparator()
        }
        nesting -= 1
        try validateArgumentCount(arguments.count, of: name, at: nameIndex)
        return try makeNode(.call(name: name, args: arguments), height: height + 1, at: nameIndex)
    }

    // MARK: Leaves and helpers

    private mutating func parseAtom() throws(FormulaSyntaxError) -> Node {
        let token = tokens[position]
        switch token.kind {
        case .number(let value):
            advance()
            return Node(expr: .number(value), height: 1)
        case .string(let value):
            advance()
            return Node(expr: .text(value), height: 1)
        case .fieldRef(let reference):
            advance()
            return Node(expr: .fieldRef(reference), height: 1)
        case .identifier(let name):
            advance()
            return Node(expr: identifierExpression(name), height: 1)
        case .invalid(let error):
            throw error
        case .end:
            throw FormulaSyntaxError(message: "Unexpected end of formula", offset: token.start)
        case .leftParen, .rightParen, .comma, .op:
            throw unexpected(at: position)
        }
    }

    private func identifierExpression(_ name: String) -> FormulaExpr {
        let uppercased = name.uppercased()
        if uppercased == "TRUE" { return .bool(true) }
        if uppercased == "FALSE" { return .bool(false) }
        if let variable = variables[uppercased] { return .variable(variable) }
        return .fieldRef(name)
    }

    private mutating func advance() {
        if position < tokens.count - 1 {
            position += 1
        }
    }

    private func currentBinaryPrecedence() -> Int? {
        guard case .op(let op) = tokens[position].kind else { return nil }
        switch op {
        case "=", "!=", "<", ">", "<=", ">=": return 0
        case "&": return 1
        case "+", "-": return 2
        case "*", "/": return 3
        default: return nil
        }
    }

    private func currentIsLeftParenthesis() -> Bool {
        if case .leftParen = tokens[position].kind { return true }
        return false
    }

    private func currentStartsCall() -> Bool {
        guard case .identifier = tokens[position].kind, position + 1 < tokens.count else { return false }
        if case .leftParen = tokens[position + 1].kind { return true }
        return false
    }

    /// Consumes leading `-`/`+` operators, counting each as a nesting level.
    private mutating func consumePrefixOperators() throws(FormulaSyntaxError) -> Int {
        var count = 0
        while case .op(let op) = tokens[position].kind, op == "-" || op == "+" {
            try enterNesting(at: position)
            count += 1
            advance()
        }
        return count
    }

    private mutating func applyPrefixOperators(from first: Int, count: Int, to operand: Node) throws(FormulaSyntaxError) -> Node {
        var node = operand
        for index in stride(from: first + count - 1, through: first, by: -1) {
            guard case .op(let op) = tokens[index].kind else { continue }
            node = try makeNode(.unary(op: op, node.expr), height: node.height + 1, at: index)
        }
        nesting -= count
        return node
    }

    private func binaryNode(operatorIndex: Int, _ lhs: Node, _ rhs: Node) throws(FormulaSyntaxError) -> Node {
        guard case .op(let op) = tokens[operatorIndex].kind else {
            throw unexpected(at: operatorIndex)
        }
        return try makeNode(.binary(op: op, lhs.expr, rhs.expr), height: max(lhs.height, rhs.height) + 1, at: operatorIndex)
    }

    private func functionName(at index: Int) throws(FormulaSyntaxError) -> String {
        guard case .identifier(let name) = tokens[index].kind else {
            throw unexpected(at: index)
        }
        let uppercased = name.uppercased()
        guard FormulaFunctionRegistry.function(named: uppercased) != nil else {
            throw FormulaSyntaxError(message: "Unknown function \(uppercased)", offset: tokens[index].start)
        }
        return uppercased
    }

    private func validateArgumentCount(_ count: Int, of name: String, at index: Int) throws(FormulaSyntaxError) {
        guard let function = FormulaFunctionRegistry.function(named: name) else { return }
        guard function.accepts(argumentCount: count) else {
            throw FormulaSyntaxError(message: function.arityMessage, offset: tokens[index].start)
        }
    }

    private mutating func consumeEmptyArgumentList() -> Bool {
        guard case .rightParen = tokens[position].kind else { return false }
        advance()
        return true
    }

    /// After an argument: returns true for `,` (another argument follows) and false for `)`.
    private mutating func consumeArgumentSeparator() throws(FormulaSyntaxError) -> Bool {
        switch tokens[position].kind {
        case .comma:
            advance()
            return true
        case .rightParen:
            advance()
            return false
        default:
            throw expected("\",\" or \")\"", at: position)
        }
    }

    private mutating func consumeClosingParenthesis() throws(FormulaSyntaxError) {
        guard case .rightParen = tokens[position].kind else {
            throw expected("\")\"", at: position)
        }
        advance()
    }

    private mutating func enterNesting(at index: Int) throws(FormulaSyntaxError) {
        nesting += 1
        if nesting > FormulaParser.maximumNestingDepth {
            throw FormulaSyntaxError(message: "Formula is nested too deeply", offset: tokens[index].start)
        }
    }

    private func makeNode(_ expr: FormulaExpr, height: Int, at index: Int) throws(FormulaSyntaxError) -> Node {
        if height > FormulaParser.maximumExpressionDepth {
            throw FormulaSyntaxError(message: "Formula is too complex", offset: tokens[index].start)
        }
        return Node(expr: expr, height: height)
    }

    // MARK: Error messages

    private func unexpected(at index: Int) -> FormulaSyntaxError {
        let token = tokens[index]
        if case .invalid(let error) = token.kind {
            return error
        }
        return FormulaSyntaxError(message: "Unexpected \(describe(token))", offset: token.start)
    }

    private func expected(_ what: String, at index: Int) -> FormulaSyntaxError {
        let token = tokens[index]
        if case .invalid(let error) = token.kind {
            return error
        }
        return FormulaSyntaxError(message: "Expected \(what) but found \(describe(token))", offset: token.start)
    }

    private func describe(_ token: FormulaToken) -> String {
        switch token.kind {
        case .number(let value):
            return FormulaNumberFormatting.string(from: value)
        case .string:
            return "text"
        case .fieldRef(let reference):
            return "{\(reference)}"
        case .identifier(let name):
            return "\"\(name)\""
        case .leftParen:
            return "\"(\""
        case .rightParen:
            return "\")\""
        case .comma:
            return "\",\""
        case .op(let op):
            return "\"\(op)\""
        case .end:
            return "end of formula"
        case .invalid(let error):
            return error.message
        }
    }
}
