import Foundation

/// Foreground app time and GitHub links (port PR B).
enum FocusOperations {
    static let all: [EngineOperation] = [
        EngineOperation(name: "record_activity", summary: "Store activity blocks from the recorder.", effect: .reversible) { params, db, context in
            let blocks: JSON
            if let list = params["blocks"].arrayValue {
                blocks = .array(list)
            } else if let input = context.input {
                blocks = try JSON.parse(input)
            } else {
                blocks = .null
            }
            try Focus.record(db, blocks)
            return .null
        },
        EngineOperation(name: "close_interrupted_activity", summary: "Close blocks a stopped recorder left open.",
                        effect: .reversible) { _, db, _ in
            try Focus.closeInterrupted(db)
            return .null
        },
        EngineOperation(name: "get_tracking_config", summary: "Tracking preference, rules and pull request routes.",
                        effect: .read) { _, db, _ in
            try Focus.config(db)
        },
        EngineOperation(name: "list_installed_apps", summary: "Find Mac apps by name or bundle identifier.",
                        effect: .read) { params, _, _ in
            let query = try Values.required(try Params(params).string("query"), "App search")
            return .array(InstalledMacApp.catalog().filter { $0.matches(query) }.map { app in
                .object([("name", .string(app.name)), ("app_id", .string(app.id))])
            })
        },
        EngineOperation(name: "list_chrome_profiles", summary: "List local Google Chrome profile names and IDs.",
                        effect: .read) { _, _, _ in
            .array(ChromeProfile.catalog().map(\.object))
        },
        EngineOperation(name: "set_chrome_profile_client", summary: "Set the fallback client for future Chrome activity in a profile.",
                        effect: .config) { params, db, _ in
            let p = Params(params)
            try Focus.setChromeProfileClient(db, profileID: try p.required("profile_id"), client: try p.string("client").flatMap { $0.isEmpty ? nil : $0 })
            return try Focus.config(db)
        },
        EngineOperation(name: "set_tracking_enabled", summary: "Turn foreground app tracking on or off.", effect: .config) { params, db, _ in
            try Store.setSetting(db, "focus_enabled", try Params(params).bool("enabled") ? "1" : "0")
            return try Focus.config(db)
        },
        EngineOperation(name: "save_rule", summary: "Assign or ignore future app, window, domain or URL activity.",
                        effect: .config) { params, db, _ in
            let p = Params(params)
            try Focus.saveRule(db, project: try destination(p), field: params["field"], keyword: params["keyword"],
                               appScope: params["app_scope"], tag: params["tag"], id: try p.string("id"),
                               chromeProfile: try p.string("chrome_profile"), chromeProfileID: try p.string("chrome_profile_id"),
                               appID: try p.string("app_id"))
            return try Focus.config(db)
        },
        EngineOperation(name: "create_tracking_rule", summary: "Create a tracking rule without replacing existing rules.",
                        effect: .config) { params, db, _ in
            let result = try writeRule(db, params)
            return .object([("rule", try rule(db, id: result.id)), ("created", .bool(result.created))])
        },
        EngineOperation(name: "update_tracking_rule", summary: "Edit an existing tracking rule by ID.",
                        effect: .config) { params, db, _ in
            let id = try Params(params).required("id")
            let existing = try rule(db, id: id)
            var changes = existing
            let fields = ["project", "ignore", "field", "keyword", "app_id", "app_scope", "tag", "chrome_profile", "chrome_profile_id"]
            // Supplying either profile field replaces the existing profile selection.
            let patch = Params(params)
            if patch.has("chrome_profile") || patch.has("chrome_profile_id") {
                changes.set("chrome_profile", .null)
                changes.set("chrome_profile_id", .null)
            }
            if let field = try patch.string("field"), field != existing["field"].stringValue {
                changes.set("app_id", .null)
                let wasBrowser = ["domain", "url"].contains(existing["field"].stringValue ?? "")
                let isBrowser = field == "domain" || field == "url"
                if wasBrowser != isBrowser { changes.set("app_scope", .null) }
                if !isBrowser {
                    changes.set("chrome_profile", .null)
                    changes.set("chrome_profile_id", .null)
                }
            }
            for key in fields where patch.has(key) {
                let value = params[key]
                changes.set(key, value.stringValue == "" ? .null : value)
            }
            if patch.has("ignore"), try patch.bool("ignore"), !patch.has("project") {
                changes.set("project", .null)
            } else if patch.has("project"), !patch.has("ignore") {
                changes.set("ignore", .bool(false))
            }
            _ = try writeRule(db, changes, id: id)
            let updated = try rule(db, id: id)
            return .object([("rule", updated), ("updated", .bool(updated != existing))])
        },
        EngineOperation(name: "delete_rule", summary: "Delete a tracking rule.", effect: .guarded) { params, db, _ in
            try db.execute("DELETE FROM focus_rules WHERE id = ?", [try Params(params).required("id")])
            return try Focus.config(db)
        },
        EngineOperation(name: "delete_tracking_rule", summary: "Delete a saved tracking rule by ID and return it.",
                        effect: .guarded) { params, db, _ in
            let id = try Params(params).required("id")
            if id.hasPrefix("auto:") {
                throw EngineError.invalid("Automatic name rules can't be deleted. Turn them off for the project instead.")
            }
            let deleted = try rule(db, id: id)
            try db.execute("DELETE FROM focus_rules WHERE id = ?", [id])
            return .object([("deleted", deleted)])
        },
        EngineOperation(name: "set_auto_rules", summary: "Turn a project's automatic name rules on or off.",
                        effect: .config) { params, db, _ in
            let p = Params(params)
            try Focus.setAutoRules(db, project: try p.required("project"), enabled: try p.bool("enabled"))
            return try Focus.config(db)
        },
        EngineOperation(name: "classify_activity", summary: "Assign, ignore or unassign recorded blocks.",
                        effect: .reversible) { params, db, _ in
            let p = Params(params)
            // "ids" is the MCP form; "id" with "additional_ids" is what the app and CLI send.
            let ids = try p.strings("ids") ?? ([try p.required("id")] + (try p.strings("additional_ids") ?? []))
            guard !ids.isEmpty, ids.count <= 1000 else { throw EngineError.invalid("Give between 1 and 1,000 block IDs") }
            let project = try p.string("project"), ignore = try p.bool("ignore")
            for id in ids {
                try Focus.classify(db, id: id, project: project, ignored: ignore)
            }
            return .null
        },
        EngineOperation(name: "unassigned_activity", summary: "Recorded app time with no project, grouped by app.",
                        effect: .read) { params, db, _ in
            let p = Params(params)
            let range = try EntryStore.dayRange(db, start: try p.string("start"), end: try p.string("end"),
                                                period: try p.string("period") ?? "week")
            return try Focus.unassignedActivity(db, since: range.since, until: range.until,
                                                bounds: (range.first, range.last), limit: try p.int("limit") ?? 50)
        },
        EngineOperation(name: "get_week", summary: "The Monday-to-Sunday week of recorded blocks and agent runtime.",
                        effect: .read) { params, db, _ in
            try Focus.weekTimeline(db, day: try Params(params).string("day"))
        },
        EngineOperation(name: "github_status", summary: "Whether the GitHub CLI is installed and signed in.", effect: .read) { _, _, _ in
            GitHub.authStatus()
        },
        EngineOperation(name: "link_repository", summary: "Link a GitHub repository to a project.", effect: .config) { params, db, _ in
            let p = Params(params)
            return .object([("repo", .string(try Store.setRepo(db, project: try p.required("project"), repo: try p.required("repo"))))])
        },
        EngineOperation(name: "link_folder_repositories",
                        summary: "Link unlinked projects to the GitHub repository their folders' git remotes name.",
                        effect: .config) { params, db, _ in
            let only = try Params(params).string("project").map { [$0] }
            return .array(try GitHub.autoLink(db, projects: only).map { .object([("project", .string($0.0)), ("repo", .string($0.1))]) })
        },
        EngineOperation(name: "refresh_pull_requests", summary: "Load a project's pull requests from GitHub.",
                        effect: .external) { params, db, _ in
            let p = Params(params)
            return try GitHub.refresh(db, project: try p.required("project"), repository: try p.string("repo"))
        },
        EngineOperation(name: "unlink_repository", summary: "Remove a project's repository link and its pull requests.",
                        effect: .guarded) { params, db, _ in
            try GitHub.unlink(db, project: try Params(params).required("project"))
            return .null
        },
        EngineOperation(name: "route_pull_request", summary: "Route a pull request to a project.", effect: .config) { params, db, _ in
            let p = Params(params)
            guard let number = try p.int("number") else { throw EngineError.invalid("number is required") }
            return try GitHub.setRoute(db, project: try p.required("project"), number: number, remove: try p.bool("remove"))
        },
    ]

    private static func rule(_ db: Database, id: String) throws -> JSON {
        guard let row = try db.first("SELECT * FROM focus_rules WHERE id = ?", [id]) else {
            throw EngineError.notFound("This rule no longer exists")
        }
        return Focus.ruleObject(row)
    }

    private static func writeRule(_ db: Database, _ params: JSON, id: String? = nil) throws -> (id: String, created: Bool) {
        let p = Params(params)
        let project = try destination(p).map { try AgentOperations.existingProject(db, $0).name }
        return try Focus.saveRule(db, project: project, field: params["field"], keyword: params["keyword"],
                                  appScope: params["app_scope"], tag: params["tag"], id: id,
                                  chromeProfile: try p.string("chrome_profile"), chromeProfileID: try p.string("chrome_profile_id"),
                                  appID: try p.string("app_id"))
    }

    private static func destination(_ params: Params) throws -> String? {
        if try params.bool("ignore") {
            guard try params.string("project") == nil else {
                throw EngineError.invalid("Choose a project or ignore matching activity.")
            }
            return nil
        }
        return try params.required("project")
    }

}
