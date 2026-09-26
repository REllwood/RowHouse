import Foundation

/// The value of a barcode cell, stored as `{"text": String, "type": String?}`. Plain strings are
/// accepted too (from scripts, pastes and older data) and read as text with no symbology.
public struct BarcodeValue: Hashable, Sendable {
    public var text: String
    /// Symbology, e.g. "code128", "qr", "ean13". Nil when unknown.
    public var type: String?

    public init(text: String, type: String? = nil) {
        self.text = text
        self.type = type.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init?(json: JSONValue) {
        switch json {
        case .string(let s):
            guard !s.isEmpty else { return nil }
            self.init(text: s)
        case .object(let o):
            let text = o["text"]?.stringValue ?? o["text"]?.numberValue.map(ValueParsing.editableNumber) ?? ""
            guard !text.isEmpty else { return nil }
            self.init(text: text, type: o["type"]?.stringValue)
        case .number(let n):
            self.init(text: ValueParsing.editableNumber(n))
        default:
            return nil
        }
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["text": .string(text)]
        if let type { object["type"] = .string(type) }
        return .object(object)
    }

    /// Whether the value should be drawn as a two-dimensional QR code.
    public var isQRCode: Bool { type?.lowercased() == "qr" }

    /// Symbologies offered when editing a barcode. Others (from imports) are kept as they are.
    public static let knownTypes: [(id: String, name: String)] = [
        ("code128", "Code 128"),
        ("qr", "QR code"),
        ("ean13", "EAN-13"),
        ("ean8", "EAN-8"),
        ("upce", "UPC-E"),
        ("code39", "Code 39"),
    ]

    public static func displayName(forType type: String?) -> String {
        guard let type, !type.isEmpty else { return "Automatic" }
        return knownTypes.first { $0.id.caseInsensitiveCompare(type) == .orderedSame }?.name ?? type.uppercased()
    }
}
