import Foundation

/// Airtable-style identifiers: a three letter prefix followed by 14 base-62 characters.
public enum RowID {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    public static func make(_ prefix: String, length: Int = 14) -> String {
        var generator = SystemRandomNumberGenerator()
        var out = prefix
        out.reserveCapacity(prefix.count + length)
        for _ in 0..<length {
            out.append(alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))])
        }
        return out
    }

    public static func base() -> String { make("app") }
    public static func table() -> String { make("tbl") }
    public static func field() -> String { make("fld") }
    public static func view() -> String { make("viw") }
    public static func record() -> String { make("rec") }
    public static func automation() -> String { make("aut") }
    public static func action() -> String { make("act") }
    public static func comment() -> String { make("com") }
    public static func choice() -> String { make("sel") }
    public static func condition() -> String { make("cnd") }
    public static func attachment() -> String { make("att") }
    public static func run() -> String { make("run") }
}
