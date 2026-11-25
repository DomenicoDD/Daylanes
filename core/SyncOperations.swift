import Foundation

/// Agent history imports: `sync` and `import-harness`.
enum SyncOperations {
    static let all: [EngineOperation] = [
        EngineOperation(name: "sync_agents", summary: "Read every coding agent's local history into the ledger.",
                        effect: .external) { params, db, _ in
            // Sync takes the write lock itself, after listing files, like the Python engine.
            let p = Params(params)
            let provider = try p.string("provider") ?? "all"
            guard provider == "all" || Sync.providers.contains(provider) else {
                throw EngineError.invalid("Unknown provider: \(provider)")
            }
            return try Sync.run(db, provider: provider, codex: try p.string("codex_dir"), claude: try p.string("claude_dir"),
                                recentDays: try p.int("recent_days"), opencode: try p.string("opencode_db"),
                                rescan: try p.bool("rescan"))
        },
        EngineOperation(name: "import_harness_usage",
                        summary: "Import normalized usage JSON Lines (id, model, timestamp, token counts) from another agent.",
                        effect: .reversible) { params, db, context in
            let p = Params(params)
            let input: Data
            if let lines = params["lines"].arrayValue {
                input = Data(lines.map { $0.stringValue ?? $0.pythonText(indent: nil) }.joined(separator: "\n").utf8)
            } else {
                input = context.input ?? Data()
            }
            return try AgentLogs.importHarness(db, harness: try p.required("name"), input: input)
        },
    ]
}
