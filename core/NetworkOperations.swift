import Foundation

/// Network sources: the OpenRouter price catalog and account activity, and Toggl Track (port PR E).
/// Keys and tokens come from the `key` parameter or the caller's input (the app's Keychain), never from the ledger.
enum NetworkOperations {
    /// The secret for a request: the `key` parameter, else the first 1024 characters of the input
    /// (Python's `sys.stdin.read(1024)`), else the environment variable, if any.
    static func secret(_ params: JSON, _ context: OperationContext, environment name: String? = nil) throws -> String {
        if let key = try Params(params).string("key") { return key }
        if let input = context.input { return String(String(decoding: input, as: UTF8.self).prefix(1024)) }
        if let name { return ProcessInfo.processInfo.environment[name] ?? "" }
        return ""
    }

    static let all: [EngineOperation] = [
        EngineOperation(name: "refresh_prices", summary: "Cache public OpenRouter token prices in USD.",
                        effect: .external) { params, db, _ in
            try Prices.refresh(db, ifStale: try Params(params).bool("if_stale"), now: ReportOperations.now().floorDividedBy1000)
        },
        EngineOperation(name: "sync_openrouter", summary: "Read the last 30 complete days of OpenRouter account activity.",
                        effect: .external) { params, db, context in
            try OpenRouterActivity.refresh(db, key: try NetworkOperations.secret(params, context, environment: "OPENROUTER_MANAGEMENT_KEY"),
                                           now: ReportOperations.now())
        },
        EngineOperation(name: "clear_openrouter", summary: "Clear locally cached OpenRouter account activity.",
                        effect: .config) { _, db, _ in
            try OpenRouterActivity.clear(db)
            return .null
        },
        EngineOperation(name: "link_toggl", summary: "Verify a Toggl Track token and remember the connected account.",
                        effect: .external) { params, db, context in
            try Toggl.link(db, key: try NetworkOperations.secret(params, context), workspace: try Params(params).int("workspace"))
        },
        EngineOperation(name: "choose_toggl_workspace", summary: "Choose the Toggl Track workspace to read.",
                        effect: .config) { params, db, _ in
            guard let id = try Params(params).int("id") else { throw EngineError.invalid("id is required") }
            return try Toggl.chooseWorkspace(db, id)
        },
        EngineOperation(name: "unlink_toggl", summary: "Forget the connected Toggl Track account.", effect: .config) { _, db, _ in
            try Toggl.unlink(db)
            return .null
        },
        EngineOperation(name: "list_toggl_projects", summary: "Toggl Track projects the token can read.",
                        effect: .external) { params, _, context in
            try Toggl.projects(try NetworkOperations.secret(params, context))
        },
        EngineOperation(name: "import_toggl", summary: "Import completed Toggl Track time of one Toggl project into a local project.",
                        effect: .external) { params, db, context in
            let p = Params(params)
            let key = try NetworkOperations.secret(params, context)
            guard let source = try p.int("source") else { throw EngineError.invalid("source is required") }
            return try Toggl.importTime(db, key: key, source: source, project: try p.required("project"),
                                        start: try p.required("start"), end: try p.required("end"))
        },
    ]
}

private extension Int {
    /// Epoch milliseconds to whole seconds, rounding down (Python's `int(datetime.timestamp())`).
    var floorDividedBy1000: Int { self >= 0 ? self / 1000 : -((-self + 999) / 1000) }
}
