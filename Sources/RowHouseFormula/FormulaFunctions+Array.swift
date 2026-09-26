import Foundation

extension FormulaFunctionRegistry {
    static let arrayFunctions: [FormulaFunction] = [
        FormulaFunction(
            "ARRAYCOMPACT(values)", .array, .exactly(1),
            summary: "Removes blank values and empty text from an array."
        ) { call in
            .array(FormulaArrays.elements(call.value(0)).filter { !$0.isBlank })
        },

        FormulaFunction(
            "ARRAYFLATTEN(values)", .array, .exactly(1),
            summary: "Flattens nested arrays into a single array."
        ) { call in
            .array(FormulaArrays.expand(FormulaArrays.elements(call.value(0))))
        },

        FormulaFunction(
            "ARRAYJOIN(values, [separator])", .array, .range(1, 2),
            summary: "Joins the values of an array into text with a separator (default \", \")."
        ) { call in
            let separator = call.has(1) ? call.text(1) : ", "
            let items = FormulaArrays.expand(FormulaArrays.elements(call.value(0)))
            return .text(items.map { $0.textValue(in: call.timeZone) }.joined(separator: separator))
        },

        FormulaFunction(
            "ARRAYUNIQUE(values)", .array, .exactly(1),
            summary: "Returns the distinct values of an array, keeping their first occurrence."
        ) { call in
            var seen = Set<FormulaValue>()
            var unique: [FormulaValue] = []
            for item in FormulaArrays.expand(FormulaArrays.elements(call.value(0))) where seen.insert(item).inserted {
                unique.append(item)
            }
            return .array(unique)
        },

        FormulaFunction(
            "ARRAYSLICE(values, start, [end])", .array, .range(2, 3),
            summary: "Returns the items from start to end inclusive (1-based; negative positions count from the end)."
        ) { call in
            let items = FormulaArrays.expand(FormulaArrays.elements(call.value(0)))
            let count = items.count

            func position(_ raw: Int) -> Int {
                raw < 0 ? count + raw + 1 : raw
            }

            let start = try max(position(call.integer(1)), 1)
            let end = try call.hasValue(2) ? min(position(call.integer(2)), count) : count
            guard start <= end else { return .array([]) }
            return .array(Array(items[(start - 1)..<end]))
        },
    ]
}
