import Foundation
import JavaScriptCore

public struct ScriptResult: Sendable {
    public var output: [String: JSONValue] = [:]
    public var logs: [String] = []
    public var error: String?
}

/// Runs automation scripts in JavaScriptCore with an Airtable-compatible API (`base`, `input`,
/// `output`, `console`, `fetch`). Scripts run on a background thread; data access hops to the main actor.
public enum ScriptRunner {
    private static let queue = DispatchQueue(label: "app.rowhouse.scripts", qos: .userInitiated)

    @MainActor
    public static func run(source: String, inputs: [String: JSONValue], document: BaseDocument, origin: ChangeOrigin, timeLimit: Double = 30) async -> ScriptResult {
        let bridge = ScriptBridge(document: document, origin: origin, inputs: inputs)
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: execute(source: source, bridge: bridge, timeLimit: timeLimit))
            }
        }
    }

    private static func execute(source: String, bridge: ScriptBridge, timeLimit: Double) -> ScriptResult {
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            return ScriptResult(error: "JavaScript is unavailable")
        }
        applyTimeLimit(context, seconds: timeLimit)
        var result = ScriptResult()
        let lock = NSLock()
        context.exceptionHandler = { _, exception in
            lock.lock()
            if result.error == nil { result.error = describe(exception) }
            lock.unlock()
        }
        bridge.install(in: context)
        context.evaluateScript(prelude)

        var settled = false
        let onDone: @convention(block) () -> Void = { settled = true }
        let onFail: @convention(block) (JSValue?) -> Void = { error in
            settled = true
            lock.lock()
            if result.error == nil { result.error = describe(error) }
            lock.unlock()
        }
        context.setObject(onDone, forKeyedSubscript: "__rhDone" as NSString)
        context.setObject(onFail, forKeyedSubscript: "__rhFail" as NSString)
        let wrapped = "(async function() {\n\(source)\n})().then(function(){ __rhDone(); }, function(e){ __rhFail(e); });"
        context.evaluateScript(wrapped, withSourceURL: URL(string: "rowhouse://automation/script.js"))
        if !settled && result.error == nil {
            result.error = "The script did not finish. Scripts time out after \(Int(timeLimit)) seconds and can't use timers."
        }
        result.logs = bridge.logs
        result.output = bridge.output
        return result
    }

    private static func describe(_ value: JSValue?) -> String {
        guard let value, !value.isUndefined, !value.isNull else { return "Unknown error" }
        if value.isObject, let message = value.objectForKeyedSubscript("message"), message.isString {
            let line = value.objectForKeyedSubscript("line")
            if let line, line.isNumber { return "\(message.toString() ?? "Error") (line \(max(1, line.toInt32() - 1)))" }
            return message.toString() ?? "Error"
        }
        return value.toString() ?? "Error"
    }

    /// JavaScriptCore exposes execution time limits only through a C function that isn't in the public
    /// headers; look it up dynamically and skip the limit if it's ever unavailable.
    nonisolated(unsafe) private static let setTimeLimitSymbol: UnsafeMutableRawPointer? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")

    /// Whether runaway scripts can be stopped on this system.
    public static var supportsTimeLimit: Bool { setTimeLimitSymbol != nil }

    private static func applyTimeLimit(_ context: JSContext, seconds: Double) {
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        guard let symbol = setTimeLimitSymbol else { return }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), seconds, nil, nil)
    }

    static let prelude = #"""
    (function(native) {
      const parse = (s) => (s === undefined || s === null || s === "") ? null : JSON.parse(s);
      const fmt = (args) => args.map((a) => {
        if (typeof a === "string") return a;
        try { return JSON.stringify(a); } catch (e) { return String(a); }
      }).join(" ");
      const check = (r) => { const v = parse(r); if (v && v.__error) throw new Error(v.__error); return v; };

      class Record {
        constructor(table, data) {
          this.id = data.id; this.name = data.name;
          this._cells = data.cells; this._text = data.text; this._table = table;
        }
        getCellValue(key) {
          const f = this._table.getField(key);
          if (!f) throw new Error("No field named " + key);
          const v = this._cells[f.id]; return v === undefined ? null : v;
        }
        getCellValueAsString(key) {
          const f = this._table.getField(key);
          if (!f) throw new Error("No field named " + key);
          return this._text[f.id] || "";
        }
      }
      class QueryResult {
        constructor(records) { this.records = records; this.recordIds = records.map((r) => r.id); }
        getRecord(id) { const r = this.records.find((x) => x.id === id); if (!r) throw new Error("No record " + id); return r; }
      }
      const unwrap = (fields) => {
        const out = {};
        for (const k of Object.keys(fields || {})) out[k] = fields[k];
        return JSON.stringify(out);
      };
      class Table {
        constructor(t) {
          this.id = t.id; this.name = t.name; this.description = t.description;
          this.fields = t.fields; this.primaryField = t.fields[0] || null;
        }
        getField(key) {
          if (key && typeof key === "object") key = key.id || key.name;
          const k = String(key);
          return this.fields.find((f) => f.id === k) || this.fields.find((f) => f.name === k)
            || this.fields.find((f) => f.name.toLowerCase() === k.toLowerCase()) || null;
        }
        getFieldIfExists(key) { return this.getField(key); }
        selectRecords(opts) {
          let recs = check(native.select(this.id)).map((d) => new Record(this, d));
          if (opts && Array.isArray(opts.sorts)) {
            for (const s of opts.sorts.slice().reverse()) {
              const f = this.getField(s.field);
              if (!f) continue;
              const dir = s.direction === "desc" ? -1 : 1;
              recs.sort((a, b) => {
                const x = a.getCellValueAsString(f.id), y = b.getCellValueAsString(f.id);
                const nx = parseFloat(x), ny = parseFloat(y);
                if (!isNaN(nx) && !isNaN(ny)) return (nx - ny) * dir;
                return x.localeCompare(y) * dir;
              });
            }
          }
          if (opts && Array.isArray(opts.recordIds)) {
            const want = new Set(opts.recordIds); recs = recs.filter((r) => want.has(r.id));
          }
          return new QueryResult(recs);
        }
        async selectRecordsAsync(opts) { return this.selectRecords(opts); }
        async selectRecordAsync(id) { const q = this.selectRecords(); return q.records.find((r) => r.id === id) || null; }
        createRecord(fields) { return check(native.create(this.id, unwrap(fields))); }
        async createRecordAsync(fields) { return this.createRecord(fields); }
        async createRecordsAsync(list) { return list.map((x) => this.createRecord(x && x.fields ? x.fields : x)); }
        updateRecord(rec, fields) { check(native.update(this.id, typeof rec === "string" ? rec : rec.id, unwrap(fields))); }
        async updateRecordAsync(rec, fields) { this.updateRecord(rec, fields); }
        async updateRecordsAsync(list) { for (const x of list) this.updateRecord(x.id, x.fields); }
        deleteRecord(rec) { check(native.remove(this.id, typeof rec === "string" ? rec : rec.id)); }
        async deleteRecordAsync(rec) { this.deleteRecord(rec); }
        async deleteRecordsAsync(list) { for (const x of list) this.deleteRecord(x); }
      }

      const tables = check(native.tables()).map((t) => new Table(t));
      const findTable = (key) => {
        if (key && typeof key === "object") key = key.id || key.name;
        const k = String(key);
        return tables.find((t) => t.id === k) || tables.find((t) => t.name === k)
          || tables.find((t) => t.name.toLowerCase() === k.toLowerCase()) || null;
      };
      globalThis.base = {
        name: native.baseName(),
        tables,
        getTable(key) { const t = findTable(key); if (!t) throw new Error("No table named " + key); return t; },
        getTableIfExists(key) { return findTable(key); },
      };
      const inputs = check(native.inputs()) || {};
      globalThis.input = { config() { return inputs; } };
      globalThis.output = {
        set(key, value) { native.outputSet(String(key), JSON.stringify(value === undefined ? null : value)); },
        text(s) { native.log("output", String(s)); },
        markdown(s) { native.log("output", String(s)); },
        table(x) { native.log("output", JSON.stringify(x, null, 2)); },
        inspect(x) { native.log("output", JSON.stringify(x, null, 2)); },
      };
      globalThis.console = {
        log: (...a) => native.log("log", fmt(a)),
        info: (...a) => native.log("info", fmt(a)),
        warn: (...a) => native.log("warn", fmt(a)),
        error: (...a) => native.log("error", fmt(a)),
        debug: (...a) => native.log("debug", fmt(a)),
      };
      globalThis.fetch = async (url, opts) => {
        const r = check(native.fetch(String(url), JSON.stringify(opts || {})));
        return {
          status: r.status, ok: r.status >= 200 && r.status < 300, statusText: "", headers: r.headers, url: String(url),
          text: async () => r.body,
          json: async () => JSON.parse(r.body),
        };
      };
      globalThis.remoteFetchAsync = globalThis.fetch;
    })(__rhNative);
    """#
}

/// Native side of the script API. Methods are called on the script thread; document access hops to main.
final class ScriptBridge: @unchecked Sendable {
    private let document: BaseDocument
    private let origin: ChangeOrigin
    private let inputs: [String: JSONValue]
    private let lock = NSLock()
    private var _logs: [String] = []
    private var _output: [String: JSONValue] = [:]

    init(document: BaseDocument, origin: ChangeOrigin, inputs: [String: JSONValue]) {
        self.document = document
        self.origin = origin
        self.inputs = inputs
    }

    var logs: [String] { lock.withLock { _logs } }
    var output: [String: JSONValue] { lock.withLock { _output } }

    private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    private func error(_ message: String) -> String {
        JSONValue.object(["__error": .string(message)]).jsonString
    }

    func install(in context: JSContext) {
        let native = JSValue(newObjectIn: context)!
        let tables: @convention(block) () -> String = { [unowned self] in
            onMain { () -> JSONValue in
                .array(document.tables.map { t in
                    .object([
                        "id": .string(t.id),
                        "name": .string(t.name),
                        "description": .string(t.description),
                        "fields": .array(document.fields(in: t.id).map { f in
                            .object(["id": .string(f.id), "name": .string(f.name), "type": .string(f.type.rawValue), "description": .string(f.description)])
                        }),
                    ])
                })
            }.jsonString
        }
        let baseName: @convention(block) () -> String = { [unowned self] in onMain { document.info.name } }
        let select: @convention(block) (String) -> String = { [unowned self] tableID in
            onMain {
                guard document.table(tableID) != nil else { return error("No table \(tableID)") }
                let fields = document.fields(in: tableID)
                let coding = RecordValueCoding(document: document, style: .scripting)
                return JSONValue.array(document.records(in: tableID).map { r in
                    var cells: [String: JSONValue] = [:]
                    var text: [String: JSONValue] = [:]
                    for f in fields {
                        cells[f.id] = coding.value(of: r, field: f)
                        text[f.id] = .string(document.displayString(r, f))
                    }
                    return .object(["id": .string(r.id), "name": .string(document.primaryTitle(r)), "cells": .object(cells), "text": .object(text)])
                }).jsonString
            }
        }
        let create: @convention(block) (String, String) -> String = { [unowned self] tableID, json in
            onMain {
                guard document.table(tableID) != nil else { return error("No table \(tableID)") }
                guard let fields = (try? JSONValue.parse(json))?.objectValue else { return error("Fields must be an object") }
                do throws(RecordValueCoding.Failure) {
                    let ids = try RecordValueCoding(document: document, style: .scripting, typecast: true)
                        .createRecords([fields], in: tableID, origin: origin)
                    return JSONValue.string(ids.first ?? "").jsonString
                } catch let failure {
                    return error(failure.message)
                }
            }
        }
        let update: @convention(block) (String, String, String) -> String = { [unowned self] tableID, recordID, json in
            onMain {
                guard let r = document.record(recordID), r.tableID == tableID else { return error("No record \(recordID) in this table") }
                guard let fields = (try? JSONValue.parse(json))?.objectValue else { return error("Fields must be an object") }
                do throws(RecordValueCoding.Failure) {
                    try RecordValueCoding(document: document, style: .scripting, typecast: true)
                        .updateRecords([(recordID, fields)], in: tableID, actionName: "Script Update", origin: origin)
                    return "null"
                } catch let failure {
                    return error(failure.message)
                }
            }
        }
        let remove: @convention(block) (String, String) -> String = { [unowned self] tableID, recordID in
            onMain {
                guard let r = document.record(recordID), r.tableID == tableID else { return error("No record \(recordID) in this table") }
                document.deleteRecords([recordID], origin: origin)
                return "null"
            }
        }
        let inputsBlock: @convention(block) () -> String = { [unowned self] in JSONValue.object(inputs).jsonString }
        let outputSet: @convention(block) (String, String) -> Void = { [unowned self] key, json in
            let value = (try? JSONValue.parse(json)) ?? .null
            lock.withLock { _output[key] = value }
        }
        let log: @convention(block) (String, String) -> Void = { [unowned self] level, message in
            let line = level == "log" || level == "output" || level == "info" ? message : "[\(level)] \(message)"
            lock.withLock {
                if _logs.count < 500 { _logs.append(String(line.prefix(4_000))) }
            }
        }
        let fetch: @convention(block) (String, String) -> String = { [unowned self] url, optsJSON in
            performFetch(url: url, optionsJSON: optsJSON)
        }
        native.setObject(tables, forKeyedSubscript: "tables" as NSString)
        native.setObject(baseName, forKeyedSubscript: "baseName" as NSString)
        native.setObject(select, forKeyedSubscript: "select" as NSString)
        native.setObject(create, forKeyedSubscript: "create" as NSString)
        native.setObject(update, forKeyedSubscript: "update" as NSString)
        native.setObject(remove, forKeyedSubscript: "remove" as NSString)
        native.setObject(inputsBlock, forKeyedSubscript: "inputs" as NSString)
        native.setObject(outputSet, forKeyedSubscript: "outputSet" as NSString)
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        context.setObject(native, forKeyedSubscript: "__rhNative" as NSString)
    }

    private func performFetch(url: String, optionsJSON: String) -> String {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return error("fetch only supports http and https URLs")
        }
        let opts = (try? JSONValue.parse(optionsJSON)) ?? .object([:])
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = (opts["method"]?.stringValue ?? "GET").uppercased()
        if let headers = opts["headers"]?.objectValue {
            for (k, v) in headers { request.setValue(TemplateRenderer.string(v), forHTTPHeaderField: k) }
        }
        if let body = opts["body"] {
            request.httpBody = Data((body.stringValue ?? body.jsonString).utf8)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox(error("Request timed out"))
        let task = URLSession.shared.dataTask(with: request) { data, resp, err in
            if let err {
                box.set(self.error(err.localizedDescription))
            } else if let http = resp as? HTTPURLResponse {
                var headers: [String: JSONValue] = [:]
                for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = .string(String(describing: v)) }
                let body = String(decoding: data ?? Data(), as: UTF8.self)
                box.set(JSONValue.object(["status": .number(Double(http.statusCode)), "headers": .object(headers), "body": .string(body)]).jsonString)
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 25) == .timedOut {
            task.cancel()
            return error("Request timed out")
        }
        return box.value
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String
        init(_ value: String) { _value = value }
        func set(_ v: String) { lock.withLock { _value = v } }
        var value: String { lock.withLock { _value } }
    }
}
