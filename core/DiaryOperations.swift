import Foundation

enum DiaryOperations {
    static let all = [
        EngineOperation(name: "get_diary_work", summary: "Get the diary brief and workday window.", effect: .read) { json, db, _ in
            let params = Params(json)
            let project = try project(db, params)
            guard let routine = try DiaryStore.routine(db, project: project) else {
                throw EngineError.notFound("Save a project routine in Daylanes first.")
            }
            let day = try params.string("work_date").map(Day.parse)
            let work = try DiaryStore.work(db, project: project, routine: routine, day: day)
            let record = try Store.project(db, project)
            let projectInfo = JSON.object([
                ("name", .string(project)), ("client", record["client"].json), ("kind", record["kind"].json),
                ("folders", .array(try db.query("SELECT path FROM folders WHERE project = ? ORDER BY path", [project]).map { $0[0].json })),
                ("github_repository", try db.first("SELECT repo FROM github_projects WHERE project = ?", [project])?[0].json ?? .null),
            ])
            var draft: JSON = .null
            if let entry = work?.draft {
                draft = .object([
                    ("entry", try jsonValue(entry.content)), ("user_edits", try jsonValue(entry.edits)),
                    ("through", .int(Int64(entry.through))), ("early", .bool(entry.early)),
                ])
            }
            let details: JSON
            if let work {
                let formatter = ISO8601DateFormatter()
                formatter.timeZone = TimeZone(identifier: work.window.timezone)
                details = .object([
                    ("work_date", .string(work.day.iso)), ("window", try jsonValue(work.window)),
                    ("start_inclusive", .string(formatter.string(from: DiaryClock.date(work.window.start)))),
                    ("end_exclusive", .string(formatter.string(from: DiaryClock.date(work.window.end)))),
                    ("evidence_before", .string(ISO8601DateFormatter.string(from: DiaryClock.date(work.through),
                        timeZone: formatter.timeZone, formatOptions: [.withInternetDateTime, .withFractionalSeconds]))),
                    ("through", .int(Int64(work.through))), ("revision", .int(Int64(work.draft?.revision ?? 0))),
                    ("early", .bool(work.through < work.window.end)), ("draft", draft),
                ])
            } else {
                details = .null
            }
            return .object([("project", projectInfo), ("brief", .string(routine.brief)), ("work", details)])
        },
        EngineOperation(name: "submit_diary_entry", summary: "Save a draft for this diary project and date.", effect: .reversible) { json, db, _ in
            let params = Params(json)
            let project = try project(db, params)
            guard let routine = try DiaryStore.routine(db, project: project) else {
                throw EngineError.notFound("Save a project routine in Daylanes first.")
            }
            let day = try Day.parse(params.required("work_date"))
            guard let work = try DiaryStore.work(db, project: project, routine: routine, day: day),
                  let through = try params.int("through"), let revision = try params.int("revision") else {
                throw EngineError.invalid("Fetch the work date and copy the returned through and revision.")
            }
            let window: DiaryWindow = try payload(json["window"], name: "window")
            guard window == work.window else {
                throw EngineError.conflict("The workday window changed. Fetch the work date again.")
            }
            let content: DiaryContent = try payload(json["entry"], name: "entry")
            let changed = try DiaryStore.submit(db, project: project, work: work, through: through,
                                                revision: revision, content: content)
            let saved = try DiaryStore.entry(db, project: project, day: day.iso)
            return .object([
                ("project", .string(project)), ("work_date", .string(day.iso)), ("changed", .bool(changed)),
                ("early", .bool(saved?.early ?? true)), ("revision", .int(Int64(saved?.revision ?? 0))),
            ])
        },
    ]

    private static func project(_ db: Database, _ params: Params) throws -> String {
        guard let id = UUID(uuidString: try params.required("routine_id")) else {
            throw EngineError.invalid("A valid Diary routine ID is required.")
        }
        return try DiaryStore.project(db, routine: id)
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSON {
        try JSON.parse(DiaryStore.encode(value))
    }

    private static func payload<T: Decodable>(_ json: JSON, name: String) throws -> T {
        do {
            return try DiaryStore.decode(T.self, json.pythonText(indent: nil))
        } catch {
            throw EngineError.invalid("Invalid \(name): \(error.localizedDescription)")
        }
    }

    private static func object(_ properties: [(String, JSON)], required: [String]) -> JSON {
        .object([("type", .string("object")), ("properties", .object(properties)),
                 ("required", JSON.strings(required)), ("additionalProperties", .bool(false))])
    }

    private static func array(_ items: JSON) -> JSON {
        .object([("type", .string("array")), ("items", items)])
    }

    private static let sources = array(object([
        ("title", MCPTools.string("A short source label.")),
        ("url", MCPTools.string("A direct HTTP or HTTPS source link.", format: "uri")),
    ], required: ["title", "url"]))

    static let tools = [
        MCPTool(name: "get_diary_work", title: "Get the current Diary brief",
                description: "Read this connection’s project, current brief and oldest due workday, including any saved draft. Omit work_date for scheduled runs. If work is null, there is nothing due.",
                properties: [("work_date", MCPTools.string("Supply a specific date only for a requested backfill or refresh.", format: "date"))],
                operation: "get_diary_work", toolset: "diary"),
        MCPTool(name: "submit_diary_entry", title: "Save a Diary draft",
                description: "Update the same project and work date. Copy the work date, window, through and revision exactly from get_diary_work. User edits are retained.",
                properties: [
                    ("work_date", MCPTools.string("The returned work date.", format: "date")),
                    ("window", object([
                        ("start", MCPTools.integer("Inclusive start in Unix milliseconds.")),
                        ("end", MCPTools.integer("Exclusive end in Unix milliseconds.")),
                        ("timezone", MCPTools.string("The workday timezone.")),
                    ], required: ["start", "end", "timezone"])),
                    ("through", MCPTools.integer("The returned exclusive evidence cutoff in Unix milliseconds.")),
                    ("revision", MCPTools.integer("The returned writer revision, or zero for a new draft.")),
                    ("entry", object([
                        ("headline", MCPTools.string("One short headline.")),
                        ("summary", MCPTools.string("A readable account of the workday.")),
                        ("standup", MCPTools.string("A short spoken update. Omit when the brief does not request one.")),
                        ("outcomes", MCPTools.string("Outcomes, as plain text with line breaks as needed.")),
                        ("decisions", MCPTools.string("Decisions that were made.")),
                        ("blockers", MCPTools.string("What is currently blocked or waiting.")),
                        ("next_steps", MCPTools.string("Suggested next steps.")),
                        ("sections", array(object([
                            ("title", MCPTools.string("A section title requested in the brief. Reuse the same title on refresh.")),
                            ("text", MCPTools.string("The section’s paragraphs or plain-text list.")),
                            ("sources", sources),
                        ], required: ["title", "text"]))),
                        ("sources", sources),
                    ], required: ["headline", "summary"])),
                ], required: ["work_date", "window", "through", "revision", "entry"],
                operation: "submit_diary_entry", toolset: "diary"),
    ]
}
