import Foundation

public enum FormulaSource: Sendable {
    /// Rewrites every field reference (braced `{Name}` and bare-identifier references) using `transform`.
    /// References for which `transform` returns nil, an empty string, or text containing `}` (which cannot be
    /// written in braces), are left untouched. Everything else — strings, comments, whitespace, function
    /// names — is preserved exactly. Malformed source is rewritten up to the first lexical error and
    /// copied verbatim after it.
    public static func rewriteFieldReferences(
        in source: String,
        variables: Set<String> = [],
        _ transform: (String) -> String?
    ) -> String {
        let characters = Array(source)
        let tokens = FormulaLexer.tokenize(characters)
        let variableNames = Set(variables.map { $0.uppercased() })

        var output = ""
        output.reserveCapacity(source.utf8.count)
        var copiedUpTo = 0
        for (index, token) in tokens.enumerated() {
            let reference: String
            switch token.kind {
            case .fieldRef(let name):
                reference = name
            case .identifier(let name):
                if case .leftParen = tokens[index + 1].kind { continue }
                let uppercased = name.uppercased()
                if uppercased == "TRUE" || uppercased == "FALSE" || variableNames.contains(uppercased) { continue }
                reference = name
            default:
                continue
            }
            guard let replacement = transform(reference), !replacement.isEmpty, !replacement.contains("}") else { continue }
            output += String(characters[copiedUpTo..<token.start])
            output += "{" + replacement + "}"
            copiedUpTo = token.end
        }
        output += String(characters[copiedUpTo...])
        return output
    }
}
