import Foundation

/// Builds the AppleScript the app runs to send automation emails through Apple Mail, and checks
/// recipient lists before anything is handed to Mail.
public enum MailScript {
    /// Error number the script raises when Mail has no enabled account.
    public static let noAccountErrorNumber = 1001

    public struct InvalidAddress: Error, Equatable, Sendable {
        public var address: String
        public var message: String { "“\(address)” isn't a valid email address" }
    }

    /// Splits a comma- or semicolon-separated recipient list. Accepts `Name <address>` entries and
    /// returns just the addresses.
    public static func addresses(from text: String) throws -> [String] {
        var out: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            var entry = part.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if let open = entry.lastIndex(of: "<"), let close = entry[open...].firstIndex(of: ">") {
                entry = entry[entry.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            }
            guard isValidAddress(entry) else { throw InvalidAddress(address: String(part.trimmingCharacters(in: .whitespaces))) }
            if !out.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) { out.append(entry) }
        }
        return out
    }

    /// A deliberately loose check: one "@", a plausible domain, and no characters that can't
    /// appear unquoted in an address.
    public static func isValidAddress(_ address: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "\"<>(),;:\\[]").union(.whitespacesAndNewlines).union(.controlCharacters)
        guard address.count <= 254, address.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return false }
        let local = parts[0], domain = parts[1]
        guard !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
    }

    /// An AppleScript string literal (including the surrounding quotes) for any text.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // Other control characters can't be typed into a script and never belong in an email.
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A script that creates and sends one message from Mail's default account. It returns
    /// `true` when Mail accepted the message for sending.
    public static func sendScript(to: [String], cc: [String], bcc: [String], subject: String, body: String) -> String {
        var recipients: [String] = []
        for (kind, list) in [("to", to), ("cc", cc), ("bcc", bcc)] {
            for address in list {
                recipients.append("            make new \(kind) recipient at end of \(kind) recipients with properties {address:\(quoted(address))}")
            }
        }
        return """
        with timeout of 60 seconds
            tell application id "com.apple.mail"
                if (count of (every account whose enabled is true)) is 0 then error "Mail has no email account set up." number \(noAccountErrorNumber)
                set newMessage to make new outgoing message with properties {subject:\(quoted(subject)), content:\(quoted(body)), visible:false}
                tell newMessage
        \(recipients.joined(separator: "\n"))
                    set didSend to send
                end tell
                return didSend
            end tell
        end timeout
        """
    }
}
