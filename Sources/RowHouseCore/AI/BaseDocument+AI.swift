import Foundation

/// `{Field}` references in prose. Unlike formulas, prompts are free text: quotes and apostrophes
/// mean nothing and bare words are never references. `\{` writes a literal brace.
public enum PromptTemplate {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case reference(String)
    }

    public static func pieces(of source: String) -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        var index = source.startIndex
        while index < source.endIndex {
            let c = source[index]
            let next = source.index(after: index)
            if c == "\\", next < source.endIndex, source[next] == "{" || source[next] == "}" {
                text.append(source[next])
                index = source.index(after: next)
                continue
            }
            if c == "{", let close = source[next...].firstIndex(where: { $0 == "}" || $0 == "{" || $0 == "\n" }), source[close] == "}" {
                let name = String(source[next..<close])
                if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !text.isEmpty { pieces.append(.text(text)) }
                    text = ""
                    pieces.append(.reference(name))
                    index = source.index(after: close)
                    continue
                }
            }
            text.append(c)
            index = next
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    public static func references(in source: String) -> [String] {
        pieces(of: source).compactMap { if case .reference(let name) = $0 { name } else { nil } }
    }

    /// Rewrites references with `transform`, leaving the rest of the text (and escapes) untouched.
    /// References `transform` returns nil for, or that can't be written in braces, stay as they are.
    public static func rewriteReferences(in source: String, _ transform: (String) -> String?) -> String {
        var out = ""
        var index = source.startIndex
        while index < source.endIndex {
            let c = source[index]
            let next = source.index(after: index)
            if c == "\\", next < source.endIndex, source[next] == "{" || source[next] == "}" {
                out += source[index...next]
                index = source.index(after: next)
                continue
            }
            if c == "{", let close = source[next...].firstIndex(where: { $0 == "}" || $0 == "{" || $0 == "\n" }), source[close] == "}" {
                let name = String(source[next..<close])
                if let replacement = transform(name), !replacement.isEmpty,
                   !replacement.contains("}"), !replacement.contains("{"), !replacement.contains("\n") {
                    out += "{" + replacement + "}"
                } else {
                    out += source[index...close]
                }
                index = source.index(after: close)
                continue
            }
            out.append(c)
            index = next
        }
        return out
    }
}

/// One record an AI batch couldn't fill.
public struct AIGenerationFailure: Hashable, Sendable {
    public var recordID: String
    public var message: String
}

public struct AIBatchResult: Sendable {
    public var generated = 0
    public var failures: [AIGenerationFailure] = []

    public init() {}
}

extension BaseDocument {
    // MARK: - Prompt references

    /// Rewrites `{Field Name}` references to `{fldID}` so prompts survive field renames.
    public func aiPromptWithFieldIDs(_ source: String, tableID: String) -> String {
        PromptTemplate.rewriteReferences(in: source) { ref in
            if let f = self.field(ref), f.tableID == tableID { return f.id }
            return self.field(named: ref, in: tableID)?.id
        }
    }

    /// Rewrites `{fldID}` references to `{Field Name}` for editing.
    public func aiPromptWithFieldNames(_ source: String, tableID: String) -> String {
        PromptTemplate.rewriteReferences(in: source) { ref in
            if let f = self.field(ref), f.tableID == tableID { return f.name }
            return nil
        }
    }

    /// Why a prompt can't be used, or nil when it's fine.
    public func validateAIPrompt(_ source: String, tableID: String, excludingFieldID: String? = nil) -> String? {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a prompt" }
        for ref in PromptTemplate.references(in: source) {
            guard let f = promptField(ref, tableID: tableID) else { return "Unknown field {\(ref)}" }
            if f.id == excludingFieldID { return "The prompt can't refer to this field itself" }
        }
        return nil
    }

    private func promptField(_ reference: String, tableID: String) -> FieldModel? {
        if let f = field(reference), f.tableID == tableID { return f }
        return field(named: reference.trimmingCharacters(in: .whitespaces), in: tableID)
    }

    /// The prompt for one record: each `{Field}` replaced by that field's value as shown in the grid.
    /// Throws before anything is sent when the prompt is empty or names a field that doesn't exist.
    public func renderAIPrompt(field: FieldModel, record: RecordModel) throws -> String {
        guard let source = field.options.aiPrompt, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.emptyPrompt
        }
        var out = ""
        for piece in PromptTemplate.pieces(of: source) {
            switch piece {
            case .text(let text):
                out += text
            case .reference(let ref):
                guard let referenced = promptField(ref, tableID: field.tableID) else { throw AIServiceError.unknownFieldReference(ref) }
                if referenced.id == field.id { throw AIServiceError.selfReference }
                out += displayString(record, referenced)
            }
        }
        return out
    }

    // MARK: - Generating values

    /// Generates an AI field's value for one record and stores it (an ordinary, undoable edit).
    @discardableResult
    public func generateAIValue(recordID: String, fieldID: String, using service: any AITextGenerating, origin: ChangeOrigin = .local) async throws -> String {
        guard let field = field(fieldID), field.type == .aiText, let record = record(recordID) else {
            throw AIServiceError.fieldUnavailable
        }
        let prompt = try renderAIPrompt(field: field, record: record)
        let text = try await service.generateText(prompt: prompt, model: field.options.aiModel)
        guard self.record(recordID) != nil, self.field(fieldID)?.type == .aiText else { throw AIServiceError.fieldUnavailable }
        updateRecord(recordID, values: [fieldID: .string(text)], actionName: "Generate \(field.name)", origin: origin)
        return text
    }

    /// Generates values for several records, a few requests at a time, storing each as it arrives.
    /// Stops early on errors that would repeat for every record (a missing or rejected API key).
    public func generateAIValues(
        fieldID: String,
        recordIDs: [String],
        using service: any AITextGenerating,
        maxConcurrent: Int = 3,
        origin: ChangeOrigin = .local,
        progress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> AIBatchResult {
        var result = AIBatchResult()
        guard let field = field(fieldID), field.type == .aiText else {
            result.failures = recordIDs.map { AIGenerationFailure(recordID: $0, message: AIServiceError.fieldUnavailable.localizedDescription) }
            return result
        }
        var prompts: [(recordID: String, prompt: String)] = []
        for id in recordIDs {
            guard let record = record(id) else { continue }
            do {
                prompts.append((id, try renderAIPrompt(field: field, record: record)))
            } catch {
                result.failures.append(AIGenerationFailure(recordID: id, message: error.localizedDescription))
            }
        }
        let total = prompts.count
        let model = field.options.aiModel
        var done = 0
        var stopMessage: String?
        progress?(0, total)
        await withTaskGroup(of: (String, Result<String, any Error>).self) { group in
            var next = 0
            func startNext() {
                let (id, prompt) = prompts[next]
                next += 1
                group.addTask {
                    do {
                        return (id, .success(try await service.generateText(prompt: prompt, model: model)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            while next < min(max(1, maxConcurrent), prompts.count) { startNext() }
            while let (id, outcome) = await group.next() {
                done += 1
                switch outcome {
                case .success(let text):
                    if record(id) != nil, self.field(fieldID)?.type == .aiText {
                        updateRecord(id, values: [fieldID: .string(text)], actionName: "Generate \(field.name)", origin: origin)
                        result.generated += 1
                    }
                case .failure(let error):
                    result.failures.append(AIGenerationFailure(recordID: id, message: error.localizedDescription))
                    if (error as? AIServiceError)?.stopsBatch == true, stopMessage == nil {
                        stopMessage = error.localizedDescription
                    }
                }
                progress?(done, total)
                if stopMessage == nil, !Task.isCancelled, next < prompts.count { startNext() }
            }
        }
        if let stopMessage {
            for (id, _) in prompts[done...] {
                result.failures.append(AIGenerationFailure(recordID: id, message: stopMessage))
            }
        }
        return result
    }
}
