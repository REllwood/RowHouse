import Foundation

struct FormulaToken: Equatable {
    enum Kind: Equatable {
        case number(Double)
        case string(String)
        case fieldRef(String)
        case identifier(String)
        case leftParen
        case rightParen
        case comma
        /// Canonical operator spelling: `<>` is reported as `!=`.
        case op(String)
        case end
        /// Lexing stopped here; the parser reports this error when it reaches the token.
        case invalid(FormulaSyntaxError)
    }

    var kind: Kind
    /// Character offsets into the source, `start..<end`.
    var start: Int
    var end: Int
}

/// Splits formula source into tokens. Offsets are measured in `Character`s. Tokenizing never throws:
/// the token list always ends with `.end` or, if the source is malformed, `.invalid`.
enum FormulaLexer {
    static func tokenize(_ characters: [Character]) -> [FormulaToken] {
        var lexer = Lexer(characters: characters)
        return lexer.run()
    }

    private struct Lexer {
        let characters: [Character]
        var index = 0
        var tokens: [FormulaToken] = []

        init(characters: [Character]) {
            self.characters = characters
        }

        mutating func run() -> [FormulaToken] {
            while true {
                if let error = skipTrivia() {
                    tokens.append(FormulaToken(kind: .invalid(error), start: error.offset, end: characters.count))
                    return tokens
                }
                guard index < characters.count else {
                    tokens.append(FormulaToken(kind: .end, start: index, end: index))
                    return tokens
                }
                let start = index
                switch lexToken() {
                case .success(let kind):
                    tokens.append(FormulaToken(kind: kind, start: start, end: index))
                case .failure(let error):
                    tokens.append(FormulaToken(kind: .invalid(error), start: error.offset, end: characters.count))
                    return tokens
                }
            }
        }

        private func peek(_ offset: Int = 0) -> Character? {
            let position = index + offset
            return position < characters.count ? characters[position] : nil
        }

        private mutating func skipTrivia() -> FormulaSyntaxError? {
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace {
                    index += 1
                } else if character == "/", peek(1) == "*" {
                    let start = index
                    index += 2
                    var closed = false
                    while index < characters.count {
                        if characters[index] == "*", peek(1) == "/" {
                            index += 2
                            closed = true
                            break
                        }
                        index += 1
                    }
                    if !closed {
                        return FormulaSyntaxError(message: "Unterminated comment", offset: start)
                    }
                } else {
                    break
                }
            }
            return nil
        }

        private mutating func lexToken() -> Result<FormulaToken.Kind, FormulaSyntaxError> {
            let start = index
            let character = characters[index]
            switch character {
            case "(":
                index += 1
                return .success(.leftParen)
            case ")":
                index += 1
                return .success(.rightParen)
            case ",":
                index += 1
                return .success(.comma)
            case "+", "-", "*", "/", "&", "=":
                index += 1
                return .success(.op(String(character)))
            case "!":
                if peek(1) == "=" {
                    index += 2
                    return .success(.op("!="))
                }
                return .failure(FormulaSyntaxError(message: "Unexpected character \"!\"", offset: start))
            case "<":
                if peek(1) == "=" {
                    index += 2
                    return .success(.op("<="))
                }
                if peek(1) == ">" {
                    index += 2
                    return .success(.op("!="))
                }
                index += 1
                return .success(.op("<"))
            case ">":
                if peek(1) == "=" {
                    index += 2
                    return .success(.op(">="))
                }
                index += 1
                return .success(.op(">"))
            case "{":
                return lexFieldReference()
            case "\"", "'", "\u{201C}", "\u{2018}":
                return lexString()
            default:
                if Self.isDigit(character) || (character == "." && peek(1).map(Self.isDigit) == true) {
                    return lexNumber()
                }
                if Self.isIdentifierStart(character) {
                    while let next = peek(), Self.isIdentifierContinuation(next) {
                        index += 1
                    }
                    return .success(.identifier(String(characters[start..<index])))
                }
                return .failure(FormulaSyntaxError(message: "Unexpected character \"\(character)\"", offset: start))
            }
        }

        private mutating func lexFieldReference() -> Result<FormulaToken.Kind, FormulaSyntaxError> {
            let start = index
            var cursor = index + 1
            while cursor < characters.count, characters[cursor] != "}" {
                cursor += 1
            }
            guard cursor < characters.count else {
                return .failure(FormulaSyntaxError(message: "Unterminated field reference", offset: start))
            }
            let name = String(characters[(start + 1)..<cursor])
            guard !name.isEmpty else {
                return .failure(FormulaSyntaxError(message: "Empty field reference", offset: start))
            }
            index = cursor + 1
            return .success(.fieldRef(name))
        }

        private mutating func lexString() -> Result<FormulaToken.Kind, FormulaSyntaxError> {
            let start = index
            let opening = characters[index]
            // Smart quotes (inserted by macOS text substitution) are accepted as delimiters.
            let closing: Set<Character>
            switch opening {
            case "\u{201C}": closing = ["\u{201D}", "\u{201C}"]
            case "\u{2018}": closing = ["\u{2019}", "\u{2018}"]
            default: closing = [opening]
            }
            index += 1
            var value = ""
            while index < characters.count {
                let character = characters[index]
                if closing.contains(character) {
                    index += 1
                    return .success(.string(value))
                }
                if character == "\\" {
                    guard let escaped = peek(1) else { break }
                    switch escaped {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "r": value.append("\r")
                    case "\\", "\"", "'": value.append(escaped)
                    default:
                        // Unknown escapes are kept verbatim so regular expressions like "\d+" work unescaped.
                        if closing.contains(escaped) {
                            value.append(escaped)
                        } else {
                            value.append("\\")
                            value.append(escaped)
                        }
                    }
                    index += 2
                    continue
                }
                value.append(character)
                index += 1
            }
            return .failure(FormulaSyntaxError(message: "Unterminated string", offset: start))
        }

        private mutating func lexNumber() -> Result<FormulaToken.Kind, FormulaSyntaxError> {
            let start = index
            while let character = peek(), Self.isDigit(character) {
                index += 1
            }
            if peek() == "." {
                index += 1
                while let character = peek(), Self.isDigit(character) {
                    index += 1
                }
            }
            if let marker = peek(), marker == "e" || marker == "E" {
                var lookahead = 1
                if let sign = peek(1), sign == "+" || sign == "-" {
                    lookahead = 2
                }
                if let digit = peek(lookahead), Self.isDigit(digit) {
                    index += lookahead
                    while let character = peek(), Self.isDigit(character) {
                        index += 1
                    }
                }
            }
            let literal = String(characters[start..<index])
            guard let value = Double(literal), value.isFinite else {
                return .failure(FormulaSyntaxError(message: "Number \(literal) is out of range", offset: start))
            }
            return .success(.number(value))
        }

        static func isDigit(_ character: Character) -> Bool {
            character.isASCII && character.isWholeNumber
        }

        static func isIdentifierStart(_ character: Character) -> Bool {
            character == "_" || character.isLetter
        }

        static func isIdentifierContinuation(_ character: Character) -> Bool {
            character == "_" || character.isLetter || isDigit(character)
        }
    }
}
