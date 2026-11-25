import CryptoKit
import Foundation

/// Ledger reads and writes shared by every operation (Python's `tracker/store.py`).
enum Store {
    // MARK: Settings

    static func setting(_ db: Database, _ key: String) throws -> String? {
        try db.first("SELECT value FROM settings WHERE key = ?", [key])?[0].string
    }

    static func setting(_ db: Database, _ key: String, _ fallback: String) throws -> String {
        try setting(db, key) ?? fallback
    }

    static func setSetting(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", [key, value])
    }

    static func currency(_ db: Database) throws -> String { try setting(db, "currency", "EUR") }
    static func timezoneName(_ db: Database) throws -> String { try setting(db, "timezone", "UTC") }
    static func timezone(_ db: Database) throws -> TimeZone { try Values.zone(timezoneName(db)) }

    /// The client that stands for your own internal and personal work, so every project has a client.
    static func selfClient(_ db: Database) throws -> String {
        try setting(db, "self_client", Schema.selfClientDefault)
    }

    // MARK: Projects and clients

    @discardableResult
    static func project(_ db: Database, _ name: String) throws -> Row {
        guard let row = try db.first("SELECT * FROM projects WHERE name = ?", [name]) else {
            throw EngineError.notFound("Unknown project: \(name)")
        }
        return row
    }

    static func createProject(_ db: Database, name: String, client: String?, kind: String, folder: String?) throws {
        let name = try Values.required(name, "Project")
        guard ["billable", "internal", "personal"].contains(kind) else {
            throw EngineError.invalid("Kind must be billable, internal or personal")
        }
        var owner = client
        if owner == nil || owner!.pythonStripped.isEmpty {
            if kind == "billable" { throw EngineError.invalid("Billable projects need a client") }
            owner = try selfClient(db)
        }
        let clientName = try Values.required(owner, "Client")
        try db.execute("INSERT OR IGNORE INTO clients SELECT client FROM projects WHERE name = ? AND client IS NOT NULL", [name])
        try db.execute("INSERT OR IGNORE INTO clients VALUES (?)", [clientName])
        try db.execute("INSERT INTO projects VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET "
                       + "client=excluded.client, kind=excluded.kind", [name, clientName, kind])
        if let folder, !folder.isEmpty { try mapFolder(db, project: name, folder: folder) }
    }

    static func clientList(_ db: Database) throws -> [String] {
        try db.query("SELECT name FROM (SELECT name FROM clients UNION SELECT client FROM projects WHERE client IS NOT NULL) "
                     + "ORDER BY name COLLATE NOCASE, name").compactMap { $0["name"].string }
    }

    static func saveClient(_ db: Database, name: String, previous: String?) throws {
        let name = try Values.required(name, "Client name")
        try db.beginImmediate()
        let existing = try clientList(db)
        if let previous, !existing.contains(previous) {
            throw EngineError.conflict("This client changed since it was loaded. Reload and try again.")
        }
        if name != previous, existing.contains(name) {
            throw EngineError.conflict("A client with this name already exists")
        }
        try db.execute("INSERT OR IGNORE INTO clients VALUES (?)", [name])
        if let previous, name != previous {
            try db.execute("UPDATE projects SET client = ? WHERE client = ?", [name, previous])
            try db.execute("UPDATE chrome_profile_clients SET client = ? WHERE client = ?", [name, previous])
            try db.execute("UPDATE focus_clients SET client = ? WHERE client = ?", [name, previous])
            try db.execute("DELETE FROM clients WHERE name = ?", [previous])
            try db.execute("UPDATE billing_terms SET name = ? WHERE scope = 'client' AND name = ?", [name, previous])
            try db.execute("UPDATE appearance SET name = ? WHERE scope = 'client' AND name = ?", [name, previous])
            if previous == (try selfClient(db)) { try setSetting(db, "self_client", name) }
        }
    }

    static func mapFolder(_ db: Database, project: String, folder: String) throws {
        try self.project(db, project)
        try db.execute("INSERT OR REPLACE INTO folders VALUES (?, ?)", [try Values.folderPath(folder), project])
    }

    static func unmapFolder(_ db: Database, project: String, folder: String) throws {
        let changed = try db.execute("DELETE FROM folders WHERE path = ? AND project = ?", [try Values.folderPath(folder), project])
        if changed == 0 { throw EngineError.notFound("This folder is not mapped to the project") }
    }

    /// Every project with its folders and GitHub link, like `store.project_list`.
    static func projectList(_ db: Database) throws -> JSON {
        var order: [String] = []
        var projects: [String: JSON] = [:]
        for row in try db.query("SELECT * FROM projects ORDER BY name") {
            guard let name = row["name"].string else { continue }
            var object = row.object
            object.set("folders", .array([]))
            order.append(name)
            projects[name] = object
        }
        for row in try db.query("SELECT * FROM folders ORDER BY path") {
            guard let name = row["project"].string, var object = projects[name] else { continue }
            object.set("folders", .array((object["folders"].arrayValue ?? []) + [row["path"].json]))
            projects[name] = object
        }
        let links = try db.query(
            "SELECT link.project, link.repo, link.refreshed_at, route.number FROM github_projects AS link "
            + "LEFT JOIN github_pr_routes AS route ON route.project = link.project "
            + "AND route.repo = link.repo ORDER BY link.project, route.number")
        for row in links {
            guard let name = row["project"].string, var object = projects[name] else { continue }
            object.set("github_repo", row["repo"].json)
            object.set("github_refreshed_at", row["refreshed_at"].json)
            var routes = object["github_routed_prs"].arrayValue ?? []
            if !row["number"].isNull { routes.append(row["number"].json) }
            object.set("github_routed_prs", .array(routes))
            projects[name] = object
        }
        return .array(order.compactMap { projects[$0] })
    }

    // MARK: GitHub links (the database side; network calls live with the GitHub port)

    static func normalizeRepo(_ value: String) throws -> String {
        var repo = value.pythonStripped
        if repo.lowercased().hasPrefix("https://github.com/") { repo = String(repo.dropFirst("https://github.com/".count)) }
        return try GitHub.repoName(repo)
    }

    @discardableResult
    static func setRepo(_ db: Database, project: String, repo value: String) throws -> String {
        try db.beginImmediate()
        try self.project(db, project)
        let repo = try normalizeRepo(value)
        if let existing = try db.first("SELECT repo FROM github_projects WHERE project = ?", [project])?["repo"].string,
           existing.lowercased() == repo.lowercased() {
            return repo
        }
        try db.execute("DELETE FROM settings WHERE key = ?", [GitHub.autoLinkOffKey(project)])
        try clearPullRequests(db, project: project)
        try db.execute("INSERT INTO github_projects (project, repo) VALUES (?, ?) ON CONFLICT(project) "
                       + "DO UPDATE SET repo = excluded.repo, refreshed_at = NULL", [project, repo])
        return repo
    }

    static func clearPullRequests(_ db: Database, project: String) throws {
        try db.execute("DELETE FROM github_pr_routes WHERE project = ?", [project])
        try db.execute("DELETE FROM github_prs WHERE project = ?", [project])
    }

    // MARK: Appearance

    static let iconLimit = 1024 * 1024

    /// Sets a project's colour or a client's icon. nil leaves a field as is; an empty string clears it.
    /// The icon is copied into the ledger's own folder, named by its content, so the original file can move.
    static func setAppearance(_ db: Database, scope: String, name: String, iconsFolder: String,
                              color: String?, icon: String?) throws {
        if scope == "project" {
            try project(db, name)
            if icon != nil { throw EngineError.invalid("Icons belong to clients") }
        } else if !(try clientList(db)).contains(name) {
            throw EngineError.notFound("Unknown client: \(name)")
        }
        let row = try db.first("SELECT color, icon FROM appearance WHERE scope = ? AND name = ?", [scope, name])
        var currentColor = row?["color"].string
        var currentIcon = row?["icon"].string
        if let color {
            let value = color.pythonStripped
            if !value.isEmpty, value.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil {
                throw EngineError.invalid("Use a colour like #3478F6")
            }
            currentColor = value.isEmpty ? nil : value.uppercased()
        }
        if let icon {
            if icon.pythonStripped.isEmpty {
                currentIcon = nil
            } else {
                let source = Values.resolvedPath(icon)
                guard let handle = FileHandle(forReadingAtPath: source) else {
                    throw EngineError.invalid("[Errno 2] No such file or directory: '\(icon)'")
                }
                let data = try handle.read(upToCount: iconLimit + 1) ?? Data()
                try? handle.close()
                if data.count > iconLimit { throw EngineError.invalid("Use an icon image under 1 MB") }
                let suffix: String
                if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                    suffix = ".png"
                } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
                    suffix = ".jpg"
                } else {
                    throw EngineError.invalid("Use a PNG or JPEG image for the icon")
                }
                try FileManager.default.createDirectory(atPath: iconsFolder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let target = iconsFolder + "/" + digest.prefix(20) + suffix
                try data.write(to: URL(fileURLWithPath: target))
                currentIcon = target
            }
        }
        if currentColor == nil, currentIcon == nil {
            try db.execute("DELETE FROM appearance WHERE scope = ? AND name = ?", [scope, name])
        } else {
            try db.execute("INSERT OR REPLACE INTO appearance VALUES (?, ?, ?, ?)", [scope, name, currentColor, currentIcon])
        }
    }

    static func appearanceList(_ db: Database) throws -> JSON {
        .array(try db.query("SELECT * FROM appearance ORDER BY scope, name").map(\.object))
    }

    // MARK: Prices and plans

    static func setModelRate(_ db: Database, provider: String, model: String, rates: [String]) throws {
        let model = try Values.required(model, "Model")
        let cents = try rates.map(Values.cents)
        try db.execute("INSERT OR REPLACE INTO model_rates VALUES (?, ?, ?, ?, ?, ?)",
                       [provider, model, cents[0], cents[1], cents[2], cents[3]])
    }

    static func subscriptions(_ db: Database) throws -> JSON {
        var total = 0
        let plans: [JSON] = try db.query("SELECT * FROM subscriptions ORDER BY name COLLATE NOCASE, name").map { row in
            let cents = row["monthly_cents"].int ?? 0
            total += cents
            return .object([("name", row["name"].json), ("monthly", .string(Values.money(cents))),
                            ("provider", row["provider"].json)])
        }
        return .object([("plans", .array(plans)), ("monthly_total", .string(Values.money(total)))])
    }

    static func setSubscription(_ db: Database, name: String, monthly: String?, provider: String?, newOnly: Bool) throws {
        let name = try Values.required(name, "Plan name")
        guard let monthly else {
            try db.execute("DELETE FROM subscriptions WHERE name = ?", [name])
            return
        }
        let amount = try Values.cents(monthly)
        if newOnly {
            try db.beginImmediate()
            if try db.first("SELECT 1 FROM subscriptions WHERE name = ?", [name]) != nil {
                throw EngineError.conflict("A subscription with this name already exists")
            }
        }
        if let provider {
            let value: String? = provider.pythonStripped.isEmpty ? nil : try Values.required(provider, "Provider")
            try db.execute("INSERT OR REPLACE INTO subscriptions (name, monthly_cents, provider) VALUES (?, ?, ?)",
                           [name, amount, value])
        } else {
            try db.execute("INSERT INTO subscriptions (name, monthly_cents) VALUES (?, ?) "
                           + "ON CONFLICT(name) DO UPDATE SET monthly_cents = excluded.monthly_cents", [name, amount])
        }
    }

    // MARK: Entries

    /// Inserts an entry; with `refresh`, an existing entry takes the new values but keeps its project.
    static func addEntry(_ db: Database, _ entry: [String: SQLValue], refresh: Bool = false) throws {
        let zeroes: Set<String> = ["millis", "input", "cached", "cache_write", "output", "reimbursable",
                                   "cache_write_1h", "reasoning", "web_searches", "replica"]
        let values: [SQLBindable] = Schema.entryFields.map { field -> SQLBindable in
            let value: SQLValue = entry[field] ?? (zeroes.contains(field) ? .integer(0) : .null)
            return value
        }
        let columns = Schema.entryFields.joined(separator: ", ")
        let placeholders = Schema.entryFields.map { _ in "?" }.joined(separator: ", ")
        let conflict: String
        if refresh {
            let updates = Schema.entryFields.filter { $0 != "id" && $0 != "project" }
                .map { "\($0)=excluded.\($0)" }.joined(separator: ", ")
            conflict = "DO UPDATE SET \(updates)"
        } else {
            conflict = "DO NOTHING"
        }
        try db.execute("INSERT INTO entries (\(columns)) VALUES (\(placeholders)) ON CONFLICT(id) \(conflict)", values)
    }

    static func assign(_ db: Database, entryID: String, project: String?) throws {
        if let project { try self.project(db, project) }
        let id = try Values.required(entryID, "Entry ID")
        let changed = try db.execute("UPDATE entries SET project = ? WHERE id = ? AND provider IS NOT NULL", [project, id])
        if changed == 0 { throw EngineError.notFound("Unknown imported entry: \(id)") }
    }

    static func removeManual(_ db: Database, entryID: String) throws {
        let changed = try db.execute("DELETE FROM entries WHERE id = ? AND kind IN ('human', 'expense')", [entryID])
        if changed == 0 { throw EngineError.notFound("No manual entry with that ID") }
    }

    /// A Jira-style key when the branch names exactly one ("feature/ABC-12-login" → "ABC-12").
    static func taskFromBranch(_ branch: String?) -> String? {
        guard let branch, !branch.isEmpty else { return nil }
        let upper = branch.uppercased()
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Z0-9])[A-Z][A-Z0-9]{1,15}-[0-9]+(?![0-9])"#)
        let keys = Set(pattern.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)).compactMap {
            Range($0.range, in: upper).map { String(upper[$0]) }
        })
        return keys.count == 1 ? keys.first : nil
    }

    /// A harness id such as `opencode` or `my-agent` (Python's `importers.harness_id`).
    static func harnessID(_ value: String) throws -> String {
        let value = try Values.required(value, "Harness")
        guard value.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
            throw EngineError.invalid("Use a harness ID such as opencode or my-agent")
        }
        return value
    }
}
