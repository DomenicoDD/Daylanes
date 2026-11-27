import Foundation

/// Read operations written for agents (docs/MCP_API_PLAN.md section 8.1): where the ledger stands,
/// and which client and project a folder belongs to.
enum AgentOperations {
    static let all: [EngineOperation] = [
        EngineOperation(name: "get_status", summary: "The ledger, tracking state, counts and the agent tools seen.",
                        effect: .read) { _, db, context in
            try status(db, context)
        },
        EngineOperation(name: "resolve_context", summary: "The client, project, task and pull request a folder belongs to.",
                        effect: .read) { params, db, _ in
            try resolveContext(Params(params), db)
        },
        EngineOperation(name: "describe_clients", summary: "Clients with their project counts.", effect: .read) { _, db, _ in
            try clients(db)
        },
        EngineOperation(name: "unassigned_by_repository", summary: "Agent work with no project, one row per repository.",
                        effect: .read) { params, db, _ in
            try unassignedByRepository(Params(params), db)
        },
        EngineOperation(name: "report_page", summary: "Billing report rows, a page at a time.", effect: .read) { params, db, _ in
            try reportPage(Params(params), db)
        },
        EngineOperation(name: "ensure_client", summary: "Create a client unless it exists.", effect: .config) { params, db, _ in
            try ensureClient(Params(params), db)
        },
        EngineOperation(name: "set_up_project", summary: "Create a project, or update its kind, client or folder.",
                        effect: .config) { params, db, _ in
            try setUpProject(Params(params), db)
        },
        EngineOperation(name: "move_project", summary: "Move a project to another client.", effect: .config) { params, db, _ in
            try moveProject(Params(params), db)
        },
        EngineOperation(name: "map_project_folder", summary: "Send a folder's work to a project, without taking it from another.",
                        effect: .config) { params, db, _ in
            let p = Params(params)
            let project = try existingProject(db, try p.required("project"))
            let folder = try mapFolder(db, project: project.name, folder: try p.required("folder"), replace: try p.bool("replace"))
            return .object([("folder", .string(folder.path)), ("previous_project", .optional(folder.previous)),
                            ("project", try projectRecord(db, project.name))])
        },
    ]

    // MARK: Unassigned work by repository

    /// The Git work tree that holds `folder`: its root and, for a linked work tree, the main checkout it
    /// belongs to. Read from the file system without running Git. A folder that no longer exists is placed
    /// by its path when it sits in a Codex or Claude worktrees folder.
    static func workTree(_ folder: String) -> (root: String, main: String?)? {
        let manager = FileManager.default
        var url = URL(fileURLWithPath: folder)
        for _ in 0..<64 {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (url.path, nil) }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else {
                    return (url.path, nil)
                }
                let target = String(text.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let base = target.hasPrefix("/") ? target : url.appendingPathComponent(target).standardized.path
                if let range = base.range(of: "/.git/worktrees/") { return (url.path, String(base[..<range.lowerBound])) }
                return (url.path, nil)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        let parts = folder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let index = parts.firstIndex(of: "worktrees"), index > 0 else { return nil }
        func path(_ count: Int) -> String { "/" + parts.prefix(count).joined(separator: "/") }
        if parts[index - 1] == ".codex", parts.count > index + 2 { return (path(index + 3), nil) }
        if parts[index - 1] == ".claude", parts.count > index + 1, index > 1 { return (path(index + 2), path(index - 1)) }
        return nil
    }

    /// Agent entries with no project, added up per repository, largest first. A linked work tree names its
    /// main checkout, and the project that checkout is mapped to.
    static func unassignedByRepository(_ p: Params, _ db: Database) throws -> JSON {
        let (start, end, period) = try ReportOperations.period(p, "week")
        let limit = try p.int("limit") ?? 50
        if limit < 1 { throw EngineError.invalid("Limit must be positive") }
        let (bounds, entries) = try EntryStore.scope(db, start: start, end: end, period: period)
        let zone = try Store.timezone(db)
        final class Group {
            var main: String?
            var folders = Set<String>(), branches = Set<String>(), tools = Set<String>()
            var tokens = 0, runtime = 0, entries = 0, last = 0
        }
        var trees: [String: (root: String, main: String?)] = [:]
        var groups: [String: Group] = [:]
        var totalTokens = 0, totalEntries = 0
        for entry in entries where entry.project == nil {
            guard let tool = entry.provider.nonEmpty else { continue }
            let folder = entry.folder.nonEmpty ?? ""
            let tree: (root: String, main: String?)
            if let known = trees[folder] {
                tree = known
            } else {
                tree = (folder.isEmpty ? nil : workTree(folder)) ?? (folder, nil)
                trees[folder] = tree
            }
            let group: Group
            if let found = groups[tree.root] { group = found } else { group = Group(); groups[tree.root] = group }
            group.main = tree.main
            group.folders.insert(folder)
            if let branch = entry.branch.nonEmpty { group.branches.insert(branch) }
            group.tools.insert(tool)
            group.tokens += entry.tokenTotal
            if entry.kind == "runtime" { group.runtime += entry.millis ?? 0 }
            group.entries += 1
            group.last = max(group.last, entry.at)
            totalTokens += entry.tokenTotal
            totalEntries += 1
        }
        let mapped: [(path: String, project: String)] = try db.query("SELECT path, project FROM folders ORDER BY length(path) DESC, path")
            .compactMap { row in
                guard let path = row["path"].string, let project = row["project"].string else { return nil }
                return (path, project)
            }
        func project(for folder: String?) -> String? {
            guard let folder else { return nil }
            for mapping in mapped {
                let inside = mapping.path.hasSuffix("/") ? mapping.path : mapping.path + "/"
                if folder == mapping.path || folder.hasPrefix(inside) { return mapping.project }
            }
            return nil
        }
        /// A removed agent work tree (".../worktrees/<id>/<repo>") can no longer name its main checkout.
        /// It is suggested for the one project whose mapped folders end in the same repository name.
        func projectByName(_ root: String) -> String? {
            guard root.contains("/worktrees/"), !FileManager.default.fileExists(atPath: root) else { return nil }
            let name = (root as NSString).lastPathComponent.lowercased()
            let projects = Set(mapped.filter { ($0.path as NSString).lastPathComponent.lowercased() == name }.map(\.project))
            return projects.count == 1 ? projects.first : nil
        }
        let sorted = groups.sorted { a, b in a.value.tokens != b.value.tokens ? a.value.tokens > b.value.tokens : a.key < b.key }
        let rows = sorted.prefix(limit).map { root, group -> JSON in
            let byCheckout = project(for: group.main)
            let byName = byCheckout == nil && group.main == nil ? projectByName(root) : nil
            return .object([
                ("repository", root.isEmpty ? .null : .string(root)),
                ("name", root.isEmpty ? .null : .string((root as NSString).lastPathComponent)),
                ("main_checkout", .optional(group.main)), ("suggested_project", .optional(byCheckout ?? byName)),
                ("suggested_by", byCheckout != nil ? .string("main_checkout") : byName != nil ? .string("repository_name") : .null),
                ("tools", JSON.strings(group.tools.sorted())), ("folders", .int(Int64(group.folders.count))),
                ("branches", .int(Int64(group.branches.count))), ("entries", .int(Int64(group.entries))),
                ("tokens", .int(Int64(group.tokens))), ("runtime_millis", .int(Int64(group.runtime))),
                ("last_at", instant(group.last, zone: zone)),
            ])
        }
        var result = bounds
        result.set("repository_count", .int(Int64(groups.count)))
        result.set("entry_count", .int(Int64(totalEntries)))
        result.set("tokens", .int(Int64(totalTokens)))
        result.set("repositories", .array(Array(rows)))
        return result
    }

    /// `report_rows` with its rows cut to a page, so a month fits in an agent's context.
    static func reportPage(_ p: Params, _ db: Database) throws -> JSON {
        let (start, end, period) = try ReportOperations.period(p, "month")
        let limit = try p.int("limit") ?? 25
        let offset = try p.int("offset") ?? 0
        guard limit >= 1, offset >= 0 else { throw EngineError.invalid("Limit must be positive and offset must not be negative") }
        var report = try ReportRows.build(db, start: start, end: end, period: period, client: try p.string("client"),
                                          projects: try p.strings("project"))
        let rows = report["rows"].arrayValue ?? []
        let page = Array(rows.dropFirst(offset).prefix(limit))
        let next = offset + page.count
        report.set("rows", .array(page))
        report.set("row_count", .int(Int64(rows.count)))
        report.set("offset", .int(Int64(offset)))
        report.set("next_offset", next < rows.count ? .int(Int64(next)) : .null)
        // The summary is the same on every page; send it once.
        if offset > 0 { report.set("billing", .null) }
        return report
    }

    // MARK: Setup an agent may do (clients, projects and folders; never rates)

    /// The stored spelling of a client, matched without regard to case, so "me" finds "Me".
    static func storedClient(_ db: Database, _ name: String) throws -> String? {
        let wanted = name.lowercased()
        return try Store.clientList(db).first { $0.lowercased() == wanted }
    }

    static func existingProject(_ db: Database, _ asked: String) throws -> (name: String, client: String?, kind: String) {
        let wanted = try Values.required(asked, "Project").lowercased()
        for row in try db.query("SELECT name, client, kind FROM projects ORDER BY name") {
            if let name = row["name"].string, name.lowercased() == wanted {
                return (name, row["client"].string, row["kind"].string ?? "internal")
            }
        }
        throw EngineError.notFound("Unknown project: \(asked)")
    }

    static func projectRecord(_ db: Database, _ name: String) throws -> JSON {
        (try Store.projectList(db).arrayValue ?? []).first { $0["name"].stringValue == name } ?? .null
    }

    /// Maps a folder to a project. A folder that already belongs to another project stays there unless `replace`.
    static func mapFolder(_ db: Database, project: String, folder: String, replace: Bool) throws -> (path: String, previous: String?) {
        let path = try Values.folderPath(folder)
        let parameters: [SQLBindable] = [path]
        let previous = try db.first("SELECT project FROM folders WHERE path = ?", parameters)?["project"].string
        if let previous, previous != project, !replace {
            throw EngineError.conflict("This folder already belongs to \(previous). Pass replace to move it.")
        }
        try Store.mapFolder(db, project: project, folder: path)
        return (path, previous == project ? nil : previous)
    }

    static func ensureClient(_ p: Params, _ db: Database) throws -> JSON {
        let asked = try Values.required(try p.required("name"), "Client name")
        let stored = try storedClient(db, asked)
        if stored == nil { try Store.saveClient(db, name: asked, previous: nil) }
        let name = stored ?? asked
        let own = try Store.selfClient(db)
        return .object([("client", .string(name)), ("created", .bool(stored == nil)), ("is_self", .bool(name == own))])
    }

    static func setUpProject(_ p: Params, _ db: Database) throws -> JSON {
        let asked = try Values.required(try p.required("name"), "Project")
        let existing = try? existingProject(db, asked)
        let name = existing?.name ?? asked
        guard let kind = try p.string("kind") ?? existing?.kind else {
            throw EngineError.invalid("A new project needs a kind: billable, internal or personal")
        }
        var client = try p.string("client") ?? existing?.client
        if let given = client { client = try storedClient(db, given) ?? given }
        try Store.createProject(db, name: name, client: client, kind: kind, folder: nil)
        if let folder = try p.string("folder") { _ = try mapFolder(db, project: name, folder: folder, replace: false) }
        return .object([("created", .bool(existing == nil)), ("project", try projectRecord(db, name))])
    }

    /// Moves a project, with all of its history, to another client. The client is created when it is new.
    static func moveProject(_ p: Params, _ db: Database) throws -> JSON {
        let project = try existingProject(db, try p.required("project"))
        let asked = try Values.required(try p.required("client"), "Client")
        let client = try storedClient(db, asked) ?? asked
        let kind = try p.string("kind") ?? project.kind
        try Store.createProject(db, name: project.name, client: client, kind: kind, folder: nil)
        return .object([("project", .string(project.name)), ("from_client", .optional(project.client)),
                        ("client", .string(client)), ("kind", .string(kind)), ("moved", .bool(project.client != client))])
    }

    /// A ledger timestamp (milliseconds) as ISO 8601 with the ledger zone's offset.
    static func instant(_ millis: Int?, zone: TimeZone) -> JSON {
        guard let millis else { return .null }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = zone
        return .string(formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000)))
    }

    static func status(_ db: Database, _ context: OperationContext) throws -> JSON {
        let zone = try Store.timezone(db)
        func count(_ sql: String) throws -> JSON { .int(Int64(try db.first(sql)?[0].int ?? 0)) }
        let tools = try db.query(
            "SELECT provider, count(*) AS entries, max(at) AS last_at FROM entries "
            + "WHERE provider IS NOT NULL GROUP BY provider ORDER BY provider"
        ).map { row -> JSON in
            .object([("tool", row["provider"].json), ("entries", row["entries"].json),
                     ("last_entry_at", instant(row["last_at"].int, zone: zone))])
        }
        let lastActivity = try db.first("SELECT max(ended_at) FROM focus_blocks")?[0].int
        let recording = try db.first("SELECT 1 FROM focus_blocks WHERE closed = 0 LIMIT 1") != nil
        return .object([
            ("api", .object([("major", .int(Int64(MCP.apiMajor))), ("minor", .int(Int64(MCP.apiMinor)))])),
            ("database", .string(context.databasePath)),
            ("tracking", .object([
                ("enabled", .bool(try Store.setting(db, "focus_enabled", "0") == "1")),
                ("recording_now", .bool(recording)),
                ("last_activity_at", instant(lastActivity, zone: zone)),
            ])),
            ("counts", .object([
                ("clients", .int(Int64(try Store.clientList(db).count))),
                ("projects", try count("SELECT count(*) FROM projects")),
                ("rules", try count("SELECT count(*) FROM focus_rules")),
                ("unassigned_blocks", try count(
                    "SELECT count(*) FROM focus_blocks WHERE project IS NULL AND ignored = 0 AND closed = 1")),
            ])),
            ("agent_tools", .array(tools)),
        ])
    }

    static func clients(_ db: Database) throws -> JSON {
        let own = try Store.selfClient(db)
        var counts: [String: Int] = [:]
        for row in try db.query("SELECT client, count(*) AS projects FROM projects WHERE client IS NOT NULL GROUP BY client") {
            if let name = row["client"].string { counts[name] = row["projects"].int ?? 0 }
        }
        return .array(try Store.clientList(db).map { name -> JSON in
            .object([("name", .string(name)), ("is_self", .bool(name == own)), ("projects", .int(Int64(counts[name] ?? 0)))])
        })
    }

    /// The branch checked out in the Git work tree that holds `folder`, read from `.git` without running Git.
    static func gitBranch(_ folder: String) -> String? {
        let manager = FileManager.default
        var url = URL(fileURLWithPath: folder)
        for _ in 0..<64 {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var head = dotGit.appendingPathComponent("HEAD")
                if !isDirectory.boolValue {
                    // A linked work tree: `.git` is a file that points at its own Git folder.
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
                    let target = String(text.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let base = target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.appendingPathComponent(target)
                    head = base.appendingPathComponent("HEAD")
                }
                guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    /// Which project a folder, branch, repository or pull request belongs to. A routed pull request wins
    /// (the one given, or the branch's own), then the longest mapped folder, then the one project linked
    /// to the folder's GitHub repository.
    static func resolveContext(_ p: Params, _ db: Database) throws -> JSON {
        let folder = Values.resolvedPath(try p.string("folder") ?? FileManager.default.currentDirectoryPath)
        let branch = try p.string("branch") ?? gitBranch(folder)
        let givenRepo = try p.string("repo").map { try GitHub.repoName($0) }
        let repos = givenRepo.map { [$0] } ?? GitHub.worktreeRepos(folder)
        let given = try p.int("pull_request")

        var project: String?
        var repo = repos.first
        var matchedBy = "none"
        // Without a number, the branch's own pull request counts when the repository's cached list has exactly one.
        var number = given
        var branchPullRequest: JSON?
        if given == nil, let branch {
            let links = try GitHub.linksByBranch(db)
            for candidate in repos {
                let matches = links[GitHub.branchKey(candidate, branch)] ?? []
                if matches.count == 1 {
                    branchPullRequest = matches[0]
                    number = matches[0]["number"].intValue
                    repo = candidate
                    break
                }
            }
        }
        if let number {
            for candidate in repos {
                let parameters: [SQLBindable] = [candidate, number]
                if let row = try db.first("SELECT project FROM github_pr_routes WHERE repo = ? AND number = ?", parameters) {
                    project = row["project"].string
                    repo = candidate
                    matchedBy = "pr_route"
                    break
                }
            }
        }
        if project == nil {
            for row in try db.query("SELECT path, project FROM folders ORDER BY length(path) DESC, path") {
                guard let root = row["path"].string else { continue }
                let inside = root.hasSuffix("/") ? root : root + "/"
                if folder == root || folder.hasPrefix(inside) {
                    project = row["project"].string
                    matchedBy = "folder"
                    break
                }
            }
        }
        // A repository names a project only when one project is linked to it; a shared repository stays unresolved.
        var shared = false
        if project == nil {
            for candidate in repos {
                let parameters: [SQLBindable] = [candidate]
                let linked = try db.query("SELECT DISTINCT project FROM github_projects WHERE repo = ? COLLATE NOCASE", parameters)
                if linked.count == 1 {
                    project = linked[0]["project"].string
                    repo = candidate
                    matchedBy = "repo"
                    break
                }
                if linked.count > 1 { shared = true }
            }
        }

        var client = JSON.null
        var kind = JSON.null
        var pullRequest = JSON.null
        if let project {
            let named: [SQLBindable] = [project]
            if let row = try db.first("SELECT client, kind FROM projects WHERE name = ?", named) {
                client = row["client"].json
                kind = row["kind"].json
            }
            let found: Row?
            if let given {
                let parameters: [SQLBindable] = [project, given]
                found = try db.first("SELECT number, title, state, url, branch FROM github_prs WHERE project = ? AND number = ?", parameters)
            } else if let branch {
                let parameters: [SQLBindable] = [project, branch]
                found = try db.first(
                    "SELECT number, title, state, url, branch FROM github_prs WHERE project = ? AND branch = ? "
                    + "ORDER BY number DESC LIMIT 1", parameters)
            } else {
                found = nil
            }
            if let found { pullRequest = found.object }
        }
        if let branchPullRequest { pullRequest = branchPullRequest }
        var result: [(String, JSON)] = [
            ("folder", .string(folder)), ("branch", .optional(branch)), ("github_repo", .optional(repo)),
            ("client", client), ("project", .optional(project)), ("kind", kind),
            ("billable", .bool(kind == .string("billable"))),
            ("task", .optional(Store.taskFromBranch(branch))), ("pull_request", pullRequest),
            ("matched_by", .string(matchedBy)),
        ]
        if project == nil {
            result.append(("hint", .string(shared
                ? "Several projects share this repository. Map the folder to one of them in Daylanes, or route the pull request."
                : "No project is mapped to this folder or its repository. Map the folder to a project in Daylanes.")))
        }
        return .object(result)
    }
}
