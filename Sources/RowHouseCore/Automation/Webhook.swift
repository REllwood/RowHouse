import Foundation

/// Shared constants and helpers for the "When a webhook is received" trigger.
public enum Webhooks {
    public static let defaultPort = 8738
    public static let maxBodyBytes = 1_048_576
    public static let maxHeaderBytes = 16_384

    /// A fresh secret for a webhook URL (about 190 bits from the system's secure generator).
    public static func makeToken() -> String {
        RowID.make("", length: 32)
    }

    /// The address a webhook automation listens on. The server only ever binds to the loopback interface.
    public static func url(automationID: String, token: String, port: Int) -> String {
        "http://127.0.0.1:\(port)\(path(automationID: automationID, token: token))"
    }

    public static func path(automationID: String, token: String) -> String {
        "/hooks/\(automationID)/\(token)"
    }

    /// Splits `/hooks/<automationID>/<token>` into its parts.
    public static func route(_ path: String) -> (automationID: String, token: String)? {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "hooks" else { return nil }
        let id = parts[2], token = parts[3]
        func valid(_ s: String) -> Bool { !s.isEmpty && s.count <= 128 && s.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) } }
        guard valid(id), valid(token) else { return nil }
        return (id, token)
    }

    /// Compares secrets in time that depends only on the expected secret's length.
    public static func constantTimeEquals(_ provided: String, _ expected: String) -> Bool {
        let a = Array(provided.utf8), b = Array(expected.utf8)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<b.count {
            difference |= (i < a.count ? a[i] : 0) ^ b[i]
        }
        return difference == 0
    }

    /// Decodes `a=1&b=two+words&b=x` into an object; repeated names become arrays.
    public static func formValues(_ text: String) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeFormComponent(kv[0])
            guard !key.isEmpty else { continue }
            let value = JSONValue.string(kv.count > 1 ? decodeFormComponent(kv[1]) : "")
            switch out[key] {
            case nil: out[key] = value
            case .array(let existing)?: out[key] = .array(existing + [value])
            case let existing?: out[key] = .array([existing, value])
            }
        }
        return out
    }

    private static func decodeFormComponent(_ s: Substring) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

/// A minimal HTTP/1.1 request as received by the webhook server.
public struct WebhookRequest: Sendable, Equatable {
    public var method: String
    /// Percent-decoded path without the query string.
    public var path: String
    public var query: [String: JSONValue]
    /// Header names are lowercased; repeated headers are joined with ", ".
    public var headers: [String: String]
    public var rawBody: Data
    /// The body decoded from JSON, a form, or plain text (null when there is none).
    public var body: JSONValue

    public init(method: String, path: String, query: [String: JSONValue] = [:], headers: [String: String] = [:], rawBody: Data = Data(), body: JSONValue = .null) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.rawBody = rawBody
        self.body = body
    }

    public struct ParseError: Error, Equatable, Sendable {
        public var status: Int
        public var message: String
    }

    public enum Parsed: Sendable, Equatable {
        case complete(WebhookRequest)
        /// More bytes are needed. `total` is the full request size once the headers have arrived;
        /// `expectsContinue` means the client is waiting for "100 Continue" before sending the body.
        case incomplete(total: Int?, expectsContinue: Bool)
    }

    /// Parses the bytes received so far. Throws for requests that must be rejected.
    public static func parse(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = 0
        var headerEnd: Int?
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                var lineEnd = i
                if lineEnd > lineStart && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                if lineEnd == lineStart {
                    if lines.isEmpty {
                        // Tolerate stray blank lines before the request line.
                        lineStart = i + 1
                    } else {
                        headerEnd = i + 1
                        break
                    }
                } else {
                    lines.append(bytes[lineStart..<lineEnd])
                    lineStart = i + 1
                }
            }
            i += 1
        }
        guard let headerEnd else {
            if bytes.count > Webhooks.maxHeaderBytes { throw ParseError(status: 431, message: "The request headers are too large") }
            return .incomplete(total: nil, expectsContinue: false)
        }
        if headerEnd > Webhooks.maxHeaderBytes { throw ParseError(status: 431, message: "The request headers are too large") }

        let requestLine = text(lines[0]).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }), !requestLine[1].isEmpty else {
            throw ParseError(status: 400, message: "Malformed request line")
        }
        guard requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            throw ParseError(status: 505, message: "Only HTTP/1.1 is supported")
        }
        let method = requestLine[0]

        var headers: [String: String] = [:]
        var contentLengths: Set<String> = []
        for line in lines.dropFirst() {
            guard let first = line.first, first != 0x20, first != 0x09 else {
                throw ParseError(status: 400, message: "Folded header lines aren't supported")
            }
            let raw = text(line)
            guard let colon = raw.firstIndex(of: ":") else { throw ParseError(status: 400, message: "Malformed header line") }
            let name = raw[..<colon]
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
                throw ParseError(status: 400, message: "Malformed header name")
            }
            let key = name.lowercased()
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if key == "content-length" {
                for part in value.split(separator: ",") { contentLengths.insert(part.trimmingCharacters(in: .whitespaces)) }
            }
            headers[key] = headers[key].map { "\($0), \(value)" } ?? value
        }

        if let encoding = headers["transfer-encoding"], encoding.lowercased() != "identity" {
            throw ParseError(status: 411, message: "Chunked bodies aren't supported; send a Content-Length header")
        }
        var length = 0
        if !contentLengths.isEmpty {
            guard contentLengths.count == 1, let declared = contentLengths.first, !declared.isEmpty, declared.count <= 12,
                  declared.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(declared)
            else { throw ParseError(status: 400, message: "Invalid Content-Length") }
            length = n
        } else if method == "POST" {
            throw ParseError(status: 411, message: "POST requests need a Content-Length header")
        }
        if length > Webhooks.maxBodyBytes {
            throw ParseError(status: 413, message: "The body is larger than 1 MB")
        }
        let total = headerEnd + length
        guard bytes.count >= total else {
            let expects = headers["expect"]?.lowercased() == "100-continue"
            return .incomplete(total: total, expectsContinue: expects)
        }

        let (path, queryString) = splitTarget(requestLine[1])
        let rawBody = Data(bytes[headerEnd..<total])
        let request = WebhookRequest(
            method: method,
            path: path,
            query: queryString.map(Webhooks.formValues) ?? [:],
            headers: headers,
            rawBody: rawBody,
            body: try decodeBody(rawBody, contentType: headers["content-type"])
        )
        return .complete(request)
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func splitTarget(_ target: String) -> (path: String, query: String?) {
        var t = Substring(target)
        if let hash = t.firstIndex(of: "#") { t = t[..<hash] }
        // Absolute-form targets ("http://host:port/path") carry the authority; keep only the path.
        if t.first != "/", let scheme = t.range(of: "://") {
            let authorityAndPath = t[scheme.upperBound...]
            t = authorityAndPath.firstIndex(where: { $0 == "/" || $0 == "?" }).map { authorityAndPath[$0...] } ?? "/"
            if t.first == "?" { t = "/" + t }
        }
        let parts = t.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        return (rawPath.removingPercentEncoding ?? rawPath, parts.count > 1 ? String(parts[1]) : nil)
    }

    static func decodeBody(_ data: Data, contentType: String?) throws -> JSONValue {
        guard !data.isEmpty else { return .null }
        let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isJSON = type == "application/json" || type.hasSuffix("+json")
        if isJSON {
            guard let value = try? JSONValue.parse(data) else { throw ParseError(status: 400, message: "The body isn't valid JSON") }
            return value
        }
        let text = String(decoding: data, as: UTF8.self)
        // Tools such as `curl -d` label JSON as a form, so accept JSON whatever the declared type.
        if let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[", let value = try? JSONValue.parse(data) {
            return value
        }
        if type == "application/x-www-form-urlencoded" {
            return .object(Webhooks.formValues(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .string(text)
    }

    /// Values offered to automation steps as `{{trigger.*}}`.
    var scope: [String: JSONValue] {
        [
            "method": .string(method),
            "query": .object(query),
            "headers": .object(headers.mapValues(JSONValue.string)),
            "body": body,
        ]
    }
}

/// A JSON response written back by the webhook server.
public struct WebhookResponse: Sendable, Equatable {
    public var status: Int
    public var body: JSONValue
    public var headers: [String: String]

    public init(status: Int, body: JSONValue, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public static func error(_ status: Int, _ message: String, headers: [String: String] = [:]) -> WebhookResponse {
        WebhookResponse(status: status, body: .object(["ok": .bool(false), "error": .string(message)]), headers: headers)
    }

    /// "HTTP/1.1 100 Continue", sent when a client asks before uploading its body.
    public static let continueBytes = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Error"
        }
    }

    /// The full response, ready to write to the socket. The server closes each connection after it.
    public func serialized() -> Data {
        let payload = body.serialized(sortedKeys: true)
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + payload
    }
}
