import Foundation

/// GitHub links, pull request routes and the `gh` calls behind them (Python's `tracker/github.py`).
enum GitHub {
    /// `owner/repo`, lower case, from a bare name (Python's `repo_name`).
    static func repoName(_ value: String) throws -> String {
        var repo = value
        if repo.hasSuffix("/") { repo.removeLast() }
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let failure = EngineError.invalid("Enter a GitHub repository as owner/repo")
        guard repo.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9-]*/[a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil,
              !repo.contains("\n") else { throw failure }
        let name = repo.split(separator: "/", omittingEmptySubsequences: false)[1]
        if name == "." || name == ".." { throw failure }
        return repo.lowercased()
    }

    static func unlink(_ db: Database, project: String) throws {
        try db.beginImmediate()
        try Store.project(db, project)
        try Store.clearPullRequests(db, project: project)
        try db.execute("DELETE FROM github_projects WHERE project = ?", [project])
        // Unlinking is a choice: the folders' repository is not linked again on its own.
        try Store.setSetting(db, autoLinkOffKey(project), "1")
    }

    static func autoLinkOffKey(_ project: String) -> String { "github_autolink_off:" + project }

    /// Links each unlinked project to the GitHub repository its folders' git remotes name, when they name exactly one
    /// and no other project has it. Projects whose repository was unlinked by hand are left alone.
    /// Returns the new links as project → repository.
    @discardableResult
    static func autoLink(_ db: Database, projects only: [String]? = nil) throws -> [(String, String)] {
        try db.beginImmediate()
        let linked = Set(try db.query("SELECT repo FROM github_projects").compactMap { $0["repo"].string?.lowercased() })
        // Count every project's folder repositories first, so a repository two projects name is never linked to one,
        // even when the other project is already linked, opted out, or names several.
        var named: [(project: String, eligible: Bool, repos: [String])] = []
        var claims: [String: Int] = [:]
        for project in try Store.projectList(db).arrayValue ?? [] {
            guard let name = project["name"].stringValue else { continue }
            var repos: [String] = []
            for folder in project["folders"].arrayValue?.compactMap(\.stringValue) ?? [] {
                if let repo = worktreeRepos(folder).first, !repos.contains(repo) { repos.append(repo) }
            }
            for repo in repos { claims[repo, default: 0] += 1 }
            let eligible = try project["github_repo"].stringValue.nonEmpty == nil && Store.setting(db, autoLinkOffKey(name)) == nil
            named.append((name, eligible, repos))
        }
        var candidates: [(String, String)] = named.compactMap { entry in
            guard entry.eligible, entry.repos.count == 1, let repo = entry.repos.first,
                  claims[repo] == 1, !linked.contains(repo) else { return nil }
            return (entry.project, repo)
        }
        if let only { candidates.removeAll { !only.contains($0.0) } }
        for (project, repo) in candidates {
            try db.execute("INSERT INTO github_projects (project, repo) VALUES (?, ?)", [project, repo])
        }
        return candidates
    }

    static func setRoute(_ db: Database, project: String, number: Int, remove: Bool) throws -> JSON {
        guard number > 0, number <= 2_147_483_647 else { throw EngineError.invalid("Enter a valid pull request number") }
        try db.beginImmediate()
        guard let repo = try db.first("SELECT repo FROM github_projects WHERE project = ?", [project])?["repo"].string else {
            throw EngineError.invalid("Connect a GitHub repository to this project first")
        }
        if remove {
            try db.execute("DELETE FROM github_pr_routes WHERE repo = ? AND number = ? AND project = ?", [repo, number, project])
        } else {
            if let existing = try db.first("SELECT project FROM github_pr_routes WHERE repo = ? AND number = ?",
                                           [repo, number])?["project"].string, existing != project {
                throw EngineError.conflict("Pull request #\(number) is routed to \(existing). Remove that route first.")
            }
            try db.execute("INSERT OR IGNORE INTO github_pr_routes VALUES (?, ?, ?)", [repo, number, project])
        }
        return .object([("repo", .string(repo)), ("number", .int(Int64(number))), ("project", .string(project))])
    }

    struct Route {
        var project: String?
        var pullRequests: [(Int, String)] = []
        var projects: [String] = []

        var json: JSON {
            .object([("project", .optional(project)),
                     ("pull_requests", .object(pullRequests.map { (String($0.0), .string($0.1)) })),
                     ("projects", .strings(projects))])
        }

        func project(forPullRequest number: Int?) -> String? {
            guard let number else { return nil }
            return pullRequests.first { $0.0 == number }?.1
        }
    }

    /// Linked repositories (lower case) with the project they belong to and their routed pull requests.
    static func routes(_ db: Database) throws -> [(String, Route)] {
        var order: [String] = []
        var result: [String: Route] = [:]
        let rows = try db.query(
            "SELECT link.repo, link.project, route.number FROM github_projects AS link "
            + "LEFT JOIN github_pr_routes AS route ON route.project = link.project "
            + "AND route.repo = link.repo ORDER BY link.project, route.number")
        for row in rows {
            guard let repo = row["repo"].string?.lowercased(), let project = row["project"].string else { continue }
            if result[repo] == nil {
                order.append(repo)
                result[repo] = Route(project: project)
            }
            var route = result[repo]!
            if !route.projects.contains(project) { route.projects.append(project) }
            if let number = row["number"].int {
                if let index = route.pullRequests.firstIndex(where: { $0.0 == number }) {
                    route.pullRequests[index].1 = project
                } else {
                    route.pullRequests.append((number, project))
                }
            }
            if route.projects.count > 1 { route.project = nil }
            result[repo] = route
        }
        return order.map { ($0, result[$0]!) }
    }

    static func routesJSON(_ db: Database) throws -> JSON {
        .object(try routes(db).map { ($0.0, $0.1.json) })
    }

    // MARK: Local Git state (never contacts a remote)

    /// Runs /usr/bin/git without GIT_* variables, stdout only, giving up after two seconds (like the
    /// Python engine's `timeout=2`). posix_spawn and waitpid: Process.waitUntilExit notices the exit
    /// about 70 ms late, which added up to seconds for a snapshot that reads many folders.
    private static func git(_ arguments: [String]) -> (status: Int32, output: Data)? {
        var output: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, output[0])
        posix_spawn_file_actions_addclose(&actions, output[1])
        let argv: [UnsafeMutablePointer<CChar>?] = (["/usr/bin/git"] + arguments).map { strdup($0) } + [nil]
        let env: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("GIT_") }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { vars in
                posix_spawn(&pid, "/usr/bin/git", &actions, nil, UnsafeMutablePointer(mutating: args.baseAddress!),
                            UnsafeMutablePointer(mutating: vars.baseAddress!))
            }
        }
        close(output[1])
        guard spawned == 0 else { close(output[0]); return nil }
        let timedOut = ManagedAtomicFlag()
        let watchdog = DispatchWorkItem { timedOut.set(); kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(output[0], &chunk, chunk.count)
            if count > 0 { data.append(chunk, count: count); continue }
            if count < 0, errno == EINTR { continue }
            break
        }
        close(output[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        watchdog.cancel()
        if timedOut.isSet { return nil }
        let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return (code, data)
    }

    /// The GitHub repositories a folder's `origin` and `upstream` remotes point to, from local config only.
    static func worktreeRepos(_ folder: String) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
              let result = git(["-C", folder, "config", "--local", "--no-includes", "--null", "--get-regexp",
                                #"^remote\.(origin|upstream)\.url$"#]), result.status == 0 else { return [] }
        var found: [String: String] = [:]
        for record in String(decoding: result.output, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false) {
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let url = parts.count > 1 ? String(parts[1]) : ""
            for prefix in ["https://github.com/", "ssh://git@github.com/", "git@github.com:"]
            where url.lowercased().hasPrefix(prefix) {
                if found[key] == nil, let name = try? repoName(String(url.dropFirst(prefix.count))) { found[key] = name }
                break
            }
        }
        return ["remote.origin.url", "remote.upstream.url"].compactMap { found[$0] }
    }

    /// The checked-out commit of a local folder.
    static func headCommit(_ folder: String) -> String? {
        guard let result = git(["-C", folder, "rev-parse", "--verify", "--quiet", "HEAD"]), result.status == 0 else { return nil }
        let commit = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil ? commit : nil
    }

    /// Pull requests by (repository, branch), from the most recently refreshed link of each repository.
    static func linksByBranch(_ db: Database) throws -> [String: [JSON]] {
        var sources: [(String, String)] = []
        for row in try db.query("SELECT repo, project FROM github_projects WHERE refreshed_at IS NOT NULL "
                                + "ORDER BY refreshed_at DESC, project") {
            guard let repo = row["repo"].string?.lowercased(), let project = row["project"].string else { continue }
            if !sources.contains(where: { $0.0 == repo }) { sources.append((repo, project)) }
        }
        var result: [String: [JSON]] = [:]
        for (repo, project) in sources {
            for row in try db.query("SELECT number, branch, title, state, url FROM github_prs WHERE project = ?", [project]) {
                result[branchKey(repo, row["branch"].string), default: []].append(row.object)
            }
        }
        return result
    }

    static func branchKey(_ repo: String?, _ branch: String?) -> String { "\(repo ?? "")\u{0}\(branch ?? "\u{1}")" }

    /// The repository and the single pull request (if any) an agent entry belongs to.
    static func agentContext(routes: [(String, Route)], byBranch: [String: [JSON]], localRepos: [String],
                             project: String?, branch: String?) -> (repo: String?, pullRequest: JSON?) {
        let repo: String?
        if !localRepos.isEmpty {
            repo = localRepos.first { name in routes.contains { $0.0 == name } }
        } else if let project {
            repo = routes.first { $0.1.projects.contains(project) }?.0
        } else {
            repo = nil
        }
        guard let repo else {
            return (nil, nil)
        }
        let matches = byBranch[branchKey(repo, branch)] ?? []
        return (repo, matches.count == 1 ? matches[0] : nil)
    }

    // MARK: The GitHub CLI

    static func ghPath() throws -> String {
        var candidates: [String] = []
        for folder in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(String(folder) + "/gh")
        }
        candidates += ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for candidate in candidates {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), !isFolder.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw EngineError.invalid("Install GitHub CLI and sign in with gh auth login")
    }

    private static func gh(_ command: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String, errors: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    static func authStatus() -> JSON {
        guard let command = try? ghPath() else { return .object([("status", .string("missing"))]) }
        guard let status = gh(command, ["auth", "status", "--hostname", "github.com"], timeout: 15) else {
            return .object([("status", .string("unavailable"))])
        }
        if status.status != 0 { return .object([("status", .string("unverified"))]) }
        var login: String?
        if let user = gh(command, ["api", "user", "--jq", ".login"], timeout: 15), user.status == 0 {
            let value = user.output.trimmingCharacters(in: .whitespacesAndNewlines)
            login = value.isEmpty ? nil : value
        }
        return .object([("status", .string("connected")), ("login", .optional(login))])
    }

    static func contributionAuthor() async -> String? {
        await Task.detached {
            guard let command = try? ghPath() else { return nil as String? }
            func login(_ arguments: [String], timeout: TimeInterval) -> String? {
                guard let response = gh(command, arguments, timeout: timeout), response.status == 0 else { return nil }
                let value = response.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.range(of: #"\A[A-Za-z0-9-]+\z"#, options: .regularExpression) == nil ? nil : value.lowercased()
            }
            let env = ProcessInfo.processInfo.environment
            if env["GH_TOKEN"].nonEmpty == nil, env["GITHUB_TOKEN"].nonEmpty == nil,
               let local = login(["config", "get", "user", "--host", "github.com"], timeout: 2) {
                return local
            }
            return login(["api", "--hostname", "github.com", "user", "--jq", ".login"], timeout: 10)
        }.value
    }

    static func contributionCounts(repo: String, author: String, start: String, end: String, timezone: String) async
        -> (commits: Int?, pullRequests: Int?)? {
        guard let repo = try? repoName(repo), let command = try? ghPath(),
              let zone = TimeZone(identifier: timezone), let first = try? Day.parse(start),
              let last = try? Day.parse(end), first < last else { return nil }
        let iso = ISO8601DateFormatter()
        let from = iso.string(from: Date(timeIntervalSince1970: Double(first.midnight(zone)) / 1000))
        let through = iso.string(from: Date(timeIntervalSince1970: Double(last.midnight(zone)) / 1000 - 1))
        let common = "repo:\(repo) author:\(author)"
        async let commits = searchCount(command, endpoint: "search/commits", query: "\(common) author-date:\(from)..\(through)")
        async let pulls = searchCount(command, endpoint: "search/issues", query: "\(common) is:pr created:\(from)..\(through)")
        return await (commits, pulls)
    }

    private static func searchCount(_ command: String, endpoint: String, query: String) async -> Int? {
        await Task.detached {
            guard let result = gh(command, ["api", "--hostname", "github.com", "--method", "GET", endpoint,
                                            "-f", "q=\(query)", "-F", "per_page=1"], timeout: 12),
                  result.status == 0, let response = try? JSON.parse(result.output),
                  response["incomplete_results"].boolValue == false else { return nil }
            return response["total_count"].intValue
        }.value
    }

    static func fetchPullRequests(_ repo: String) throws -> [JSON] {
        let command = try ghPath()
        guard let result = gh(command, ["pr", "list", "--repo", "github.com/" + repo, "--state", "all", "--limit", "150",
                                        "--json", "number,headRefName,title,state,url,isCrossRepository"], timeout: 35) else {
            throw EngineError.invalid("GitHub took too long to respond. Try again.")
        }
        if result.status != 0 {
            let detail = result.errors.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first
                .map(String.init) ?? "Check the repository name and your GitHub CLI session."
            throw EngineError.invalid("GitHub could not load pull requests. \(detail)")
        }
        guard let list = (try? JSON.parse(result.output))?.arrayValue else {
            throw EngineError.invalid("GitHub CLI returned an unreadable result")
        }
        return list
    }

    static func pullRequestRows(project: String, repo: String) throws -> [[SQLBindable]] {
        try fetchPullRequests(repo).compactMap { item -> [SQLBindable]? in
            guard let number = item["number"].intValue, let link = item["url"].stringValue,
                  let url = URLComponents(string: link) else { return nil }
            if item["isCrossRepository"].boolValue == true || url.scheme != "https" || url.percentEncodedHost != "github.com"
                || url.port != nil || url.user != nil {
                return nil
            }
            guard url.percentEncodedPath.lowercased() == "/\(repo)/pull/\(number)".lowercased() else { return nil }
            return [project, number, item["headRefName"].stringValue ?? "", item["title"].stringValue ?? "",
                    item["state"].stringValue ?? "", link]
        }
    }

    /// Loads a project's pull requests with `gh` and stores them, linking `repository` first when given.
    static func refresh(_ db: Database, project: String, repository: String?) throws -> JSON {
        try Store.project(db, project)
        let previous = try db.first("SELECT repo FROM github_projects WHERE project = ?", [project])?["repo"].string
        if repository == nil, previous == nil { throw EngineError.invalid("Set a GitHub repository for this project first") }
        let repo = try repository.map(Store.normalizeRepo) ?? previous!
        let rows = try pullRequestRows(project: project, repo: repo)
        try db.beginImmediate()
        let current = try db.first("SELECT repo FROM github_projects WHERE project = ?", [project])?["repo"].string
        if current != previous { throw EngineError.conflict("The repository changed while syncing. Reload it and try again.") }
        if repository != nil { try Store.setRepo(db, project: project, repo: repo) }
        try db.execute("DELETE FROM github_prs WHERE project = ?", [project])
        for row in rows { try db.execute("INSERT INTO github_prs VALUES (?, ?, ?, ?, ?, ?)", row) }
        try db.execute("UPDATE github_projects SET refreshed_at = ? WHERE project = ?", [Values.nowMillis(), project])
        return .object([("repo", .string(repo)), ("pull_requests", .int(Int64(rows.count)))])
    }
}

/// A flag set once from another thread.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
