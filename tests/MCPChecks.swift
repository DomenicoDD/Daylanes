import Foundation

// Checks for the MCP server (core/MCP.swift). Build and run on macOS:
//   d="$(mktemp -d)"; xcrun swiftc -parse-as-library core/*.swift tests/MCPChecks.swift -o "$d/mcp" && "$d/mcp"

@main
struct MCPChecks {
    static var failures = 0

    /// A condition that throws counts as a failure, so one broken call doesn't hide the rest.
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
        do {
            if try !condition() {
                failures += 1
                print("FAIL line \(line): \(message)")
            }
        } catch {
            failures += 1
            print("FAIL line \(line): \(message) (threw \(error.localizedDescription))")
        }
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-checks-\(UUID().uuidString)")
        let repo = folder.appendingPathComponent("shop")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/ACME-12-checkout\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("ledger.sqlite3").path
        let environment = ["TRACKER_DB": database]
        func setup(_ arguments: String...) throws {
            _ = try CLI.run(arguments, environment: environment)
        }
        try setup("init", "--timezone", "Europe/Rome", "--currency", "EUR")
        try setup("project", "add", "Shop", "--kind=billable", "--client=Acme", "--folder", repo.path)
        try setup("project", "add", "Site", "--kind", "internal")
        try setup("project", "add", "Solo", "--kind", "internal", "--github", "acme/solo")
        try setup("project", "add", "Left", "--kind", "internal", "--github", "acme/shared")
        try setup("project", "add", "Right", "--kind=billable", "--client=Acme", "--github", "acme/shared")
        try setup("focus", "save-rule", "--project", "Shop", "--field", "domain", "--keyword", "acme.example")

        var session = MCP.Session(options: MCP.Options(databasePath: database, lockReason: { nil }))
        var nextID = 0
        func send(_ method: String, _ params: String = "{}") throws -> JSON {
            nextID += 1
            let line = "{\"jsonrpc\": \"2.0\", \"id\": \(nextID), \"method\": \"\(method)\", \"params\": \(params)}"
            guard let reply = MCP.answer(line, session: &session) else { return .null }
            check(!reply.contains("\n"), "a reply is one line")
            let parsed = try JSON.parse(reply)
            check(parsed["id"].intValue == nextID && parsed["jsonrpc"].stringValue == "2.0", "\(method) echoes the id")
            return parsed
        }
        func tool(_ name: String, _ arguments: String = "{}") throws -> JSON {
            try send("tools/call", "{\"name\": \"\(name)\", \"arguments\": \(arguments)}")["result"]
        }

        // Protocol
        check(try send("tools/list")["error"]["code"].intValue == -32601, "tools need initialize first")
        let hello = try send("initialize", "{\"protocolVersion\": \"2025-06-18\", \"capabilities\": {}}")["result"]
        check(hello["protocolVersion"].stringValue == "2025-06-18", "a known protocol version is kept")
        check(hello["serverInfo"]["name"].stringValue == "tracker", "the server names itself")
        check(hello["capabilities"]["tools"].pairs != nil && hello["capabilities"]["resources"].pairs != nil, "capabilities")
        check(hello["instructions"].stringValue?.contains("read-only") == true, "instructions say the connection is read-only")
        var other = MCP.Session(options: MCP.Options(databasePath: database, lockReason: { nil }))
        let future = MCP.answer("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\"}}",
                                session: &other).flatMap { try? JSON.parse($0) }
        check(future?["result"]["protocolVersion"].stringValue == MCP.protocolVersions[0], "an unknown version gets the newest")
        check(MCP.answer("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", session: &session) == nil,
              "notifications get no reply")
        check(MCP.answer("not json", session: &session)?.contains("-32700") == true, "bad JSON is a parse error")
        check(MCP.answer("[1]", session: &session)?.contains("-32600") == true, "a non-object is an invalid request")
        check(try send("ping")["result"] == .object([]), "ping")
        check(try send("nope")["error"]["code"].intValue == -32601, "unknown methods are refused")

        // Tools
        let listed = try send("tools/list")["result"]["tools"].arrayValue ?? []
        let names = listed.compactMap { $0["name"].stringValue }
        for expected in ["get_status", "resolve_context", "list_clients", "list_projects", "list_rules", "list_installed_apps", "list_chrome_profiles", "get_week"] {
            check(names.contains(expected), "\(expected) is offered")
        }
        check(Set(names).count == names.count, "tool names are unique")
        for item in listed {
            let name = item["name"].stringValue ?? "?"
            check(item["inputSchema"]["type"].stringValue == "object", "\(name) has an object schema")
            check(item["inputSchema"]["additionalProperties"] == .bool(false), "\(name) refuses unknown arguments")
            check(item["annotations"]["readOnlyHint"] == .bool(true), "\(name) is marked read-only")
            check(!["create_client", "set_up_project", "move_project", "map_folder"].contains(name), "\(name) needs write access")
            check((item["description"].stringValue ?? "").count > 20, "\(name) is described")
        }
        for entry in MCPTools.all {
            if let operation = Engine.operation(entry.operation) {
                check(operation.effect == .read || !names.contains(entry.name), "\(entry.name) is offered only when it reads")
            } else {
                check(!names.contains(entry.name), "\(entry.name) waits for its operation")
            }
        }
        check(!names.contains("save_rule") && !names.contains("log_time"), "no write tools are offered")
        check(try send("tools/call", "{\"name\": \"save_project\", \"arguments\": {}}")["error"]["code"].intValue == -32602,
              "an operation that writes can't be called by name")

        for expected in ["get_day", "list_entries", "list_unassigned", "usage_report", "billing_summary", "get_billing_terms",
                         "get_report", "usage_windows"] {
            check(names.contains(expected), "\(expected) is offered")
        }
        for item in listed where item["inputSchema"]["required"].arrayValue?.isEmpty == true {
            guard let name = item["name"].stringValue else { continue }
            check(try tool(name)["isError"] == .bool(false), "\(name) runs with default arguments")
        }
        let appSearch = try tool("list_installed_apps", "{\"query\": \"com.apple.TextEdit\"}")
        let app = appSearch["structuredContent"]["data"].arrayValue?.first
        check(app?["name"].stringValue?.isEmpty == false && app?["app_id"] == .string("com.apple.TextEdit"),
              "read access can find an installed bundle")
        check(try tool("get_report", "{\"projects\": [\"Shop\"], \"period\": \"month\", \"client\": \"Acme\"}")["isError"] == .bool(false),
              "get_report takes a list of projects")
        check(try tool("usage_windows", "{\"hours\": 48, \"active_only\": true}")["isError"] == .bool(false),
              "usage_windows passes its options on")
        check(try tool("billing_summary", "{\"start\": \"2026-11-01\", \"end\": \"2026-12-01\"}")["structuredContent"]["data"]["total"]
            .stringValue == "0.00", "an empty month bills nothing")
        check(try tool("list_entries", "{\"limit\": 0}")["structuredContent"]["error"]["message"].stringValue?.contains("Limit") == true,
              "an operation's own checks reach the caller")
        let page = try tool("get_report", "{\"limit\": 10}")["structuredContent"]["data"]
        check(page["row_count"].intValue == 0 && page["next_offset"].isNull && page["offset"].intValue == 0, "get_report pages its rows")
        check(try tool("get_report", "{\"offset\": -1}")["isError"] == .bool(true), "a negative offset is refused")
        let waiting = try tool("list_unassigned", "{\"period\": \"month\"}")["structuredContent"]["data"]
        check(waiting["repositories"].arrayValue?.isEmpty == true && waiting["repository_count"].intValue == 0
              && waiting["tokens"].intValue == 0, "list_unassigned sums by repository")
        check(try tool("list_unassigned", "{\"limit\": 0}")["isError"] == .bool(true), "a limit must be positive")

        // Work trees
        let linked = folder.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("gitdir: \(repo.path)/.git/worktrees/linked\n".utf8).write(to: linked.appendingPathComponent(".git"))
        let tree = AgentOperations.workTree(linked.appendingPathComponent("src").path)
        check(tree?.root == linked.path && tree?.main == repo.path, "a linked work tree names its main checkout")
        let own = AgentOperations.workTree(repo.appendingPathComponent("src").path)
        check(own?.root == repo.path && own?.main == nil, "a main checkout is its own root")
        let gone = AgentOperations.workTree("/nowhere-\(UUID().uuidString)/.codex/worktrees/ab12/shop/src/app")
        check(gone?.root.hasSuffix("/.codex/worktrees/ab12/shop") == true && gone?.main == nil, "a deleted Codex worktree is placed by its path")
        let nested = AgentOperations.workTree("/nowhere-\(UUID().uuidString)/shop/.claude/worktrees/fix/src")
        check(nested?.root.hasSuffix("/shop/.claude/worktrees/fix") == true && nested?.main?.hasSuffix("/shop") == true,
              "a deleted Claude worktree names its repository")
        check(AgentOperations.workTree("/nowhere-\(UUID().uuidString)/plain/folder") == nil, "a folder outside Git has no work tree")

        check(try tool("get_day", "{\"day\": \"2026-11-18\"}")["structuredContent"]["data"]["day"].stringValue == "2026-11-18",
              "get_day takes its day")

        let status = try tool("get_status")
        check(status["isError"] == .bool(false), "get_status succeeds")
        let envelope = status["structuredContent"]
        check(envelope["schema"].stringValue == "tracker.v1" && envelope["currency"].stringValue == "EUR"
              && envelope["timezone"].stringValue == "Europe/Rome", "results come in the envelope")
        check(envelope["data"]["access"].stringValue == "read", "status reports the access level")
        check(envelope["data"]["api"]["major"].intValue == 1, "status reports the API version")
        check(envelope["data"]["counts"]["projects"].intValue == 5 && envelope["data"]["counts"]["rules"].intValue == 1,
              "status counts projects and rules")
        check(envelope["data"]["counts"]["clients"].intValue == 2, "status counts clients")
        let text = status["content"].arrayValue?.first?["text"].stringValue ?? ""
        check(try JSON.parse(text) == envelope, "the text content is the same JSON")

        let clients = try tool("list_clients")["structuredContent"]["data"].arrayValue ?? []
        check(clients.count == 2, "two clients")
        check(clients.first { $0["name"].stringValue == "Acme" }?["projects"].intValue == 2, "a client's projects are counted")
        check(clients.first { $0["is_self"] == .bool(true) }?["name"].stringValue == "Me", "the self client is marked")
        let projects = try tool("list_projects")["structuredContent"]["data"].arrayValue ?? []
        check(projects.compactMap { $0["name"].stringValue } == ["Left", "Right", "Shop", "Site", "Solo"], "projects are listed")
        let rules = try tool("list_rules")["structuredContent"]["data"]["rules"].arrayValue ?? []
        check(rules.first?["keyword"].stringValue == "acme.example", "rules are listed")
        let week = try tool("get_week", "{\"day\": \"2026-11-18\"}")["structuredContent"]["data"]["days"].arrayValue ?? []
        check(week.count == 7 && week.first?["day"].stringValue == "2026-11-16", "the week starts on Monday")

        // Context
        func context(_ arguments: String) throws -> JSON { try tool("resolve_context", arguments)["structuredContent"]["data"] }
        let inside = try context("{\"folder\": \"\(repo.path)/src\"}")
        check(inside["project"].stringValue == "Shop" && inside["client"].stringValue == "Acme", "a folder inside a mapped folder resolves")
        check(inside["matched_by"].stringValue == "folder" && inside["billable"] == .bool(true), "it says how it matched")
        check(inside["branch"].stringValue == "feature/ACME-12-checkout", "the branch is read from .git")
        check(inside["task"].stringValue == "ACME-12", "the task comes from the branch")
        let named = try context("{\"folder\": \"\(repo.path)\", \"branch\": \"main\"}")
        check(named["branch"].stringValue == "main" && named["task"].isNull, "a given branch wins")
        let outside = try context("{\"folder\": \"\(folder.path)\"}")
        check(outside["project"].isNull && outside["matched_by"].stringValue == "none" && outside["hint"].stringValue != nil,
              "an unmapped folder says so")
        check(outside["billable"] == .bool(false), "no project is not billable")
        let solo = try context("{\"folder\": \"\(folder.path)\", \"repo\": \"Acme/Solo\"}")
        check(solo["project"].stringValue == "Solo" && solo["matched_by"].stringValue == "repo", "a repository with one project resolves")
        let both = try context("{\"folder\": \"\(folder.path)\", \"repo\": \"acme/shared\"}")
        check(both["project"].isNull && both["hint"].stringValue?.contains("share") == true, "a shared repository stays unresolved")
        let mapped = try context("{\"folder\": \"\(repo.path)\", \"repo\": \"acme/shared\"}")
        check(mapped["project"].stringValue == "Shop", "a mapped folder settles a shared repository")

        // Errors
        let unknown = try tool("get_week", "{\"week\": true}")
        check(unknown["isError"] == .bool(true)
              && unknown["structuredContent"]["error"]["code"].stringValue == "invalid_argument", "unknown arguments are refused")
        check(try tool("get_week", "{\"day\": 5}")["isError"] == .bool(true), "argument types are checked")
        check(try tool("resolve_context", "{\"repo\": \"not a repo\"}")["structuredContent"]["error"]["message"].stringValue?
            .contains("owner/repo") == true, "engine errors keep their message")
        check(try send("tools/call", "{\"name\": \"nope\"}")["error"]["code"].intValue == -32602, "unknown tools are refused")

        // Resources
        let resources = try send("resources/list")["result"]["resources"].arrayValue ?? []
        check(resources.contains { $0["uri"].stringValue == "tracker://status" }, "resources are listed")
        let read = try send("resources/read", "{\"uri\": \"tracker://projects\"}")["result"]["contents"].arrayValue?.first
        check(read?["mimeType"].stringValue == "application/json", "a resource is JSON")
        check(try JSON.parse(read?["text"].stringValue ?? "null")["data"].arrayValue?.count == 5, "a resource holds the tool's data")
        let dated = try send("resources/read", "{\"uri\": \"tracker://week/2026-11-18\"}")["result"]["contents"].arrayValue?.first
        check(try JSON.parse(dated?["text"].stringValue ?? "null")["data"]["days"].arrayValue?.count == 7, "a dated resource takes its day")
        check(try send("resources/read", "{\"uri\": \"tracker://nope\"}")["error"]["code"].intValue == -32002, "unknown resources are refused")
        check(try send("resources/read", "{\"uri\": \"tracker://week/soon\"}")["error"]["code"].intValue == -32603, "a bad day is an error")

        // Toolsets and the command line
        var core = MCP.Session(options: MCP.Options(databasePath: database, toolsets: ["core"], lockReason: { nil }))
        core.initialized = true
        check(!core.tools.contains { $0.name == "list_rules" } && core.tools.contains { $0.name == "get_status" },
              "toolsets trim the list")
        check(MCP.run(arguments: ["project", "list"]) == nil, "other commands are left alone")
        check(MCP.run(arguments: ["mcp", "--access", "propose"]) == 2, "propose access is refused for now")
        check(MCP.run(arguments: ["mcp", "--access", "all"]) == 2, "unknown access levels are refused")
        check(MCP.run(arguments: ["mcp", "--toolsets", "everything"]) == 2, "unknown toolsets are refused")
        check(MCP.run(arguments: ["mcp", "--nope"]) == 2, "unknown options are refused")

        // Setup with write access
        session = MCP.Session(options: MCP.Options(databasePath: database, access: .write, lockReason: { nil }))
        let welcome = try send("initialize", "{\"protocolVersion\": \"2025-06-18\"}")["result"]["instructions"].stringValue ?? ""
        check(!welcome.contains("read-only") && welcome.contains("set_up_project"), "write access explains the setup tools")
        let writable = try send("tools/list")["result"]["tools"].arrayValue ?? []
        let writers = writable.filter { $0["annotations"]["readOnlyHint"] == .bool(false) }.compactMap { $0["name"].stringValue }
        check(Set(writers) == ["create_client", "set_up_project", "move_project", "map_folder", "create_tracking_rule", "update_tracking_rule",
                               "delete_tracking_rule", "assign_activity", "set_chrome_profile_client", "sync_agents"],
              "write access adds the setup tools only")
        check(writable.first { $0["name"].stringValue == "delete_tracking_rule" }?["annotations"]["destructiveHint"] == .bool(true),
              "deleting a rule is marked destructive")
        check(!writable.contains { $0["name"].stringValue == "set_tracking_enabled" }, "tracking can't be turned off over MCP")
        check(!writable.contains { ["save_rule", "log_time", "set_billing_terms", "delete_entry"].contains($0["name"].stringValue ?? "") },
              "rates, raw writes and entry deletion stay out of reach")
        check(try tool("get_status")["structuredContent"]["data"]["access"].stringValue == "write", "status reports write access")
        func data(_ name: String, _ arguments: String) throws -> JSON { try tool(name, arguments)["structuredContent"]["data"] }

        let me = try data("create_client", "{\"name\": \"me\"}")
        check(me["client"].stringValue == "Me" && me["created"] == .bool(false) && me["is_self"] == .bool(true),
              "a client that exists is found whatever its case")
        let globex = try data("create_client", "{\"name\": \" Globex \"}")
        check(globex["client"].stringValue == "Globex" && globex["created"] == .bool(true), "a new client is created")
        check(try data("create_client", "{\"name\": \"Globex\"}")["created"] == .bool(false), "creating it again changes nothing")
        check(try tool("create_client", "{}")["isError"] == .bool(true), "a client needs a name")

        let work = folder.appendingPathComponent("tracker")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("docs"), withIntermediateDirectories: true)
        check(try context("{\"folder\": \"\(work.path)/docs\"}")["project"].isNull, "the new folder starts with no project")
        check(try tool("set_up_project", "{\"name\": \"Tracker\"}")["structuredContent"]["error"]["message"].stringValue?
            .contains("kind") == true, "a new project needs a kind")
        check(try tool("set_up_project", "{\"name\": \"Paid\", \"kind\": \"billable\"}")["isError"] == .bool(true),
              "a billable project needs a client")
        let made = try data("set_up_project", "{\"name\": \"Tracker\", \"kind\": \"internal\", \"folder\": \"\(work.path)\"}")
        check(made["created"] == .bool(true) && made["project"]["client"].stringValue == "Me", "an internal project goes to the own client")
        check(made["project"]["folders"].arrayValue?.count == 1, "its folder is mapped")
        let found = try context("{\"folder\": \"\(work.path)/docs\"}")
        check(found["project"].stringValue == "Tracker" && found["client"].stringValue == "Me" && found["matched_by"].stringValue == "folder",
              "the folder now resolves to the project")
        let again = try data("set_up_project", "{\"name\": \"tracker\"}")
        check(again["created"] == .bool(false) && again["project"]["name"].stringValue == "Tracker"
              && again["project"]["kind"].stringValue == "internal", "an existing project keeps what is not passed")
        check(try data("list_projects", "{}").arrayValue?.count == 6, "no duplicate project was made")

        let moved = try data("move_project", "{\"project\": \"Tracker\", \"client\": \"globex\", \"kind\": \"billable\"}")
        check(moved["from_client"].stringValue == "Me" && moved["client"].stringValue == "Globex" && moved["moved"] == .bool(true)
              && moved["kind"].stringValue == "billable", "a project moves to another client")
        let after = try context("{\"folder\": \"\(work.path)\"}")
        check(after["client"].stringValue == "Globex" && after["billable"] == .bool(true), "its folder follows it")
        check(try data("move_project", "{\"project\": \"Site\", \"client\": \"Initech\"}")["client"].stringValue == "Initech",
              "moving can create the client")
        check(try data("list_clients", "{}").arrayValue?.contains { $0["name"].stringValue == "Initech" } == true, "the new client is listed")
        check(try tool("move_project", "{\"project\": \"Nope\", \"client\": \"Acme\"}")["structuredContent"]["error"]["code"]
            .stringValue == "not_found", "an unknown project can't be moved")

        let stolen = try tool("map_folder", "{\"project\": \"Site\", \"folder\": \"\(work.path)\"}")
        check(stolen["isError"] == .bool(true) && stolen["structuredContent"]["error"]["message"].stringValue?.contains("Tracker") == true,
              "a folder is not taken from another project")
        check(try context("{\"folder\": \"\(work.path)\"}")["project"].stringValue == "Tracker", "a refused change leaves the ledger as it was")
        let taken = try data("map_folder", "{\"project\": \"Site\", \"folder\": \"\(work.path)\", \"replace\": true}")
        check(taken["previous_project"].stringValue == "Tracker" && taken["project"]["name"].stringValue == "Site", "replace moves the folder")
        check(try data("map_folder", "{\"project\": \"Site\", \"folder\": \"\(work.path)/docs\"}")["previous_project"].isNull,
              "a new folder has no previous project")
        let appArgs = """
            {"project":"site","field":"app","keyword":"TextEdit","app_id":"com.apple.TextEdit"}
            """
        let saved = try data("create_tracking_rule", appArgs)
        check(saved["created"] == .bool(true) && saved["rule"]["app_id"] == .string("com.apple.TextEdit"),
              "a write connection saves an exact app rule")
        let repeated = try data("create_tracking_rule", appArgs.replacingOccurrences(of: "\"keyword\":\"TextEdit\"",
                                                                                      with: "\"keyword\":\"Text Edit\""))
        check(repeated["created"] == .bool(false) && repeated["rule"]["id"] == saved["rule"]["id"],
              "retrying setup reuses the rule")
        let conflict = try tool("create_tracking_rule", appArgs.replacingOccurrences(of: "\"site\"", with: "\"Tracker\""))
        check(conflict["structuredContent"]["error"]["code"] == .string("conflict"), "a conflicting destination is refused")
        check(try data("list_rules", "{}")["rules"].arrayValue?.contains(saved["rule"]) == true,
              "new rules appear in the shared tracking configuration")
        let meetRule = try data("create_tracking_rule", #"""
            {"project":"Site","field":"domain","keyword":"meet.google.com","chrome_profile":"Work","tag":"Meeting"}
            """#)["rule"]
        let meetID = meetRule["id"].stringValue!
        let scoped = try data("update_tracking_rule", #"{"id":"\#(meetID)","chrome_profile_id":"Profile 12"}"#)
        check(scoped["updated"] == .bool(true) && scoped["rule"]["chrome_profile_id"] == .string("Profile 12")
              && scoped["rule"]["chrome_profile"].isNull && scoped["rule"]["tag"] == .string("Meeting")
              && scoped["rule"]["project"] == .string("Site") && scoped["rule"]["keyword"] == .string("meet.google.com"),
              "editing a rule replaces its scope and keeps omitted fields")
        let same = try data("update_tracking_rule", #"{"id":"\#(meetID)","chrome_profile_id":"Profile 12"}"#)
        check(same["updated"] == .bool(false), "repeating an edit is idempotent")
        _ = try data("create_tracking_rule", #"""
            {"project":"Tracker","field":"domain","keyword":"meet.google.com","chrome_profile_id":"Profile 13"}
            """#)
        let contested = try tool("update_tracking_rule", #"{"id":"\#(meetID)","chrome_profile_id":"Profile 13"}"#)
        check(contested["structuredContent"]["error"]["code"] == .string("conflict"), "an edit cannot claim another rule's profile")
        let cleared = try data("update_tracking_rule", #"{"id":"\#(meetID)","chrome_profile_id":""}"#)
        check(cleared["rule"]["chrome_profile_id"].isNull && cleared["rule"]["tag"] == .string("Meeting"),
              "an empty profile clears its scope without clearing the tag")
        let ignored = try data("update_tracking_rule", #"{"id":"\#(meetID)","ignore":true}"#)["rule"]
        check(ignored["ignore"] == .bool(true) && ignored["project"].isNull && ignored["tag"].isNull,
              "ignoring future matches clears the tracking destination and tag")
        let tracked = try data("update_tracking_rule", #"{"id":"\#(meetID)","project":"Site"}"#)["rule"]
        check(tracked["project"] == .string("Site") && tracked["ignore"].isNull,
              "setting a project on an ignored rule resumes tracking")
        let missing = try tool("update_tracking_rule", #"{"id":"missing","tag":"Meeting"}"#)
        check(missing["structuredContent"]["error"]["code"] == .string("not_found"), "editing a missing rule never creates it")

        let bare = try data("create_tracking_rule", #"{"project":"Site","field":"url","keyword":"github.com/acme/site/"}"#)
        check(bare["rule"]["keyword"] == .string("https://github.com/acme/site"), "a URL without a scheme is read as https")
        let removed = try data("delete_tracking_rule", #"{"id":"\#(meetID)"}"#)
        check(removed["deleted"]["id"] == .string(meetID), "a rule is deleted and returned")
        check(try data("list_rules", "{}")["rules"].arrayValue?.contains { $0["id"].stringValue == meetID } == false, "the rule is gone")
        check(try tool("delete_tracking_rule", #"{"id":"\#(meetID)"}"#)["structuredContent"]["error"]["code"] == .string("not_found"),
              "deleting it twice says it is missing")
        check(try tool("delete_tracking_rule", #"{"id":"auto:project:Site"}"#)["isError"] == .bool(true),
              "automatic name rules can't be deleted")

        let ledger = try Database(path: database)
        for (id, end) in [("11111111-1111-4111-8111-111111111111", 1), ("22222222-2222-4222-8222-222222222222", 1),
                          ("33333333-3333-4333-8333-333333333333", 0)] {
            try ledger.execute("INSERT INTO focus_blocks VALUES (?, 'com.example.chat', 'Chat', ?, ?, ?, NULL, 0)",
                               [id, Values.nowMillis() - 7_200_000, Values.nowMillis() - 3_600_000, end])
        }
        let appTime = try data("list_unassigned_activity", "{}")
        check(appTime["block_count"].intValue == 2 && appTime["apps"].arrayValue?.first?["app_name"] == .string("Chat")
              && appTime["millis"].intValue == 7_200_000, "unassigned app time is listed by app")
        check(try data("get_status", "{}")["counts"]["unassigned_blocks"].intValue == 2, "status counts the same blocks")
        check(appTime["apps"].arrayValue?.first?["top_titles"] == .array([]), "no titles are kept unless the setting is on")
        let detailed = #"[{"id":"44444444-4444-4444-8444-444444444444","app_id":"com.example.chat","app_name":"Chat","started_at":1,"ended_at":60001,"closed":true,"details":[{"title":"Acme launch plan","address":"https://docs.example.com/d/1?token=secret#x","millis":45000},{"title":"Inbox","address":"","millis":15000}]}]"#
        try Focus.record(ledger, try JSON.parse(detailed))
        check(try ledger.query("SELECT * FROM focus_details").isEmpty, "details are dropped while the setting is off")
        try Focus.setKeepDetails(ledger, true)
        try ledger.execute("DELETE FROM focus_blocks WHERE id = '44444444-4444-4444-8444-444444444444'")
        try Focus.record(ledger, try JSON.parse(detailed))
        let kept = try data("list_unassigned_activity", #"{"start":"1970-01-01","end":"1970-01-02"}"#)["apps"].arrayValue?.first
        check(kept?["top_titles"].arrayValue?.first?["title"] == .string("Acme launch plan")
              && kept?["top_sites"].arrayValue?.first?["address"] == .string("https://docs.example.com/d/1"),
              "kept titles and sites show up, without queries or fragments")
        try Focus.setKeepDetails(ledger, false)
        check(try ledger.query("SELECT * FROM focus_details").isEmpty, "turning the setting off deletes what was kept")
        _ = try data("assign_activity", #"{"ids":["11111111-1111-4111-8111-111111111111"],"project":"Site"}"#)
        _ = try data("assign_activity", #"{"ids":["22222222-2222-4222-8222-222222222222"],"ignore":true}"#)
        check(try data("list_unassigned_activity", "{}")["block_count"].intValue == 0, "assigned and ignored blocks leave the list")
        let open = try tool("assign_activity", #"{"ids":["33333333-3333-4333-8333-333333333333"],"project":"Site"}"#)
        check(open["structuredContent"]["error"]["code"] == .string("conflict"), "a block still being recorded is refused")
        check(try tool("assign_activity", #"{"ids":[],"project":"Site"}"#)["isError"] == .bool(true), "assigning needs a block")
        check(try data("set_chrome_profile_client", #"{"profile_id":"Profile 12","client":"Acme"}"#)["chrome_profile_clients"]["Profile 12"]
              == .string("Acme"), "a Chrome profile links to a client")
        check(try data("set_chrome_profile_client", #"{"profile_id":"Profile 12","client":""}"#)["chrome_profile_clients"]["Profile 12"]
              .isNull, "an empty client removes the link")
        check(try tool("set_chrome_profile_client", #"{"profile_id":"Profile 12","client":"Nobody"}"#)["isError"] == .bool(true),
              "an unknown client is refused")
        var plain = MCP.Session(options: MCP.Options(databasePath: database, lockReason: { nil }))
        plain.initialized = true
        check(!plain.tools.contains { $0.toolset == "setup" }, "a read connection never gets the setup tools")
        var trimmed = MCP.Session(options: MCP.Options(databasePath: database, access: .write, toolsets: ["core"], lockReason: { nil }))
        trimmed.initialized = true
        check(!trimmed.tools.contains { $0.toolset == "setup" }, "toolsets can leave the setup tools out")

        // Licence lock (core/LicenceStamp.swift)
        let stampPath = folder.appendingPathComponent("licence-stamp.json").path
        check(LicenceStamp.lockReason(path: stampPath, enforced: true) != nil, "no stamp yet locks the tools")
        try LicenceStamp.write(.init(licensed: false, trialEndsAt: .now.addingTimeInterval(3600)), to: stampPath)
        check(LicenceStamp.lockReason(path: stampPath, enforced: true) == nil, "a running trial unlocks the tools")
        try LicenceStamp.write(.init(licensed: false, trialEndsAt: .now.addingTimeInterval(-60)), to: stampPath)
        check(LicenceStamp.lockReason(path: stampPath, enforced: true) != nil, "an ended trial locks the tools")
        try LicenceStamp.write(.init(licensed: true, trialEndsAt: .now.addingTimeInterval(-60)), to: stampPath)
        check(LicenceStamp.lockReason(path: stampPath, enforced: true) == nil, "a licence unlocks the tools after the trial")
        try? FileManager.default.removeItem(atPath: stampPath)
        check(LicenceStamp.lockReason(path: stampPath, enforced: false) == nil, "a build without payments never locks")

        var lockedSession = MCP.Session(options: MCP.Options(databasePath: database, access: .write,
                                                             lockReason: { "Your Daylanes trial has ended." }))
        let lockedHello = MCP.answer(#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}"#, session: &lockedSession)
        check(lockedHello?.contains("trial has ended") == true, "a locked server says so in its instructions")
        check(lockedSession.tools.map(\.name) == ["get_status"], "a locked server offers only get_status")
        let lockedCall = try JSON.parse(MCP.answer(
            #"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_projects", "arguments": {}}}"#,
            session: &lockedSession) ?? "")["result"]
        check(lockedCall["isError"] == .bool(true)
              && lockedCall["structuredContent"]["error"]["code"] == .string("trial_ended"),
              "a locked tool answers trial_ended, not unknown tool")
        let lockedStatus = try JSON.parse(MCP.answer(
            #"{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_status", "arguments": {}}}"#,
            session: &lockedSession) ?? "")["result"]["structuredContent"]["data"]
        check(lockedStatus["locked"] == .bool(true) && lockedStatus["locked_reason"].stringValue != nil,
              "get_status reports the lock")

        if failures > 0 {
            print("\(failures) MCP check(s) failed")
            exit(1)
        }
        print("MCP checks passed")
    }
}
