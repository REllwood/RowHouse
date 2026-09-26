import Foundation
import Testing
@testable import RowHouseCore

@Suite(.serialized)
@MainActor
struct AirtableImporterTests {
    private static let token = "patTEST.secret"
    private static let policy = AirtableRequestPolicy(
        minimumInterval: .milliseconds(50),
        maxAttempts: 5,
        retryDelay: .milliseconds(10),
        rateLimitDelay: .milliseconds(20),
        maxRetryAfter: .seconds(1),
        attachmentConcurrency: 2
    )

    private func makeImporter() -> AirtableImporter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AirtableImporter(token: Self.token, session: URLSession(configuration: configuration), policy: Self.policy)
    }

    private func makeBase() throws -> (BaseDocument, BaseStorage, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AirtableImport-\(UUID().uuidString).rowhouse", isDirectory: true)
        try BaseStorage.createPackage(at: url, baseID: "appLocal", name: "Imported")
        let storage = BaseStorage(packageURL: url, deviceID: "devTest")
        let document = BaseDocument(baseID: "appLocal", deviceID: "devTest", deviceName: "Test Mac")
        return (document, storage, url)
    }

    // MARK: - Import

    @Test func importsLinkedTablesWithValuesAttachmentsAndComputedFields() async throws {
        let stub = AirtableStub.shared
        stub.reset()
        stub.route("https://api.airtable.com/v0/meta/bases/appStub/tables", .json(Fixture.schema))
        stub.route("https://api.airtable.com/v0/appStub/tblProjects?pageSize=100&returnFieldsByFieldId=true&cellFormat=json", .json(Fixture.projectsPage1))
        stub.route("https://api.airtable.com/v0/appStub/tblProjects?pageSize=100&returnFieldsByFieldId=true&cellFormat=json&offset=itrNext/recP2", .json(Fixture.projectsPage2))
        stub.route("https://api.airtable.com/v0/appStub/tblTasks?pageSize=100&returnFieldsByFieldId=true&cellFormat=json",
                   .json(#"{"error":{"type":"RATE_LIMIT_REACHED","message":"Rate limit exceeded"}}"#, status: 429),
                   .json(Fixture.tasks))
        stub.route("https://files.stub.test/logo.png", StubResponse(status: 200, body: Fixture.logoBytes, headers: ["Content-Type": "image/png"]))

        let (document, storage, url) = try makeBase()
        defer { try? FileManager.default.removeItem(at: url) }
        var progressValues: [Double] = []
        let report = try await makeImporter().importBase(id: "appStub", name: "Studio", into: document, storage: storage) { _, value in
            progressValues.append(value)
        }

        #expect(report.tables == 2)
        #expect(report.records == 6)
        #expect(report.fields == 22)
        #expect(report.attachments == 1)
        #expect(report.skippedAttachments == 1)
        #expect(!report.warnings.contains { $0.contains("“Owner”") })
        #expect(report.warnings.contains { $0.contains("1 attachment") })
        #expect(progressValues.first == 0 && progressValues.last == 1)
        #expect(progressValues == progressValues.sorted())

        // Tables and fields keep Airtable's order, names and types.
        #expect(document.tables.map(\.name) == ["Projects", "Tasks"])
        let projects = try #require(document.table(named: "Projects"))
        let tasks = try #require(document.table(named: "Tasks"))
        #expect(projects.description == "Client work")
        #expect(document.views(in: projects.id).map(\.name) == ["All projects"])

        let projectFields = document.fields(in: projects.id)
        #expect(projectFields.map(\.name) == ["Name", "Status", "Tags", "Due", "Kickoff", "Budget", "Progress", "Tasks", "Task count",
                                              "Longest task", "Task names", "Label", "Files", "Owner", "Related"])
        #expect(projectFields.map(\.type) == [.singleLineText, .singleSelect, .multipleSelects, .date, .date, .currency, .percent, .link, .count,
                                              .rollup, .lookup, .formula, .attachment, .collaborator, .link])
        #expect(projects.primaryFieldID == projectFields[0].id)
        let taskFields = document.fields(in: tasks.id)
        #expect(taskFields.map(\.name) == ["Name", "Project", "Hours", "Done", "Time spent", "Notes", "ID"])
        #expect(taskFields.map(\.type) == [.singleLineText, .link, .number, .checkbox, .duration, .multilineText, .autoNumber])

        func field(_ name: String, _ table: TableModel) throws -> FieldModel {
            try #require(document.field(named: name, in: table.id))
        }
        let status = try field("Status", projects)
        #expect(status.choices.map(\.name) == ["Todo", "Doing", "Done", "Archived"])
        #expect(status.choices.prefix(3).map(\.color) == [.red, .yellow, .green])
        let tags = try field("Tags", projects)
        #expect(tags.choices.map(\.name) == ["Web", "iOS"])
        #expect(tags.choices.map(\.color) == [.blue, .purple])
        let due = try field("Due", projects)
        #expect(due.includesTime == false)
        #expect(due.options.dateFormat == .iso)
        let kickoff = try field("Kickoff", projects)
        #expect(kickoff.includesTime)
        #expect(kickoff.options.use24HourClock == true)
        let budget = try field("Budget", projects)
        #expect(budget.options.currencySymbol == "€")
        #expect(budget.options.precision == 2)
        #expect(try field("Progress", projects).options.precision == 1)
        #expect(try field("Time spent", tasks).options.durationFormat == .hoursMinutesSeconds)

        // One link pair: the Airtable inverse became RowHouse's inverse field; the one-way link has none.
        let tasksLink = try field("Tasks", projects)
        let projectLink = try field("Project", tasks)
        #expect(tasksLink.options.linkedTableID == tasks.id)
        #expect(tasksLink.options.inverseFieldID == projectLink.id)
        #expect(projectLink.isInverseLink)
        #expect(projectLink.options.inverseFieldID == tasksLink.id)
        #expect(projectLink.options.singleRecordLink == true)
        let related = try field("Related", projects)
        #expect(related.options.linkedTableID == tasks.id)
        #expect(related.options.inverseFieldID == nil)

        // Computed fields point at the imported fields.
        let hours = try field("Hours", tasks)
        let rollup = try field("Longest task", projects)
        #expect(rollup.options.linkFieldID == tasksLink.id)
        #expect(rollup.options.targetFieldID == hours.id)
        #expect(rollup.options.rollupFormula == "MAX(values)")
        #expect(rollup.options.precision == 1)
        let lookup = try field("Task names", projects)
        #expect(lookup.options.linkFieldID == tasksLink.id)
        #expect(lookup.options.targetFieldID == taskFields[0].id)
        #expect(try field("Task count", projects).options.linkFieldID == tasksLink.id)
        let name = projectFields[0]
        #expect(try field("Label", projects).options.formula == "CONCATENATE({\(name.id)}, \" — \", {\(status.id)}, \" {fldPName}\")")

        // Records keep Airtable's order and creation times.
        let projectRecords = document.records(in: projects.id)
        let taskRecords = document.records(in: tasks.id)
        #expect(projectRecords.map { document.primaryTitle($0) } == ["Website", "App", "Archive"])
        #expect(taskRecords.map { document.primaryTitle($0) } == ["Design", "Build", "Ship"])
        let website = projectRecords[0], app = projectRecords[1], archive = projectRecords[2]
        let design = taskRecords[0], build = taskRecords[1], ship = taskRecords[2]
        #expect(website.createdTime == DateCoding.parseISO("2024-01-02T03:04:05.000Z"))

        // Values are converted to RowHouse's stored forms.
        #expect(document.value(website, status) == .choice(try #require(status.choice(named: "Doing"))))
        #expect(document.value(archive, status) == .choice(try #require(status.choice(named: "Archived"))))
        #expect(document.value(website, tags) == .choices(tags.choices))
        #expect(website[due.id] == .string("2026-03-01"))
        #expect(website[kickoff.id].stringValue.flatMap(DateCoding.parseISO) == DateCoding.parseISO("2026-02-15T09:30:00Z"))
        #expect(website[budget.id] == .number(1250.5))
        #expect(website[try field("Progress", projects).id] == .number(0.25))
        // Collaborators became people in the base.
        let owner = try field("Owner", projects)
        let ada = try #require(document.person(matching: "ada@example.com"))
        let grace = try #require(document.person(matching: "grace@example.com"))
        #expect(document.people.count == 2)
        #expect(ada.name == "Ada Lovelace")
        #expect(owner.options.allowMultipleCollaborators == nil)
        #expect(website[owner.id] == .string(ada.id))
        #expect(app[owner.id] == .string(grace.id))
        #expect(document.displayString(app, owner) == "grace@example.com")
        #expect(design[try field("Done", tasks).id] == .bool(true))
        #expect(build[try field("Done", tasks).id] == .null)
        #expect(design[try field("Time spent", tasks).id] == .number(5400))
        let notes = try field("Notes", tasks)
        #expect(notes.options.richText == true)
        #expect(design[notes.id].stringValue?.contains("**Bold** idea") == true)
        #expect(document.displayString(design, notes) == "Bold idea\n• one")

        // Links resolve in both directions.
        #expect(document.compute.linkedRecordIDs(record: website, field: tasksLink) == [design.id, build.id])
        #expect(document.compute.linkedRecordIDs(record: app, field: tasksLink) == [ship.id])
        #expect(document.compute.linkedRecordIDs(record: design, field: projectLink) == [website.id])
        #expect(document.compute.linkedRecordIDs(record: ship, field: projectLink) == [app.id])
        #expect(document.compute.linkedRecordIDs(record: website, field: related) == [ship.id])
        #expect(document.value(website, try field("Task count", projects)) == .number(2))
        #expect(document.value(website, lookup) == .list([.text("Design"), .text("Build")]))

        // Autonumbers follow Airtable's numbering, not the list order.
        let number = try field("ID", tasks)
        #expect(taskRecords.map { document.value($0, number) } == [.number(2), .number(3), .number(1)])

        // The attachment was downloaded into the package; the missing one was skipped.
        let files = try field("Files", projects)
        guard case .attachments(let stored) = document.value(website, files) else {
            Issue.record("Website has no attachment")
            return
        }
        #expect(stored.map(\.filename) == ["logo.png"])
        let storedData = try Data(contentsOf: storage.url(for: stored[0]))
        #expect(storedData == Fixture.logoBytes)
        #expect(app[files.id] == .null)

        // The 429 was retried, attachments never saw the token, and API calls were spaced out.
        let hits = stub.hits
        #expect(hits.filter { $0.url.path == "/v0/appStub/tblTasks" }.count == 2)
        let apiHits = hits.filter { $0.url.host == "api.airtable.com" }
        #expect(apiHits.count == 5)
        #expect(apiHits.allSatisfy { $0.authorization == "Bearer \(Self.token)" })
        #expect(hits.filter { $0.url.host == "files.stub.test" }.allSatisfy { $0.authorization == nil })
        let gaps = zip(apiHits.dropFirst(), apiHits).map { $0.time - $1.time }
        #expect(gaps.allSatisfy { $0 >= .milliseconds(35) })
    }

    @Test func importsPeopleBarcodesAndAIFields() async throws {
        let stub = AirtableStub.shared
        stub.reset()
        stub.route("https://api.airtable.com/v0/meta/bases/appPeople/tables", .json(#"""
        {"tables": [{"id": "tblItems", "name": "Items", "primaryFieldId": "fldName", "fields": [
          {"id": "fldName", "name": "Name", "type": "singleLineText"},
          {"id": "fldTeam", "name": "Team", "type": "multipleCollaborators"},
          {"id": "fldCode", "name": "Code", "type": "barcode"},
          {"id": "fldBy", "name": "Added by", "type": "createdBy"},
          {"id": "fldEditor", "name": "Edited by", "type": "lastModifiedBy", "options": {"referencedFieldIds": ["fldCode"]}},
          {"id": "fldAI", "name": "Summary", "type": "aiText", "options": {
            "prompt": ["Summarise {", {"field": {"fieldId": "fldName"}}, "} with code ", {"field": {"fieldId": "fldCode"}}],
            "referencedFieldIds": ["fldName", "fldCode"]}}
        ]}]}
        """#))
        stub.route("https://api.airtable.com/v0/appPeople/tblItems?pageSize=100&returnFieldsByFieldId=true&cellFormat=json", .json(#"""
        {"records": [{"id": "rec1", "createdTime": "2024-01-02T03:04:05.000Z", "fields": {
          "fldName": "Lamp",
          "fldTeam": [{"id": "usr1", "email": "ada@example.com", "name": "Ada"}, {"id": "usr2", "email": "grace@example.com", "name": "Grace"}],
          "fldCode": {"text": "4006381333931", "type": "ean13"},
          "fldBy": {"id": "usr1", "email": "ada@example.com", "name": "Ada"},
          "fldAI": {"state": "generated", "value": "A warm lamp.", "isStale": false}}}]}
        """#))

        let (document, storage, url) = try makeBase()
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await makeImporter().importBase(id: "appPeople", name: "People", into: document, storage: storage) { _, _ in }
        let table = try #require(document.table(named: "Items"))
        let fields = document.fields(in: table.id)
        #expect(fields.map(\.type) == [.singleLineText, .collaborator, .barcode, .createdBy, .lastModifiedBy, .aiText])
        #expect(report.warnings.contains { $0.contains("“Added by”") && $0.contains("Mac") })

        let record = try #require(document.records(in: table.id).first)
        let team = fields[1], code = fields[2], editedBy = fields[4], summary = fields[5]
        #expect(team.options.allowMultipleCollaborators == true)
        #expect(document.people.map(\.name) == ["Ada", "Grace"])
        #expect(document.displayString(record, team) == "Ada, Grace")
        #expect(record[code.id] == ["text": "4006381333931", "type": "ean13"])
        #expect(editedBy.options.watchedFieldIDs == [code.id])
        #expect(document.displayString(record, fields[3]) == "Test Mac")
        #expect(record[summary.id] == "A warm lamp.")
        #expect(summary.options.aiPrompt == "Summarise \\{{\(fields[0].id)}\\} with code {\(code.id)}")
        #expect(try document.renderAIPrompt(field: summary, record: record) == "Summarise {Lamp} with code 4006381333931")
    }

    @Test func cancellingBeforeTheFirstRequestLeavesTheDocumentEmpty() async throws {
        AirtableStub.shared.reset()
        let (document, storage, url) = try makeBase()
        defer { try? FileManager.default.removeItem(at: url) }
        let importer = makeImporter()
        let task = Task { try await importer.importBase(id: "appStub", name: "Studio", into: document, storage: storage) { _, _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(document.tables.isEmpty)
        #expect(AirtableStub.shared.hits.isEmpty)
    }

    // MARK: - Listing and errors

    @Test func listBasesFollowsOffsets() async throws {
        let stub = AirtableStub.shared
        stub.reset()
        stub.route("https://api.airtable.com/v0/meta/bases",
                   .json(#"{"bases":[{"id":"app1","name":"Marketing","permissionLevel":"create"}],"offset":"itr1/app1"}"#))
        stub.route("https://api.airtable.com/v0/meta/bases?offset=itr1/app1",
                   .json(#"{"bases":[{"id":"app2","name":"Hiring","permissionLevel":"read"}]}"#))
        let bases = try await makeImporter().listBases()
        #expect(bases == [
            AirtableBaseSummary(id: "app1", name: "Marketing", permissionLevel: "create"),
            AirtableBaseSummary(id: "app2", name: "Hiring", permissionLevel: "read"),
        ])
    }

    @Test(arguments: [
        (401, AirtableImportError.unauthorized),
        (403, AirtableImportError.forbidden),
        (404, AirtableImportError.notFound),
    ])
    func httpErrorsBecomeClearMessages(status: Int, expected: AirtableImportError) async throws {
        let stub = AirtableStub.shared
        stub.reset()
        stub.route("https://api.airtable.com/v0/meta/bases", .json(#"{"error":{"type":"ERROR","message":"Nope"}}"#, status: status))
        await #expect(throws: expected) { try await makeImporter().listBases() }
        #expect(stub.hits.count == 1)
        if status != 404 {
            let message = expected.errorDescription ?? ""
            #expect(message.contains("data.records:read") && message.contains("schema.bases:read"))
        }
    }

    @Test func serverErrorsAreRetriedFiveTimes() async throws {
        let stub = AirtableStub.shared
        stub.reset()
        stub.route("https://api.airtable.com/v0/meta/bases", .json(#"{"error":"SERVER_ERROR"}"#, status: 503))
        await #expect(throws: AirtableImportError.server(status: 503, message: "SERVER_ERROR")) { try await makeImporter().listBases() }
        #expect(stub.hits.count == 5)
    }

    @Test func tokenIsHiddenFromReflection() {
        var dumped = ""
        dump(makeImporter(), to: &dumped)
        #expect(!dumped.contains(Self.token))
    }
}

// MARK: - Fixtures

private enum Fixture {
    static let logoBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])

    static let schema = #"""
    {"tables": [
      {"id": "tblProjects", "name": "Projects", "primaryFieldId": "fldPName", "description": "Client work",
       "fields": [
        {"id": "fldPName", "name": "Name", "type": "singleLineText"},
        {"id": "fldPStatus", "name": "Status", "type": "singleSelect", "options": {"choices": [
          {"id": "selTodo", "name": "Todo", "color": "redLight2"},
          {"id": "selDoing", "name": "Doing", "color": "yellowBright"},
          {"id": "selDone", "name": "Done", "color": "greenDark1"}]}},
        {"id": "fldPTags", "name": "Tags", "type": "multipleSelects", "options": {"choices": [
          {"id": "selWeb", "name": "Web", "color": "blueLight2"},
          {"id": "selIOS", "name": "iOS", "color": "purpleLight1"}]}},
        {"id": "fldPDue", "name": "Due", "type": "date", "options": {"dateFormat": {"name": "iso", "format": "YYYY-MM-DD"}}},
        {"id": "fldPKickoff", "name": "Kickoff", "type": "dateTime", "options": {
          "dateFormat": {"name": "friendly", "format": "LL"}, "timeFormat": {"name": "24hour", "format": "HH:mm"}, "timeZone": "utc"}},
        {"id": "fldPBudget", "name": "Budget", "type": "currency", "options": {"precision": 2, "symbol": "€"}},
        {"id": "fldPProgress", "name": "Progress", "type": "percent", "options": {"precision": 1}},
        {"id": "fldPTasks", "name": "Tasks", "type": "multipleRecordLinks", "options": {
          "linkedTableId": "tblTasks", "isReversed": false, "prefersSingleRecordLink": false, "inverseLinkFieldId": "fldTProject"}},
        {"id": "fldPCount", "name": "Task count", "type": "count", "options": {"isValid": true, "recordLinkFieldId": "fldPTasks"}},
        {"id": "fldPLongest", "name": "Longest task", "type": "rollup", "options": {
          "isValid": true, "recordLinkFieldId": "fldPTasks", "fieldIdInLinkedTable": "fldTHours", "referencedFieldIds": ["fldPTasks"],
          "result": {"type": "number", "options": {"precision": 1}}}},
        {"id": "fldPTaskNames", "name": "Task names", "type": "multipleLookupValues", "options": {
          "isValid": true, "recordLinkFieldId": "fldPTasks", "fieldIdInLinkedTable": "fldTName", "result": {"type": "singleLineText"}}},
        {"id": "fldPLabel", "name": "Label", "type": "formula", "options": {
          "isValid": true, "formula": "CONCATENATE({fldPName}, \" — \", {Status}, \" {fldPName}\")",
          "referencedFieldIds": ["fldPName", "fldPStatus"], "result": {"type": "singleLineText"}}},
        {"id": "fldPFiles", "name": "Files", "type": "multipleAttachments", "options": {"isReversed": false}},
        {"id": "fldPOwner", "name": "Owner", "type": "singleCollaborator"},
        {"id": "fldPRelated", "name": "Related", "type": "multipleRecordLinks", "options": {
          "linkedTableId": "tblTasks", "isReversed": false, "prefersSingleRecordLink": false}}
       ],
       "views": [{"id": "viwProjects", "name": "All projects", "type": "grid"}]},
      {"id": "tblTasks", "name": "Tasks", "primaryFieldId": "fldTName",
       "fields": [
        {"id": "fldTName", "name": "Name", "type": "singleLineText"},
        {"id": "fldTProject", "name": "Project", "type": "multipleRecordLinks", "options": {
          "linkedTableId": "tblProjects", "isReversed": false, "prefersSingleRecordLink": true, "inverseLinkFieldId": "fldPTasks"}},
        {"id": "fldTHours", "name": "Hours", "type": "number", "options": {"precision": 1}},
        {"id": "fldTDone", "name": "Done", "type": "checkbox", "options": {"icon": "check", "color": "greenBright"}},
        {"id": "fldTTime", "name": "Time spent", "type": "duration", "options": {"durationFormat": "h:mm:ss"}},
        {"id": "fldTNotes", "name": "Notes", "type": "richText"},
        {"id": "fldTNumber", "name": "ID", "type": "autoNumber"}
       ],
       "views": [{"id": "viwTasks", "name": "Grid view", "type": "grid"}]}
    ]}
    """#

    static let projectsPage1 = #"""
    {"records": [
      {"id": "recP1", "createdTime": "2024-01-02T03:04:05.000Z", "fields": {
        "fldPName": "Website", "fldPStatus": "Doing", "fldPTags": ["Web", "iOS"], "fldPDue": "2026-03-01",
        "fldPKickoff": "2026-02-15T09:30:00.000Z", "fldPBudget": 1250.5, "fldPProgress": 0.25,
        "fldPTasks": ["recT1", "recT2"], "fldPCount": 2, "fldPLongest": 5, "fldPTaskNames": ["Design", "Build"],
        "fldPLabel": "Website — Doing {fldPName}",
        "fldPFiles": [{"id": "attLogo", "url": "https://files.stub.test/logo.png", "filename": "logo.png", "size": 11, "type": "image/png"}],
        "fldPOwner": {"id": "usr1", "email": "ada@example.com", "name": "Ada Lovelace"},
        "fldPRelated": ["recT3"]}},
      {"id": "recP2", "createdTime": "2024-01-03T03:04:05.000Z", "fields": {
        "fldPName": "App", "fldPStatus": "Todo", "fldPTasks": ["recT3"], "fldPCount": 1, "fldPLongest": 2,
        "fldPTaskNames": ["Ship"], "fldPLabel": "App — Todo {fldPName}",
        "fldPFiles": [{"id": "attSpec", "url": "https://files.stub.test/missing.pdf", "filename": "spec.pdf", "size": 10, "type": "application/pdf"}],
        "fldPOwner": {"id": "usr2", "email": "grace@example.com"}}}
    ], "offset": "itrNext/recP2"}
    """#

    static let projectsPage2 = #"""
    {"records": [
      {"id": "recP3", "createdTime": "2024-01-04T03:04:05.000Z", "fields": {
        "fldPName": "Archive", "fldPStatus": "Archived", "fldPCount": 0, "fldPLabel": "Archive — Archived {fldPName}"}}
    ]}
    """#

    static let tasks = #"""
    {"records": [
      {"id": "recT1", "createdTime": "2024-02-01T00:00:00.000Z", "fields": {
        "fldTName": "Design", "fldTProject": ["recP1"], "fldTHours": 3, "fldTDone": true, "fldTTime": 5400,
        "fldTNotes": "**Bold** idea\n- one", "fldTNumber": 2}},
      {"id": "recT2", "createdTime": "2024-02-02T00:00:00.000Z", "fields": {
        "fldTName": "Build", "fldTProject": ["recP1"], "fldTHours": 5, "fldTNumber": 3}},
      {"id": "recT3", "createdTime": "2024-01-31T00:00:00.000Z", "fields": {
        "fldTName": "Ship", "fldTProject": ["recP2"], "fldTHours": 2, "fldTNumber": 1}}
    ]}
    """#
}

// MARK: - URL stub

private struct StubResponse: Sendable {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]

    static func json(_ text: String, status: Int = 200) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }
}

/// Serves canned responses by URL (query order and percent-encoding don't matter). Each route answers
/// with its responses in turn and then keeps repeating the last one.
private final class AirtableStub: @unchecked Sendable {
    struct Hit: Sendable {
        let url: URL
        let authorization: String?
        let time: ContinuousClock.Instant
    }

    static let shared = AirtableStub()
    private let lock = NSLock()
    private var routes: [String: [StubResponse]] = [:]
    private var recorded: [Hit] = []

    var hits: [Hit] { lock.withLock { recorded } }

    func reset() {
        lock.withLock {
            routes = [:]
            recorded = []
        }
    }

    func route(_ url: String, _ responses: StubResponse...) {
        let key = Self.key(URL(string: url)!)
        lock.withLock { routes[key] = responses }
    }

    func respond(to request: URLRequest) -> StubResponse {
        let url = request.url!
        return lock.withLock {
            recorded.append(Hit(url: url, authorization: request.value(forHTTPHeaderField: "Authorization"), time: .now))
            let key = Self.key(url)
            guard var queue = routes[key], let first = queue.first else {
                return .json(#"{"error":"NOT_FOUND"}"#, status: 404)
            }
            if queue.count > 1 {
                queue.removeFirst()
                routes[key] = queue
            }
            return first
        }
    }

    private static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = (components.queryItems ?? []).sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? url.absoluteString
    }
}

private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = AirtableStub.shared.respond(to: request)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
