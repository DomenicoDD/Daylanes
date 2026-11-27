import Foundation

/// The `tracker` command line on top of the operation registry. It accepts the same arguments as the
/// Python engine and prints the same output, so the app's `Ledger.run` can call either.
enum CLI {
    enum Output {
        /// Pretty JSON, like Python's `print_json`.
        case json
        /// Nothing on success.
        case none
        /// The `id` field of the result on its own line (new manual entries).
        case id
        /// Text results as they are (CSV, the text report); anything else as pretty JSON.
        case auto
    }

    enum Option {
        /// `--name VALUE` or `--name=VALUE`, stored under `param`; `choices` limits the value.
        case value(_ param: String, choices: [String]? = nil)
        /// `--name`, stored as true.
        case flag(_ param: String)
        /// `--name`, stored as a fixed JSON value.
        case constant(_ param: String, JSON)
        /// `--name VALUE`, repeatable, collected into a list (argparse's `action="append"`).
        case append(_ param: String)
    }

    struct Command {
        let words: [String]
        var positionals: [String] = []
        var options: [String: Option] = [:]
        var required: [String] = []
        /// Groups of options where at most one may be given (`exclusive`), or exactly one (`oneOf`).
        var exclusive: [[String]] = []
        var oneOf: [[String]] = []
        let operation: String
        var output: Output = .json
        var defaults: [(String, JSON)] = []
        /// Reads stdin (the activity recorder pipes JSON).
        var readsInput = false
        /// Reads stdin only for some argument combinations (`openrouter-sync --key-stdin`).
        var readsInputWhen: ((JSON) -> Bool)?
        /// False for argument combinations the Swift engine doesn't handle yet; they go to Python.
        var ported: (JSON) -> Bool = { _ in true }
        /// Integer parameters, checked like argparse's `type=int`.
        var integers: Set<String> = []
        /// Picks another operation (and its parameters) for some argument combinations.
        var route: ((JSON) -> (String, JSON))?
        /// Values checked like an argparse `type=` function: the type's name for the message, and the check.
        var checks: [String: (String, (String) -> Bool)] = [:]

        /// How argparse names a parameter in its messages: the option, or the positional's name.
        func label(_ param: String) -> String {
            for (name, option) in options.sorted(by: { $0.key < $1.key }) {
                if case let .value(found, _) = option, found == param { return name }
                if case let .append(found) = option, found == param { return name }
            }
            return param
        }
    }

    static let commands: [Command] = [
        Command(words: ["init"], options: [
            "--timezone": .value("timezone"), "--default-timezone": .value("default_timezone"), "--currency": .value("currency"),
        ], exclusive: [["--timezone", "--default-timezone"]], operation: "init_ledger"),
        Command(words: ["project", "add"], positionals: ["name"], options: [
            "--client": .value("client"), "--kind": .value("kind", choices: ["billable", "internal", "personal"]),
            "--folder": .value("folder"), "--github": .value("github"), "--new-only": .flag("new_only"),
            "--human-rate": .value("human_rate"),
        ], required: ["--kind"], operation: "save_project", output: .none),
        Command(words: ["project", "map"], positionals: ["project", "folder"], operation: "map_folder", output: .none),
        Command(words: ["project", "unmap"], positionals: ["project", "folder"], operation: "unmap_folder", output: .none),
        Command(words: ["project", "list"], operation: "list_projects"),
        Command(words: ["client", "list"], operation: "list_clients"),
        Command(words: ["client", "save"], positionals: ["name"], options: ["--previous": .value("previous")],
                operation: "save_client"),
        Command(words: ["appearance"], options: [
            "--client": .value("client"), "--project": .value("project"), "--color": .value("color"), "--icon": .value("icon"),
        ], oneOf: [["--client", "--project"]], operation: "set_appearance"),
        Command(words: ["subscription", "set"], positionals: ["name"], options: [
            "--monthly": .value("monthly"), "--provider": .value("provider"), "--new-only": .flag("new_only"),
        ], required: ["--monthly"], operation: "set_subscription"),
        Command(words: ["subscription", "remove"], positionals: ["name"], operation: "remove_subscription"),
        Command(words: ["subscription", "list"], operation: "list_subscriptions"),
        Command(words: ["model-rate"], positionals: ["provider", "model"], options: [
            "--input": .value("input"), "--cached": .value("cached"), "--cache-write": .value("cache_write"),
            "--output": .value("output"),
        ], required: ["--input", "--cached", "--cache-write", "--output"], operation: "set_model_rate", output: .none),
        Command(words: ["time"], positionals: ["project"], options: [
            "--minutes": .value("minutes"), "--activity": .value("activity", choices: ["prompting", "reviewing", "other"]),
            "--task": .value("task"), "--at": .value("at"),
        ], required: ["--minutes"], operation: "log_time", output: .id),
        Command(words: ["expense"], positionals: ["project", "description"], options: [
            "--amount": .value("amount"), "--reimburse": .flag("reimburse"), "--task": .value("task"), "--at": .value("at"),
        ], required: ["--amount"], operation: "add_expense", output: .id),
        Command(words: ["remove"], positionals: ["id"], operation: "delete_entry", output: .none),
        Command(words: ["focus", "record"], operation: "record_activity", output: .none, readsInput: true),
        Command(words: ["focus", "recover"], operation: "close_interrupted_activity", output: .none),
        Command(words: ["focus", "config"], options: ["--enabled": .value("enabled", choices: ["on", "off"])],
                operation: "get_tracking_config", route: { params in
                    guard let value = params["enabled"].stringValue else { return ("get_tracking_config", params) }
                    return ("set_tracking_enabled", .object([("enabled", .bool(value == "on"))]))
                }),
        Command(words: ["focus", "save-rule"], options: [
            "--id": .value("id"), "--project": .value("project"), "--ignore": .flag("ignore"),
            "--field": .value("field", choices: ["app", "window", "domain", "url"]), "--keyword": .value("keyword"),
            "--app-scope": .value("app_scope"), "--app-id": .value("app_id"),
            "--chrome-profile": .value("chrome_profile"), "--chrome-profile-id": .value("chrome_profile_id"),
            "--tag": .value("tag"),
        ], required: ["--field", "--keyword"], exclusive: [["--chrome-profile", "--chrome-profile-id"]],
                oneOf: [["--project", "--ignore"]],
                operation: "save_rule"),
        Command(words: ["focus", "chrome-profiles"], operation: "list_chrome_profiles"),
        Command(words: ["focus", "chrome-client"], positionals: ["profile_id"], options: [
            "--client": .value("client"), "--clear": .constant("client", .null),
        ], oneOf: [["--client", "--clear"]], operation: "set_chrome_profile_client"),
        Command(words: ["focus", "delete-rule"], positionals: ["id"], operation: "delete_rule"),
        Command(words: ["focus", "details"], options: ["--state": .value("state", choices: ["on", "off"])], required: ["--state"],
                operation: "set_activity_details", route: { params in
                    ("set_activity_details", .object([("enabled", .bool(params["state"].stringValue == "on"))]))
                }),
        Command(words: ["focus", "auto-rules"], positionals: ["project"],
                options: ["--state": .value("state", choices: ["on", "off"])], required: ["--state"],
                operation: "set_auto_rules", route: { params in
                    ("set_auto_rules", .object([("project", params["project"]), ("enabled", .bool(params["state"].stringValue == "on"))]))
                }),
        Command(words: ["focus", "classify"], positionals: ["id"], options: [
            "--project": .value("project"), "--ignore": .flag("ignore"), "--unassign": .constant("project", .null),
            "--also": .append("additional_ids"),
        ], oneOf: [["--project", "--ignore", "--unassign"]], operation: "classify_activity", output: .none),
        Command(words: ["focus", "timeline"], options: [
            "--day": .value("day"), "--week": .flag("week"), "--with-human-time": .flag("with_human_time"),
        ],
                operation: "get_week", route: { params in
                    (params["week"] == .bool(true) ? "get_week" : "get_day", params)
                }),
        Command(words: ["github", "status"], operation: "github_status"),
        Command(words: ["github", "set"], positionals: ["project", "repo"], operation: "link_repository"),
        Command(words: ["github", "refresh"], positionals: ["project"], options: ["--repo": .value("repo")],
                operation: "refresh_pull_requests"),
        Command(words: ["github", "autolink"], options: ["--project": .value("project")], operation: "link_folder_repositories"),
        Command(words: ["github", "unlink"], positionals: ["project"], operation: "unlink_repository", output: .none),
        Command(words: ["github", "route-pr"], positionals: ["project", "number"], options: ["--remove": .flag("remove")],
                operation: "route_pull_request", integers: ["number"]),
        Command(words: ["assign"], positionals: ["id"], options: [
            "--project": .value("project"), "--use-folder": .constant("project", .null),
        ], oneOf: [["--project", "--use-folder"]], operation: "assign_entry", output: .none),
        Command(words: ["import-harness"], positionals: ["name"], operation: "import_harness_usage", readsInput: true,
                checks: ["name": ("harness_id", { (try? Store.harnessID($0)) != nil })]),
        Command(words: ["sync"], options: [
            "--provider": .value("provider", choices: ["all"] + Sync.providers), "--codex-dir": .value("codex_dir"),
            "--claude-dir": .value("claude_dir"), "--opencode-db": .value("opencode_db"),
            "--recent-days": .value("recent_days"), "--rescan": .flag("rescan"),
        ], operation: "sync_agents", integers: ["recent_days"]),
        Command(words: ["billing", "show"], operation: "list_billing_terms"),
        Command(words: ["billing", "set"], options: [
            "--client": .value("client"), "--project": .value("project"), "--human-rate": .value("human_rate"),
            "--agent-mode": .value("agent_mode", choices: ["", "none", "time", "usage", "hybrid"]),
            "--agent-rate": .value("agent_rate"), "--markup": .value("markup"), "--cap": .value("cap"),
        ], oneOf: [["--client", "--project"]], operation: "set_billing_terms"),
        Command(words: ["billing", "exchange-rate"], positionals: ["rate"], operation: "set_exchange_rate"),
        Command(words: ["billing", "summary"], options: [
            "--period": .value("period", choices: ["week", "month"]), "--start": .value("start"), "--end": .value("end"),
        ], operation: "billing_summary", defaults: [("period", .string("month"))]),
        Command(words: ["report"], options: [
            "--period": .value("period", choices: ["week", "month"]), "--start": .value("start"), "--end": .value("end"),
            "--json": .flag("as_json"), "--client": .value("client"), "--project": .value("project"), "--task": .value("task"),
        ], operation: "usage_report_text", output: .auto, defaults: [("period", .string("week"))], route: { params in
            (params["as_json"] == .bool(true) ? "usage_report" : "usage_report_text", params)
        }),
        Command(words: ["review"], options: [
            "--period": .value("period", choices: ["week", "month"]), "--start": .value("start"), "--end": .value("end"),
        ], operation: "review_unassigned", defaults: [("period", .string("week"))]),
        Command(words: ["snapshot"], options: [
            "--period": .value("period", choices: ["week", "month"]), "--start": .value("start"), "--end": .value("end"),
            "--with-human-time": .flag("with_human_time"),
        ], operation: "get_snapshot", defaults: [("period", .string("week"))]),
        Command(words: ["export"], options: [
            "--period": .value("period", choices: ["week", "month"]), "--start": .value("start"), "--end": .value("end"),
            "--project": .value("project"), "--client": .value("client"),
        ], operation: "export_entries", output: .auto, defaults: [("period", .string("week"))]),
        Command(words: ["report-rows"], options: [
            "--period": .value("period", choices: ["week", "month"]), "--start": .value("start"), "--end": .value("end"),
            "--client": .value("client"), "--project": .append("project"),
        ], operation: "report_rows", defaults: [("period", .string("month"))]),
        Command(words: ["assign-group"], positionals: ["target"], options: [
            "--provider": .value("provider"), "--folder": .value("folder"), "--branch": .value("branch"),
            "--project": .value("project"), "--task": .value("task"), "--start": .value("start"), "--end": .value("end"),
            "--save-folder": .flag("save_folder"),
        ], required: ["--provider", "--start", "--end"], operation: "assign_group",
           checks: ["provider": ("harness_id", { (try? Store.harnessID($0)) != nil })]),
        Command(words: ["entries"], options: [
            "--period": .value("period", choices: ["week", "month"]), "--start": .value("start"), "--end": .value("end"),
            "--project": .value("project"), "--unassigned": .flag("unassigned"), "--limit": .value("limit"),
        ], operation: "list_entries", defaults: [("period", .string("week"))], integers: ["limit"]),
        Command(words: ["refresh-prices"], options: ["--if-stale": .flag("if_stale")], operation: "refresh_prices"),
        Command(words: ["openrouter-sync"], options: ["--key-stdin": .flag("key_stdin"), "--clear": .flag("clear")],
                exclusive: [["--key-stdin", "--clear"]], operation: "sync_openrouter", output: .auto,
                readsInputWhen: { $0["key_stdin"] == .bool(true) },
                route: { params in (params["clear"] == .bool(true) ? "clear_openrouter" : "sync_openrouter", params) }),
        Command(words: ["toggl", "projects"], operation: "list_toggl_projects", readsInput: true),
        Command(words: ["toggl", "link"], options: ["--workspace": .value("workspace")], operation: "link_toggl",
                readsInput: true, integers: ["workspace"]),
        Command(words: ["toggl", "workspace"], positionals: ["id"], operation: "choose_toggl_workspace", integers: ["id"]),
        Command(words: ["toggl", "unlink"], operation: "unlink_toggl", output: .none),
        Command(words: ["toggl", "import"], options: [
            "--source": .value("source"), "--project": .value("project"), "--start": .value("start"), "--end": .value("end"),
        ], required: ["--source", "--project", "--start", "--end"], operation: "import_toggl", readsInput: true,
           integers: ["source"]),
        Command(words: ["blocks"], options: ["--hours": .value("hours"), "--active": .flag("active")],
                operation: "usage_blocks", integers: ["hours"]),
    ]

    struct Parsed {
        let command: Command
        let params: JSON
        let database: String
    }

    struct UsageError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Finds the command and reads its arguments. Returns nil when the Swift engine doesn't have it yet.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Parsed? {
        var rest = arguments[...]
        var database: String?
        while let first = rest.first, first.hasPrefix("--db") {
            if first == "--db" {
                rest = rest.dropFirst()
                guard let value = rest.first else { throw UsageError(message: "argument --db: expected one argument") }
                database = value
                rest = rest.dropFirst()
            } else if first.hasPrefix("--db=") {
                database = String(first.dropFirst(5))
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        guard let command = commands
            .filter({ Array(rest.prefix($0.words.count)) == $0.words })
            .max(by: { $0.words.count < $1.words.count }) else { return nil }
        let words = Array(rest.dropFirst(command.words.count))
        let params = try read(words, for: command)
        guard command.ported(params) else { return nil }
        let path = database.map { Values.resolvedPath($0) } ?? Values.databasePath(environment: environment)
        return Parsed(command: command, params: params, database: path)
    }

    private static func read(_ words: [String], for command: Command) throws -> JSON {
        var values: [(String, JSON)] = command.defaults
        var seen: [String] = []
        var positionals: [String] = []
        var positionalIndexes: [Int] = []
        // Unknown options, kept with their position: argparse lists every unrecognized argument at the end.
        var unknown: [(Int, String)] = []
        var onlyPositionals = false
        var index = 0
        func store(_ param: String, _ value: JSON) {
            if let existing = values.firstIndex(where: { $0.0 == param }) { values[existing].1 = value } else { values.append((param, value)) }
        }
        while index < words.count {
            let word = words[index]
            index += 1
            if onlyPositionals || !word.hasPrefix("-") || word == "-" {
                positionals.append(word)
                positionalIndexes.append(index - 1)
                continue
            }
            if word == "--" { onlyPositionals = true; continue }
            let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            guard let option = command.options[name] else {
                unknown.append((index - 1, word))
                continue
            }
            seen.append(name)
            switch option {
            case let .flag(param):
                guard name == word else { throw UsageError(message: "argument \(name): ignored explicit argument") }
                store(param, .bool(true))
            case let .constant(param, value):
                guard name == word else { throw UsageError(message: "argument \(name): ignored explicit argument") }
                store(param, value)
            case let .append(param):
                let value: String
                if name != word {
                    value = String(word.dropFirst(name.count + 1))
                } else {
                    guard index < words.count, !words[index].hasPrefix("-") || words[index] == "-"
                        || Double(words[index]) != nil else {
                        throw UsageError(message: "argument \(name): expected one argument")
                    }
                    value = words[index]
                    index += 1
                }
                let existing = values.first { $0.0 == param }?.1.arrayValue ?? []
                store(param, .array(existing + [.string(value)]))
            case let .value(param, choices):
                let value: String
                if name != word {
                    value = String(word.dropFirst(name.count + 1))
                } else {
                    guard index < words.count, !words[index].hasPrefix("-") || words[index] == "-"
                        || Double(words[index]) != nil else {
                        throw UsageError(message: "argument \(name): expected one argument")
                    }
                    value = words[index]
                    index += 1
                }
                if let choices, !choices.contains(value) {
                    let listed = choices.map { "'\($0)'" }.joined(separator: ", ")
                    throw UsageError(message: "argument \(name): invalid choice: '\(value)' (choose from \(listed))")
                }
                store(param, .string(value))
            }
        }
        for group in command.exclusive + command.oneOf {
            // argparse names the option given second, then the one it conflicts with, in command-line order.
            var given: [String] = []
            for name in seen where group.contains(name) && !given.contains(name) { given.append(name) }
            if given.count > 1 {
                throw UsageError(message: "argument \(given[1]): not allowed with argument \(given[0])")
            }
        }
        for group in command.oneOf where !group.contains(where: seen.contains) {
            throw UsageError(message: "one of the arguments \(group.joined(separator: " ")) is required")
        }
        let missing = command.required.filter { !seen.contains($0) }
        if positionals.count < command.positionals.count || !missing.isEmpty {
            let names = command.positionals.dropFirst(positionals.count) + missing.map { $0 }
            throw UsageError(message: "the following arguments are required: \(names.joined(separator: ", "))")
        }
        let extra = zip(positionalIndexes, positionals).dropFirst(command.positionals.count).map { ($0.0, $0.1) }
        if !unknown.isEmpty || !extra.isEmpty {
            let words = (unknown + extra).sorted { $0.0 < $1.0 }.map(\.1)
            throw UsageError(message: "unrecognized arguments: \(words.joined(separator: " "))")
        }
        for (param, value) in zip(command.positionals, positionals) { store(param, .string(value)) }
        for (param, value) in values where command.integers.contains(param) {
            guard let text = value.stringValue, Int(text.pythonStripped) != nil else {
                throw UsageError(message: "argument \(command.label(param)): invalid int value: '\(value.stringValue ?? "")'")
            }
        }
        for (param, value) in values {
            if let check = command.checks[param], let text = value.stringValue, !check.1(text) {
                throw UsageError(message: "argument \(command.label(param)): invalid \(check.0) value: '\(text)'")
            }
        }
        return .object(values)
    }

    /// The commands, one per line, for `--help` and unknown commands.
    static var usage: String {
        let words = commands.map { $0.words.joined(separator: " ") }
        return "usage: tracker [--db PATH] <command> ...\n\ncommands:\n" + words.map { "  " + $0 }.joined(separator: "\n")
            + "\n  call <operation> [--json PARAMS]\n  api schema"
    }

    /// Whether the command reads stdin, so the command line knows to pass it on.
    static func readsInput(_ arguments: [String]) -> Bool {
        guard let parsed = (try? parse(arguments)) ?? nil else { return false }
        return parsed.command.readsInputWhen?(parsed.params) ?? parsed.command.readsInput
    }

    /// Runs a command the way the former `python3 -m tracker` did and returns what it prints, or nil
    /// for an unknown command. Errors carry the engine's message with the "tracker: " prefix.
    static func run(_ arguments: [String], input: Data? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data? {
        let parsed: Parsed
        do {
            guard let found = try parse(arguments, environment: environment) else { return nil }
            parsed = found
        } catch let error as UsageError {
            throw EngineError.invalid("tracker: error: \(error.message)")
        }
        let context = OperationContext(databasePath: parsed.database, actor: .cli, input: input)
        let result: JSON
        do {
            let (operation, params) = parsed.command.route?(parsed.params) ?? (parsed.command.operation, parsed.params)
            result = try Engine.call(operation, params, context: context)
        } catch let error as EngineError {
            throw EngineError.invalid("tracker: \(error.message)")
        } catch let error as SQLiteError {
            throw EngineError.invalid("tracker: \(error.message)")
        } catch let error as CocoaError {
            throw EngineError.invalid("tracker: \(error.localizedDescription)")
        }
        switch parsed.command.output {
        case .none: return Data()
        case .id: return Data(((result["id"].stringValue ?? "") + "\n").utf8)
        case .json: return Data((result.pythonText() + "\n").utf8)
        case .auto:
            if let text = result.stringValue { return Data(text.utf8) }
            if result == .null { return Data() }
            return Data((result.pythonText() + "\n").utf8)
        }
    }
}
