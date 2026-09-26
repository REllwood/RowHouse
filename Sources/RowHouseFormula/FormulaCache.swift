import Foundation

/// A small thread-safe memo table keyed by string. When full it is simply cleared; the cached values
/// (format token lists, compiled regular expressions) are cheap to rebuild and working sets are small.
final class FormulaCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Value] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: String, orCreate create: () -> Value) -> Value {
        lock.lock()
        let cached = storage[key]
        lock.unlock()
        if let cached { return cached }

        let created = create()
        lock.lock()
        if storage.count >= capacity {
            storage.removeAll(keepingCapacity: true)
        }
        storage[key] = created
        lock.unlock()
        return created
    }
}

/// `NSRegularExpression` is immutable and documented as safe to use from multiple threads.
struct FormulaCompiledRegex: @unchecked Sendable {
    let expression: NSRegularExpression
}

enum FormulaRegexCache {
    private static let cache = FormulaCache<Result<FormulaCompiledRegex, FormulaError>>(capacity: 512)

    static func regex(for pattern: String) throws(FormulaError) -> NSRegularExpression {
        let result = cache.value(for: pattern) {
            do {
                return .success(FormulaCompiledRegex(expression: try NSRegularExpression(pattern: pattern)))
            } catch {
                return .failure(FormulaError("Invalid regular expression \(FormulaCoercion.quoted(pattern))"))
            }
        }
        switch result {
        case .success(let compiled):
            return compiled.expression
        case .failure(let error):
            throw error
        }
    }
}
