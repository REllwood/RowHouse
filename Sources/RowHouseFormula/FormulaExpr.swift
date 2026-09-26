import Foundation

public indirect enum FormulaExpr: Equatable, Sendable {
    case number(Double)
    case text(String)
    case bool(Bool)
    case fieldRef(String)
    case variable(String)
    case unary(op: String, FormulaExpr)
    case binary(op: String, FormulaExpr, FormulaExpr)
    case call(name: String, args: [FormulaExpr])
}

// Tree walks use an explicit work list rather than recursion so that long operator chains (up to
// `FormulaParser.maximumExpressionDepth` levels) never exhaust a secondary thread's stack.
extension FormulaExpr {
    public var fieldReferences: Set<String> {
        var references = Set<String>()
        var pending: [FormulaExpr] = [self]
        while let expression = pending.popLast() {
            switch expression {
            case .fieldRef(let reference):
                references.insert(reference)
            case .unary(_, let operand):
                pending.append(operand)
            case .binary(_, let lhs, let rhs):
                pending.append(lhs)
                pending.append(rhs)
            case .call(_, let args):
                pending.append(contentsOf: args)
            case .number, .text, .bool, .variable:
                break
            }
        }
        return references
    }

    public static func == (lhs: FormulaExpr, rhs: FormulaExpr) -> Bool {
        var pending: [(FormulaExpr, FormulaExpr)] = [(lhs, rhs)]
        while let (a, b) = pending.popLast() {
            switch (a, b) {
            case let (.number(x), .number(y)):
                guard x == y else { return false }
            case let (.text(x), .text(y)):
                guard x == y else { return false }
            case let (.bool(x), .bool(y)):
                guard x == y else { return false }
            case let (.fieldRef(x), .fieldRef(y)):
                guard x == y else { return false }
            case let (.variable(x), .variable(y)):
                guard x == y else { return false }
            case let (.unary(opA, operandA), .unary(opB, operandB)):
                guard opA == opB else { return false }
                pending.append((operandA, operandB))
            case let (.binary(opA, lhsA, rhsA), .binary(opB, lhsB, rhsB)):
                guard opA == opB else { return false }
                pending.append((rhsA, rhsB))
                pending.append((lhsA, lhsB))
            case let (.call(nameA, argsA), .call(nameB, argsB)):
                guard nameA == nameB, argsA.count == argsB.count else { return false }
                pending.append(contentsOf: zip(argsA, argsB).reversed())
            default:
                return false
            }
        }
        return true
    }
}

public struct FormulaSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// Offset in `Character`s from the start of the source.
    public var offset: Int

    public init(message: String, offset: Int) {
        self.message = message
        self.offset = offset
    }

    public var description: String { message }
}
