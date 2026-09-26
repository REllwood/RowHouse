import Foundation

extension FormulaFunctionRegistry {
    static let recordFunctions: [FormulaFunction] = [
        FormulaFunction("RECORD_ID()", .record, .exactly(0), summary: "Returns the ID of the current record.") { call in
            .text(call.context.recordID)
        },

        FormulaFunction("CREATED_TIME()", .record, .exactly(0), summary: "Returns when the current record was created.") { call in
            .date(call.context.createdTime)
        },

        FormulaFunction(
            "LAST_MODIFIED_TIME()", .record, .exactly(0),
            summary: "Returns when the current record was last modified."
        ) { call in
            .date(call.context.lastModifiedTime)
        },
    ]
}
