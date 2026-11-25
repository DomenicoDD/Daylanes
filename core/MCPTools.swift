import Foundation

/// One MCP tool: a public name and input schema bound to an operation of the engine.
/// A tool is offered only while its operation is registered, so tools appear as the engine grows.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    /// The input properties as JSON Schema, in the order they are listed.
    var properties: [(String, JSON)] = []
    var required: [String] = []
    let operation: String
    var toolset = "core"
    /// Input names the operation knows under another name.
    var rename: [String: String] = [:]
    /// Parameters the tool always passes to its operation.
    var fixed: [(String, JSON)] = []

    var inputSchema: JSON {
        .object([("type", .string("object")), ("properties", .object(properties)),
                 ("required", JSON.strings(required)), ("additionalProperties", .bool(false))])
    }

    /// Checks the arguments against the schema and returns the operation's parameters.
    func operationParams(_ arguments: JSON) throws -> JSON {
        guard let pairs = arguments.pairs ?? (arguments.isNull ? [] : nil) else {
            throw EngineError.invalid("Tool arguments must be an object")
        }
        for key in required where !pairs.contains(where: { $0.0 == key && !$0.1.isNull }) {
            throw EngineError.invalid("Missing required argument: \(key)")
        }
        var out = fixed
        for (key, value) in pairs {
            guard let schema = properties.first(where: { $0.0 == key })?.1 else {
                throw EngineError.invalid("Unknown argument: \(key)")
            }
            if value.isNull { continue }
            let matches: Bool
            switch schema["type"].stringValue {
            case "string": matches = value.stringValue != nil
            case "integer": matches = value.intValue != nil
            case "boolean": matches = value.boolValue != nil
            case "array": matches = value.arrayValue?.allSatisfy { $0.stringValue != nil } ?? false
            case "object": matches = value.pairs != nil
            default: matches = true
            }
            guard matches else { throw EngineError.invalid("Invalid value for \(key)") }
            if let choices = schema["enum"].arrayValue, !choices.contains(value) {
                throw EngineError.invalid("Invalid value for \(key)")
            }
            out.append((rename[key] ?? key, value))
        }
        return .object(out)
    }
}

enum MCPTools {
    static func string(_ description: String, choices: [String]? = nil, format: String? = nil) -> JSON {
        var schema: [(String, JSON)] = [("type", .string("string"))]
        if let format { schema.append(("format", .string(format))) }
        if let choices { schema.append(("enum", JSON.strings(choices))) }
        schema.append(("description", .string(description)))
        return .object(schema)
    }

    static func integer(_ description: String) -> JSON {
        .object([("type", .string("integer")), ("description", .string(description))])
    }

    static func boolean(_ description: String) -> JSON {
        .object([("type", .string("boolean")), ("description", .string(description))])
    }

    static func strings(_ description: String) -> JSON {
        .object([("type", .string("array")), ("items", .object([("type", .string("string"))])),
                 ("description", .string(description))])
    }

    /// The date range every report takes: both dates, or a period ending today.
    static func range(_ more: [(String, JSON)] = []) -> [(String, JSON)] {
        let dates: [(String, JSON)] = [
            ("start", string("First day, in the ledger's time zone. Give it together with end.", format: "date")),
            ("end", string("The day after the last day (exclusive).", format: "date")),
            ("period", string("The current week or month, when no dates are given.", choices: ["week", "month"])),
        ]
        return dates + more
    }

    static let client: (String, JSON) = ("client", string("Limit to this client, by name."))
    static let project: (String, JSON) = ("project", string("Limit to this project, by name."))

    private static let trackingRuleFields: [(String, JSON)] = [
        ("project", string("The existing destination project, by name. Required for tracked rules.")),
        ("ignore", boolean("Keep matching app time in Ignored. Supply this instead of a project.")),
        ("field", string("What to match.", choices: ["app", "window", "domain", "url"])),
        ("keyword", string("The installed app name, window title text, domain, or URL prefix.")),
        ("app_id", string("An exact Mac app ID for an app or window title rule. An empty string clears it on update.")),
        ("app_scope", string("Part of the app name for window rules or the exact Chrome window name for browser rules. An empty string clears it on update.")),
        ("chrome_profile_id", string("A local Chrome profile ID from list_chrome_profiles. An empty string clears the profile scope on update.")),
        ("chrome_profile", string("A label from the Daylanes extension. Use this instead of chrome_profile_id. An empty string clears the profile scope on update.")),
        ("tag", string("Optional label for matching activity. An empty string clears it on update.")),
    ]

    static let all: [MCPTool] = [
        // Orientation
        MCPTool(name: "get_status", title: "Daylanes status",
                description: "Start here. The ledger's time zone and currency, whether tracking is on, how much is waiting for a project, and which agent tools have history.",
                operation: "get_status"),
        MCPTool(name: "resolve_context", title: "Which project is this?",
                description: "The client, project, task and pull request a folder belongs to. With no arguments it uses the folder the server was started in and its checked-out branch.",
                properties: [
                    ("folder", string("An absolute folder path. Defaults to the server's working directory.")),
                    ("branch", string("A Git branch. Defaults to the branch checked out in the folder.")),
                    ("repo", string("A GitHub repository as owner/repo. Defaults to the folder's remotes.")),
                    ("pull_request", integer("A pull request number in that repository.")),
                ], operation: "resolve_context"),
        MCPTool(name: "list_clients", title: "Clients",
                description: "Every client with its number of projects. The client marked is_self stands for your own internal and personal work.",
                operation: "describe_clients"),
        MCPTool(name: "list_projects", title: "Projects",
                description: "Every project with its client, kind (billable, internal or personal), mapped folders and linked GitHub repository.",
                operation: "list_projects"),
        MCPTool(name: "list_rules", title: "Tracking rules",
                description: "The rules that send app, window, domain and URL activity to projects, the automatic name rules, and pull request routes.",
                operation: "get_tracking_config", toolset: "admin"),
        MCPTool(name: "list_installed_apps", title: "Find installed Mac apps",
                description: "Search Mac apps by name or bundle identifier. Returns the installed names and app identifiers for exact app rules.",
                properties: [("query", string("Part of the installed app name or its macOS bundle identifier."))],
                required: ["query"], operation: "list_installed_apps", toolset: "admin"),

        MCPTool(name: "list_chrome_profiles", title: "Chrome profiles",
                description: "List local Google Chrome profile names and IDs on this Mac. Use an ID to scope a domain or URL rule.",
                operation: "list_chrome_profiles", toolset: "admin"),

        // Time and activity
        MCPTool(name: "get_week", title: "A week of activity",
                description: "The Monday-to-Sunday week that holds a day: recorded blocks per day with app, project and tag, and agent run time per day. Times are milliseconds since 1970.",
                properties: [("day", string("Any day of the week you want. Defaults to today.", format: "date"))],
                operation: "get_week"),
        MCPTool(name: "get_day", title: "One day, column by column",
                description: "One day as the app's day view shows it: your blocks, one column per agent thread with its runs and tokens, and the billing spans with amounts.",
                properties: [("day", string("The day. Defaults to today.", format: "date"))],
                operation: "get_day"),
        MCPTool(name: "list_entries", title: "Ledger entries",
                description: "The raw entries of a period with their ids: your time, agent runs, agent token usage and expenses. Use it to look something up, not to add up money; billing_summary does that.",
                properties: range([
                    project,
                    ("unassigned", boolean("Only entries with no project.")),
                    ("limit", integer("The most entries to return, newest last. Defaults to 50.")),
                ]), operation: "list_entries"),
        MCPTool(name: "list_unassigned", title: "Agent work with no project",
                description: "Agent work that counts for no project yet, one row per repository, largest first, with tools, tokens and run time. For a worktree of another checkout it gives main_checkout, and suggested_project when that checkout is mapped: map the row's repository to that project.",
                properties: range([("limit", integer("The most repositories to return. Defaults to 50."))]),
                operation: "unassigned_by_repository"),
        MCPTool(name: "usage_report", title: "Hours, tokens and costs",
                description: "Your hours, agent run time and tokens, expenses and API-equivalent value per project for a period, with totals and the invoice lines.",
                properties: range([client, project, ("task", string("Limit to this task id."))]),
                operation: "usage_report"),

        // Billing
        MCPTool(name: "billing_summary", title: "Invoice lines",
                description: "What to invoice per client and project for a period: your time, agent time and agent usage with rates, the monthly cap reduction and totals. Amounts are final; do not recompute them from rows.",
                properties: range(), operation: "billing_summary", toolset: "billing"),
        MCPTool(name: "get_billing_terms", title: "Rates and billing modes",
                description: "The hourly rate, agent billing mode, agent rate, usage markup and monthly cap of each client and project, and the exchange rate used for usage billing.",
                operation: "list_billing_terms", toolset: "billing"),
        MCPTool(name: "get_report", title: "Report rows",
                description: "The line items behind an invoice: your work sessions, agent threads per day and expenses, each with an amount. Any grouping of the rows adds up to billing_summary to the cent.",
                properties: range([
                    client, ("projects", strings("Limit to these projects, by name.")),
                    ("limit", integer("The most rows to return. Defaults to 25.")),
                    ("offset", integer("Rows to skip. Pass the next_offset of the page before; it is null on the last page.")),
                ]), operation: "report_page", toolset: "billing", rename: ["projects": "project"]),
        MCPTool(name: "usage_windows", title: "Five-hour usage windows",
                description: "Agent usage in the five-hour windows that Claude and ChatGPT plans meter, with burn rate, projection and the plan limits a tool reported.",
                properties: [
                    ("hours", integer("How far back to look. Defaults to 24.")),
                    ("active_only", boolean("Only the windows open now.")),
                ], operation: "usage_blocks", toolset: "billing", rename: ["active_only": "active"]),

        // Setup (offered only with --access write)
        MCPTool(name: "create_client", title: "Create a client",
                description: "Create a client by name. Does nothing when it exists already (names match without regard to case) and says which it was. Use the client marked is_self for the person's own work instead of making a new one.",
                properties: [("name", string("The client's name, as it should appear on reports."))],
                required: ["name"], operation: "ensure_client", toolset: "setup"),
        MCPTool(name: "set_up_project", title: "Create or update a project",
                description: "Create a project under a client and map a folder to it, so that agent work in that folder counts for it from now on and in the past. On an existing project it changes only what you pass. A new client is created as needed. It never sets rates.",
                properties: [
                    ("name", string("The project's name.")),
                    ("client", string("The client it belongs to. Left out on a new internal or personal project, it is the person's own client.")),
                    ("kind", string("billable for client work that is invoiced, internal for the person's own business, personal for private work. Required on a new project.",
                                    choices: ["billable", "internal", "personal"])),
                    ("folder", string("An absolute folder path to map to the project, usually the repository root.")),
                ], required: ["name"], operation: "set_up_project", toolset: "setup"),
        MCPTool(name: "move_project", title: "Move a project to another client",
                description: "Move a project to another client, for one that was filed under the wrong client. All of its recorded time and usage moves with it, and its own rates stay. The client is created when it is new.",
                properties: [
                    ("project", string("The project to move, by name.")),
                    ("client", string("The client it should belong to.")),
                    ("kind", string("Also change the kind, for example to billable when it moves from the person's own client to a paying one.",
                                    choices: ["billable", "internal", "personal"])),
                ], required: ["project", "client"], operation: "move_project", toolset: "setup"),
        MCPTool(name: "map_folder", title: "Map a folder to a project",
                description: "Send the agent work done in a folder, and in the folders inside it, to a project. A folder that belongs to another project is left alone unless replace is true.",
                properties: [
                    ("project", string("The project, by name.")),
                    ("folder", string("An absolute folder path.")),
                    ("replace", boolean("Take the folder from the project it belongs to now.")),
                ], required: ["project", "folder"], operation: "map_project_folder", toolset: "setup"),
        MCPTool(name: "create_tracking_rule", title: "Create a tracking rule",
                description: "Route future activity to a project or keep it in Ignored. Reuses an identical rule and refuses conflicting destinations. Use list_installed_apps or list_chrome_profiles for exact IDs.",
                properties: trackingRuleFields, required: ["field", "keyword"],
                operation: "create_tracking_rule", toolset: "setup"),
        MCPTool(name: "update_tracking_rule", title: "Edit a tracking rule",
                description: "Edit a saved rule by the ID returned by list_rules. Omitted fields keep their values when applicable. A supplied Chrome profile replaces the existing profile scope. Conflicting destinations are refused.",
                properties: [("id", string("The saved rule ID from list_rules."))] + trackingRuleFields,
                required: ["id"], operation: "update_tracking_rule", toolset: "setup"),

        // Names from the first server, kept for one release.
        MCPTool(name: "review_unassigned", title: "Unassigned work by folder and branch",
                description: "Unassigned entries grouped by tool, folder and branch: the detail behind list_unassigned. It includes your own time logged with no project, as rows with no provider.",
                properties: range(), operation: "review_unassigned"),
    ]
}
