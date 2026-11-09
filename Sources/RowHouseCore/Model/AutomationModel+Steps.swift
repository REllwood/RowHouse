import Foundation

extension AutomationModel {
    /// Swaps two steps, keeping every reference to steps by number pointing at the same steps:
    /// "repeat for each" sources and `{{steps.N…}}` tokens in any step's text.
    public mutating func swapActions(_ i: Int, _ j: Int) {
        guard actions.indices.contains(i), actions.indices.contains(j), i != j else { return }
        actions.swapAt(i, j)
        let a = i + 1, b = j + 1
        renumberSteps { $0 == a ? b : $0 == b ? a : $0 }
    }

    /// Removes a step. Later steps move up a number, and references to the removed step stop pointing
    /// anywhere: its tokens become `{{steps.deleted…}}`, which render empty, and "repeat for each" turns off.
    public mutating func removeAction(at index: Int) {
        guard actions.indices.contains(index) else { return }
        actions.remove(at: index)
        let removed = index + 1
        renumberSteps { $0 == removed ? nil : $0 > removed ? $0 - 1 : $0 }
    }

    /// Applies a renumbering of steps (1-based, nil for a removed step) to every reference.
    mutating func renumberSteps(_ number: (Int) -> Int?) {
        for i in actions.indices {
            if let from = actions[i].repeatFrom {
                if let moved = number(from) {
                    actions[i].repeatFrom = moved
                } else {
                    actions[i].repeatFrom = nil
                    actions[i].repeatPath = nil
                }
            }
            let encoded = JSONValue(encoding: actions[i])
            let renumbered = encoded.mappingStrings { Self.renumberingTokens(in: $0, number) }
            if renumbered != encoded, let action = renumbered.decode(AutomationAction.self) {
                actions[i] = action
            }
        }
    }

    private static let stepToken = try! NSRegularExpression(pattern: #"(\{\{\s*steps\.)(\d+)(?=[.\s|}])"#)

    static func renumberingTokens(in text: String, _ number: (Int) -> Int?) -> String {
        guard text.contains("steps.") else { return text }
        let ns = text as NSString
        var result = text
        for match in stepToken.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let old = Int(ns.substring(with: match.range(at: 2))) else { continue }
            let replacement = number(old).map(String.init) ?? "deleted"
            result = (result as NSString).replacingCharacters(in: match.range(at: 2), with: replacement)
        }
        return result
    }
}

private extension JSONValue {
    func mappingStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let s): .string(transform(s))
        case .array(let items): .array(items.map { $0.mappingStrings(transform) })
        case .object(let fields): .object(fields.mapValues { $0.mappingStrings(transform) })
        default: self
        }
    }
}
