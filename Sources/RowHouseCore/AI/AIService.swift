import Foundation

/// Something that turns a prompt into text. `AIService` talks to Claude; tests and previews can
/// substitute their own.
public protocol AITextGenerating: Sendable {
    /// Generates text for `prompt`. `model` overrides the generator's default model when set.
    func generateText(prompt: String, model: String?) async throws -> String
}

/// Claude models RowHouse offers in Settings and in AI field options.
public enum AIModel: String, CaseIterable, Sendable, Identifiable {
    case opus5 = "claude-opus-5"
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"

    public static let `default` = AIModel.opus5

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus5: "Claude Opus 5"
        case .sonnet5: "Claude Sonnet 5"
        case .haiku45: "Claude Haiku 4.5"
        }
    }

    public static func displayName(for id: String) -> String {
        AIModel(rawValue: id)?.displayName ?? id
    }

    /// Haiku 4.5 predates adaptive thinking and server-side fallbacks, so requests to it leave both out.
    public static func supportsAdaptiveThinking(_ id: String) -> Bool {
        !id.hasPrefix("claude-haiku-4")
    }
}

public enum AIServiceError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case emptyPrompt
    case unknownFieldReference(String)
    case selfReference
    case fieldUnavailable
    /// Claude declined the request. `category` is the refusal category, when the API gives one.
    case refusal(category: String?)
    case api(status: Int, message: String)
    case network(String)
    case invalidResponse
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Anthropic API key in Settings › Claude AI to generate AI values."
        case .emptyPrompt:
            "This AI field has no prompt yet. Add one in the field settings."
        case .unknownFieldReference(let name):
            "The prompt refers to {\(name)}, which isn't a field in this table."
        case .selfReference:
            "An AI field's prompt can't refer to the field itself."
        case .fieldUnavailable:
            "The record or field no longer exists."
        case .refusal(let category):
            "Claude declined to answer this prompt" + (category.map { " (\($0))" } ?? "") + ". Try rewording it."
        case .api(let status, let message):
            "Claude returned an error (HTTP \(status)): \(message)"
        case .network(let description):
            "Couldn't reach Claude: \(description)"
        case .invalidResponse:
            "Claude sent a response RowHouse couldn't read."
        case .emptyResponse:
            "Claude didn't return any text for this prompt."
        }
    }

    /// Errors that will fail every request the same way, so a batch should stop instead of repeating them.
    public var stopsBatch: Bool {
        switch self {
        case .missingAPIKey: true
        case .api(let status, _): [400, 401, 403, 404].contains(status)
        default: false
        }
    }
}

/// How `AIService` retries rate limits, overloads, server errors and dropped connections.
public struct AIRetryPolicy: Sendable {
    /// Retries after the first attempt.
    public var maxRetries: Int
    /// Delay before the first retry; each later retry waits twice as long.
    public var baseDelay: Duration
    /// Upper bound for any single wait, including one asked for by a `retry-after` header.
    public var maxDelay: Duration

    public init(maxRetries: Int = 3, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(60)) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let standard = AIRetryPolicy()

    func delay(afterAttempt attempt: Int, retryAfter: Duration?) -> Duration {
        if let retryAfter { return min(retryAfter, maxDelay) }
        return min(baseDelay * (1 << min(attempt, 16)), maxDelay)
    }
}

/// Calls the Claude Messages API over HTTPS. The API key is held in memory only and never logged;
/// neither are prompts or responses.
public final class AIService: AITextGenerating {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let maxTokens = 16_000
    public static let timeout: TimeInterval = 600
    public static let systemPrompt = """
        You produce the value of one field in a database record. Reply with only that value: no preamble, \
        no explanation, no surrounding quotation marks and no Markdown code fences.
        """

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let apiKey: String
    public let defaultModel: String
    private let session: URLSession
    private let retryPolicy: AIRetryPolicy

    public init(apiKey: String, defaultModel: String = AIModel.default.rawValue, session: URLSession? = nil, retryPolicy: AIRetryPolicy = .standard) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultModel = defaultModel
        self.session = session ?? Self.defaultSession
        self.retryPolicy = retryPolicy
    }

    public func generateText(prompt: String, model: String? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw AIServiceError.missingAPIKey }
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = Self.makeRequest(prompt: prompt, model: trimmedModel?.isEmpty == false ? trimmedModel! : defaultModel, apiKey: apiKey)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
                guard attempt < retryPolicy.maxRetries, Self.isTransient(error) else {
                    throw AIServiceError.network(error.localizedDescription)
                }
                try await Task.sleep(for: retryPolicy.delay(afterAttempt: attempt, retryAfter: nil))
                attempt += 1
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                return try Self.parseResponse(data)
            case 429, 500...599:
                guard attempt < retryPolicy.maxRetries else {
                    throw AIServiceError.api(status: http.statusCode, message: Self.errorMessage(data) ?? Self.statusText(http.statusCode))
                }
                try await Task.sleep(for: retryPolicy.delay(afterAttempt: attempt, retryAfter: Self.retryAfter(http)))
                attempt += 1
            default:
                throw AIServiceError.api(status: http.statusCode, message: Self.errorMessage(data) ?? Self.statusText(http.statusCode))
            }
        }
    }

    // MARK: - Request

    public static func makeRequest(prompt: String, model: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if AIModel.supportsAdaptiveThinking(model) {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = requestBody(prompt: prompt, model: model).serialized()
        return request
    }

    public static func requestBody(prompt: String, model: String) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "system": .string(systemPrompt),
            "messages": .array([.object(["role": "user", "content": .string(prompt)])]),
        ]
        if AIModel.supportsAdaptiveThinking(model) {
            body["thinking"] = .object(["type": "adaptive"])
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    // MARK: - Response

    /// Text of a successful Messages API response. A refusal is reported before any content is read;
    /// otherwise every text block is joined, skipping thinking and other block types.
    public static func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONValue.parse(data), json.objectValue != nil else { throw AIServiceError.invalidResponse }
        if json["stop_reason"]?.stringValue == "refusal" {
            throw AIServiceError.refusal(category: json["stop_details"]?["category"]?.stringValue)
        }
        guard let content = json["content"]?.arrayValue else { throw AIServiceError.invalidResponse }
        let text = content
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIServiceError.emptyResponse }
        return text
    }

    static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONValue.parse(data), let error = json["error"] else { return nil }
        let message = error["message"]?.stringValue ?? error.stringValue
        return message.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func statusText(_ status: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }

    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let header = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            return .milliseconds(Int((seconds * 1000).rounded()))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return .milliseconds(Int(max(0, date.timeIntervalSinceNow) * 1000))
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        let transient: Set<URLError.Code> = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .notConnectedToInternet, .badServerResponse, .secureConnectionFailed, .cannotLoadFromNetwork,
        ]
        return transient.contains(code)
    }
}

extension AIService: CustomReflectable {
    /// Keeps the API key out of `dump()` and debugger descriptions.
    public var customMirror: Mirror { Mirror(self, children: ["defaultModel": defaultModel]) }
}
