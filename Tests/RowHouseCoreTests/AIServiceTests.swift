import Foundation
import Testing
@testable import RowHouseCore

@Suite("Claude AI service", .serialized)
struct AIServiceTests {
    private static let key = "sk-ant-test-key"

    private func makeService(model: String = AIModel.default.rawValue, policy: AIRetryPolicy = AIRetryPolicy(maxRetries: 3, baseDelay: .milliseconds(1), maxDelay: .milliseconds(20))) -> AIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStubURLProtocol.self]
        return AIService(apiKey: Self.key, defaultModel: model, session: URLSession(configuration: configuration), retryPolicy: policy)
    }

    private static func textResponse(_ blocks: String, stopReason: String = "end_turn") -> AIStub.Response {
        .json(#"{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5","content":[\#(blocks)],"stop_reason":"\#(stopReason)","usage":{"input_tokens":10,"output_tokens":5}}"#)
    }

    @Test func requestsUseTheMessagesAPIWithAdaptiveThinkingAndFallbacks() async throws {
        AIStub.shared.reset([Self.textResponse(#"{"type":"text","text":"Paris"}"#)])
        let text = try await makeService().generateText(prompt: "Capital of France?", model: nil)
        #expect(text == "Paris")

        let request = try #require(AIStub.shared.requests.first)
        #expect(request.url == URL(string: "https://api.anthropic.com/v1/messages"))
        #expect(request.method == "POST")
        #expect(request.headers["x-api-key"] == Self.key)
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(request.timeout == 600)

        let body = try JSONValue.parse(request.body)
        #expect(body["model"] == "claude-opus-5")
        #expect(body["max_tokens"] == 16000)
        #expect(body["thinking"] == ["type": "adaptive"])
        #expect(body["fallbacks"] == "default")
        #expect(body["system"]?.stringValue?.contains("only that value") == true)
        #expect(body["messages"] == [["role": "user", "content": "Capital of France?"]])
    }

    @Test func haikuRequestsLeaveOutThinkingAndFallbacks() async throws {
        AIStub.shared.reset([Self.textResponse(#"{"type":"text","text":"ok"}"#)])
        _ = try await makeService().generateText(prompt: "Hi", model: "claude-haiku-4-5")
        let request = try #require(AIStub.shared.requests.first)
        #expect(request.headers["anthropic-beta"] == nil)
        let body = try JSONValue.parse(request.body)
        #expect(body["model"] == "claude-haiku-4-5")
        #expect(body["max_tokens"] == 16000)
        #expect(body["thinking"] == nil)
        #expect(body["fallbacks"] == nil)

        AIStub.shared.reset([Self.textResponse(#"{"type":"text","text":"ok"}"#)])
        _ = try await makeService(model: "claude-sonnet-5").generateText(prompt: "Hi", model: " ")
        let sonnet = try JSONValue.parse(try #require(AIStub.shared.requests.first).body)
        #expect(sonnet["model"] == "claude-sonnet-5")
        #expect(sonnet["thinking"] == ["type": "adaptive"])
    }

    @Test func textBlocksAreJoinedAndThinkingIsSkipped() async throws {
        AIStub.shared.reset([Self.textResponse(#"""
            {"type":"thinking","thinking":"","signature":"sig"},
            {"type":"text","text":"  Hello, "},
            {"type":"fallback","from":{"model":"claude-opus-5"},"to":{"model":"claude-opus-4-8"}},
            {"type":"text","text":"world.\n"}
            """#)])
        #expect(try await makeService().generateText(prompt: "Greet", model: nil) == "Hello, world.")
    }

    @Test func refusalsAreReportedWithoutReadingContent() async throws {
        AIStub.shared.reset([.json(#"{"type":"message","content":[{"type":"text","text":"partial"}],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#)])
        await #expect(throws: AIServiceError.refusal(category: "cyber")) {
            try await makeService().generateText(prompt: "x", model: nil)
        }
        #expect(AIStub.shared.requests.count == 1)
        #expect(throws: AIServiceError.refusal(category: nil)) {
            try AIService.parseResponse(Data(#"{"content":[],"stop_reason":"refusal","stop_details":null}"#.utf8))
        }
        #expect(throws: AIServiceError.emptyResponse) {
            try AIService.parseResponse(Data(#"{"content":[{"type":"thinking","thinking":"hm"}],"stop_reason":"end_turn"}"#.utf8))
        }
        #expect(throws: AIServiceError.invalidResponse) {
            try AIService.parseResponse(Data("not json".utf8))
        }
    }

    @Test func overloadedResponsesAreRetriedHonouringRetryAfter() async throws {
        AIStub.shared.reset([
            .json(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529, headers: ["retry-after": "0"]),
            Self.textResponse(#"{"type":"text","text":"Recovered"}"#),
        ])
        // A long backoff proves the zero-second retry-after header was used instead.
        let service = makeService(policy: AIRetryPolicy(maxRetries: 3, baseDelay: .seconds(30), maxDelay: .seconds(60)))
        let start = ContinuousClock.now
        #expect(try await service.generateText(prompt: "x", model: nil) == "Recovered")
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(AIStub.shared.requests.count == 2)
    }

    @Test func networkErrorsAndServerErrorsAreRetriedUpToThreeTimes() async throws {
        AIStub.shared.reset([.failure(.networkConnectionLost), Self.textResponse(#"{"type":"text","text":"ok"}"#)])
        #expect(try await makeService().generateText(prompt: "x", model: nil) == "ok")
        #expect(AIStub.shared.requests.count == 2)

        AIStub.shared.reset([.json(#"{"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#, status: 500)])
        await #expect(throws: AIServiceError.api(status: 500, message: "Internal server error")) {
            try await makeService().generateText(prompt: "x", model: nil)
        }
        #expect(AIStub.shared.requests.count == 4)

        AIStub.shared.reset([.json(#"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}"#, status: 429, headers: ["retry-after": "0"])])
        await #expect(throws: AIServiceError.api(status: 429, message: "Slow down")) {
            try await makeService().generateText(prompt: "x", model: nil)
        }
        #expect(AIStub.shared.requests.count == 4)
    }

    @Test func clientErrorsSurfaceTheAPIMessageWithoutRetrying() async throws {
        AIStub.shared.reset([.json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401)])
        do {
            _ = try await makeService().generateText(prompt: "x", model: nil)
            Issue.record("Expected an error")
        } catch let error as AIServiceError {
            #expect(error == .api(status: 401, message: "invalid x-api-key"))
            #expect(error.localizedDescription.contains("invalid x-api-key"))
            #expect(error.stopsBatch)
        }
        #expect(AIStub.shared.requests.count == 1)

        for status in [400, 403, 404, 413] {
            AIStub.shared.reset([.json(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad \#(status)"}}"#, status: status)])
            await #expect(throws: AIServiceError.api(status: status, message: "bad \(status)")) {
                try await makeService().generateText(prompt: "x", model: nil)
            }
            #expect(AIStub.shared.requests.count == 1)
        }
    }

    @Test func aMissingKeyFailsBeforeAnyRequest() async throws {
        AIStub.shared.reset([])
        let service = AIService(apiKey: "  ")
        await #expect(throws: AIServiceError.missingAPIKey) {
            try await service.generateText(prompt: "x", model: nil)
        }
        #expect(AIStub.shared.requests.isEmpty)
        #expect(!String(describing: Mirror(reflecting: makeService()).children.map(\.value)).contains(Self.key))
    }
}

@Suite("AI fields")
@MainActor
struct AIFieldTests {
    private func makeTable() throws -> (BaseDocument, table: String, name: String, notes: String, ai: FieldModel) {
        let doc = TestSupport.document()
        let table = doc.createTable(name: "Products", starterFields: false, emptyRecords: 0)
        let name = try #require(doc.primaryField(of: table)).id
        doc.renameField(name, to: "Name")
        let notes = doc.createField(in: table, name: "Notes", type: .multilineText)
        var options = FieldOptions()
        options.aiPrompt = "Write a tagline for {Name}. Don't mention \\{price\\}. Notes: {Notes}"
        options.aiModel = "claude-sonnet-5"
        let ai = try #require(doc.field(doc.createField(in: table, name: "Tagline", type: .aiText, options: options)))
        return (doc, table, name, notes, ai)
    }

    @Test func promptsStoreFieldIDsAndRenderRecordValues() throws {
        let (doc, table, name, notes, ai) = try makeTable()
        #expect(ai.options.aiPrompt == "Write a tagline for {\(name)}. Don't mention \\{price\\}. Notes: {\(notes)}")
        #expect(doc.aiPromptWithFieldNames(ai.options.aiPrompt ?? "", tableID: table) == "Write a tagline for {Name}. Don't mention \\{price\\}. Notes: {Notes}")

        doc.renameField(notes, to: "Details")
        #expect(doc.aiPromptWithFieldNames(ai.options.aiPrompt ?? "", tableID: table).hasSuffix("Notes: {Details}"))

        let r = doc.createRecord(in: table, values: [name: "Lamp", notes: "Warm light"])
        let record = try #require(doc.record(r))
        #expect(try doc.renderAIPrompt(field: ai, record: record) == "Write a tagline for Lamp. Don't mention {price}. Notes: Warm light")

        #expect(doc.validateAIPrompt("Use {Name} and {Nope}", tableID: table) == "Unknown field {Nope}")
        #expect(doc.validateAIPrompt("Use {Tagline}", tableID: table, excludingFieldID: ai.id) == "The prompt can't refer to this field itself")
        #expect(doc.validateAIPrompt("   ", tableID: table) == "Write a prompt")
        #expect(doc.validateAIPrompt("It's {Name}'s turn", tableID: table) == nil)
        #expect(PromptTemplate.references(in: "a {b} {c\nd} {} \\{e}") == ["b"])
    }

    @Test func unknownReferencesFailBeforeCallingClaude() async throws {
        let (doc, table, name, _, ai) = try makeTable()
        var options = ai.options
        options.aiPrompt = "Describe {Name} using {Missing}"
        doc.updateField(ai.id, options: options)
        let r = doc.createRecord(in: table, values: [name: "Lamp"])
        let generator = RecordingGenerator(reply: "unused")
        await #expect(throws: AIServiceError.unknownFieldReference("Missing")) {
            try await doc.generateAIValue(recordID: r, fieldID: ai.id, using: generator)
        }
        #expect(generator.prompts.isEmpty)
    }

    @Test func generatedValuesAreStoredAndEditable() async throws {
        let (doc, table, name, _, ai) = try makeTable()
        let r = doc.createRecord(in: table, values: [name: "Lamp"])
        let generator = RecordingGenerator(reply: "Light up your evenings.")
        let text = try await doc.generateAIValue(recordID: r, fieldID: ai.id, using: generator)
        #expect(text == "Light up your evenings.")
        #expect(doc.record(r)?[ai.id] == "Light up your evenings.")
        #expect(generator.prompts == ["Write a tagline for Lamp. Don't mention {price}. Notes: "])
        #expect(generator.models == ["claude-sonnet-5"])

        doc.setCell(recordID: r, fieldID: ai.id, text: "Edited by hand")
        #expect(doc.displayString(try #require(doc.record(r)), ai) == "Edited by hand")
    }

    @Test func batchesFillEveryRecordAndReportFailures() async throws {
        let (doc, table, name, _, ai) = try makeTable()
        let ids = doc.createRecords(in: table, values: (1...5).map { [name: .string("Item \($0)")] })
        let generator = RecordingGenerator(reply: "Tagline", failingPrompts: ["Item 3"])
        var progress: [Int] = []
        let result = await doc.generateAIValues(fieldID: ai.id, recordIDs: ids, using: generator, maxConcurrent: 2) { done, _ in progress.append(done) }
        #expect(result.generated == 4)
        #expect(result.failures.map(\.recordID) == [ids[2]])
        #expect(ids.enumerated().allSatisfy { i, id in doc.record(id)?[ai.id] == (i == 2 ? .null : "Tagline") })
        #expect(progress == [0, 1, 2, 3, 4, 5])

        let rejected = RecordingGenerator(reply: "", error: .api(status: 401, message: "invalid x-api-key"))
        let stopped = await doc.generateAIValues(fieldID: ai.id, recordIDs: ids, using: rejected, maxConcurrent: 1)
        #expect(stopped.generated == 0)
        #expect(stopped.failures.count == 5)
        #expect(rejected.prompts.count == 1)
    }
}

/// Returns a fixed reply (or error) and remembers what it was asked.
private final class RecordingGenerator: AITextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: String
    private let failing: [String]
    private let error: AIServiceError?
    private var _prompts: [String] = []
    private var _models: [String?] = []

    init(reply: String, failingPrompts: [String] = [], error: AIServiceError? = nil) {
        self.reply = reply
        self.failing = failingPrompts
        self.error = error
    }

    var prompts: [String] { lock.withLock { _prompts } }
    var models: [String?] { lock.withLock { _models } }

    func generateText(prompt: String, model: String?) async throws -> String {
        lock.withLock {
            _prompts.append(prompt)
            _models.append(model)
        }
        if let error { throw error }
        if failing.contains(where: { prompt.contains($0) }) { throw AIServiceError.emptyResponse }
        return reply
    }
}

// MARK: - URL stub

private final class AIStub: @unchecked Sendable {
    enum Response: Sendable {
        case http(status: Int, body: Data, headers: [String: String])
        case failure(URLError.Code)

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            .http(status: status, body: Data(text.utf8), headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a })
        }
    }

    struct Request: Sendable {
        var url: URL?
        var method: String?
        var headers: [String: String]
        var body: Data
        var timeout: TimeInterval
    }

    static let shared = AIStub()
    private let lock = NSLock()
    private var queue: [Response] = []
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }

    /// Responses are served in order; the last one repeats.
    func reset(_ responses: [Response]) {
        lock.withLock {
            queue = responses
            recorded = []
        }
    }

    func respond(to request: URLRequest) -> Response {
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key.lowercased()] = value }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        return lock.withLock {
            recorded.append(Request(url: request.url, method: request.httpMethod, headers: headers, body: body, timeout: request.timeoutInterval))
            guard let first = queue.first else { return .json("{}", status: 599) }
            if queue.count > 1 { queue.removeFirst() }
            return first
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class AIStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        switch AIStub.shared.respond(to: request) {
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
