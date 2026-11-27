import Foundation

/// Foreground app time: recording, rules and the timeline (Python's `tracker/focus.py`).
enum Focus {
    static let rulesChanged = Notification.Name("com.domenicodidonna.tracker.rules-changed")

    /// A UUID in canonical lower-case form, accepting what Python's `uuid.UUID(text)` accepts.
    static func canonicalUUID(_ text: String) throws -> String {
        var hex = text.replacingOccurrences(of: "urn:", with: "").replacingOccurrences(of: "uuid:", with: "")
        hex = String(hex.drop { $0 == "{" || $0 == "}" }.reversed().drop { $0 == "{" || $0 == "}" }.reversed())
        hex = hex.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit), hex.allSatisfy(\.isASCII) else {
            throw EngineError.invalid("badly formed hexadecimal UUID string")
        }
        let lower = Array(hex.lowercased())
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(lower[$0]) }.joined(separator: "-")
    }

    static let maxStamp = 253_402_300_799_999

    /// Stores activity blocks from the recorder. Open blocks keep growing with their original classification.
    static func record(_ db: Database, _ blocks: JSON) throws {
        guard let list = blocks.arrayValue, list.count <= 1000 else {
            throw EngineError.invalid("Expected up to 1,000 activity blocks")
        }
        for block in list {
            guard block.pairs != nil else { throw EngineError.invalid("Invalid activity block") }
            let key = try canonicalUUID(try Values.required(block["id"].stringValue, "Block ID"))
            let appID = try Values.required(block["app_id"].stringValue, "App identifier")
            let appName = try Values.required(block["app_name"].stringValue, "App name")
            guard case let .int(start64) = block["started_at"], case let .int(end64) = block["ended_at"],
                  case let .bool(closed) = block["closed"] else {
                throw EngineError.invalid("Invalid activity interval")
            }
            let start = Int(start64), end = Int(end64)
            guard 0 <= start, start < end, end <= maxStamp, end - start <= 7 * 86_400_000 else {
                throw EngineError.invalid("Invalid activity interval")
            }
            var repo: String?
            var number: Int?
            let ignored = try Params(block).bool("ignored")
            let client = ignored ? .null : block["client"]
            guard client.isNull || client.stringValue != nil else { throw EngineError.invalid("client must be a string") }
            let context = ignored ? .null : block["github"]
            if !context.isNull {
                guard context.pairs != nil else { throw EngineError.invalid("Invalid GitHub activity context") }
                repo = try GitHub.repoName(try Values.required(context["repo"].stringValue, "GitHub repository"))
                if !context["number"].isNull {
                    guard case let .int(value) = context["number"], value > 0, value <= 2_147_483_647 else {
                        throw EngineError.invalid("Invalid GitHub pull request number")
                    }
                    number = Int(value)
                }
            }
            var project: String?
            var details: [SQLBindable]?
            let match = ignored ? .null : block["match"]
            if !match.isNull {
                guard match.pairs != nil else { throw EngineError.invalid("Invalid rule match") }
                project = try Values.required(match["project"].stringValue, "Project")
                if match["field"].stringValue == "github", let repo {
                    details = [key, "github", number.map { "\(repo)#\($0)" } ?? repo, SQLValue.null]
                } else {
                    let rule = try ruleValues(field: match["field"], keyword: match["keyword"], appScope: .null, tag: match["tag"])
                    details = [key, rule.field, rule.keyword, rule.tag]
                }
            }
            let changed = try db.execute(
                "INSERT INTO focus_blocks (id, app_id, app_name, started_at, ended_at, closed, project, ignored) "
                + "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                + "ended_at = max(focus_blocks.ended_at, excluded.ended_at), closed = excluded.closed "
                + "WHERE focus_blocks.closed = 0 AND focus_blocks.ignored = excluded.ignored "
                + "AND focus_blocks.started_at = excluded.started_at AND focus_blocks.app_id = excluded.app_id "
                + "AND focus_blocks.project IS excluded.project",
                [key, appID, appName, start, end, closed ? 1 : 0, project, ignored ? 1 : 0])
            if changed > 0, let details {
                try db.execute("INSERT OR IGNORE INTO focus_matches VALUES (?, ?, ?, ?)", details)
            }
            if changed > 0, let repo {
                try db.execute("INSERT OR IGNORE INTO focus_github VALUES (?, ?, ?)", [key, repo, number])
            }
            if changed > 0, let client = client.stringValue {
                try db.execute("INSERT OR IGNORE INTO focus_clients SELECT ?, name FROM clients WHERE name = ?", [key, client])
            }
            if changed > 0, !ignored, !block["details"].isNull, try keepsDetails(db) {
                try storeDetails(db, block: key, block["details"])
            }
        }
    }

    // MARK: Window titles and page addresses (opt-in)

    static let detailsSetting = "keep_activity_details"
    static let maxDetails = 20

    static func keepsDetails(_ db: Database) throws -> Bool {
        try Store.setting(db, detailsSetting, "0") == "1"
    }

    /// Turning the setting off stops new titles; what was kept stays until it is deleted on purpose.
    static func setKeepDetails(_ db: Database, _ enabled: Bool) throws {
        try Store.setSetting(db, detailsSetting, enabled ? "1" : "0")
    }

    /// Deletes kept titles and addresses: all of them, those of some blocks, or those of blocks in a time range.
    @discardableResult
    static func deleteDetails(_ db: Database, all: Bool, blocks: [String]?, since: Int?, until: Int?) throws -> Int {
        if all {
            guard blocks == nil, since == nil else { throw EngineError.invalid("Choose all, some blocks, or a period") }
            return try db.execute("DELETE FROM focus_details")
        }
        if let blocks {
            guard !blocks.isEmpty, blocks.count <= 1000, since == nil else {
                throw EngineError.invalid("Give between 1 and 1,000 block IDs, without a period")
            }
            var deleted = 0
            for id in blocks { deleted += try db.execute("DELETE FROM focus_details WHERE block_id = ?", [id]) }
            return deleted
        }
        guard let since, let until else { throw EngineError.invalid("Choose all, some blocks, or a period") }
        return try db.execute("DELETE FROM focus_details WHERE block_id IN "
                              + "(SELECT id FROM focus_blocks WHERE ended_at > ? AND started_at < ?)", [since, until])
    }

    /// The titles and addresses seen during a block, with the time on each. The recorder sends the whole set
    /// with every checkpoint, so it replaces what was stored. Queries and fragments never reach the ledger.
    static func storeDetails(_ db: Database, block: String, _ details: JSON) throws {
        guard let list = details.arrayValue, list.count <= maxDetails else {
            throw EngineError.invalid("Expected up to \(maxDetails) activity details")
        }
        var rows: [String: (title: String, address: String, millis: Int)] = [:]
        for item in list {
            guard item.pairs != nil, case let .int(millis) = item["millis"], millis >= 0 else {
                throw EngineError.invalid("Invalid activity detail")
            }
            let title = String((item["title"].stringValue ?? "").pythonStripped.prefix(300))
            var address = item["address"].stringValue ?? ""
            address = String(address.prefix { $0 != "?" && $0 != "#" }.prefix(512))
            if !address.isEmpty, !(address.hasPrefix("https://") || address.hasPrefix("http://")) { address = "" }
            guard !title.isEmpty || !address.isEmpty else { continue }
            let key = title + "\u{1F}" + address
            rows[key] = (title, address, (rows[key]?.millis ?? 0) + Int(millis))
        }
        try db.execute("DELETE FROM focus_details WHERE block_id = ?", [block])
        for row in rows.values {
            try db.execute("INSERT INTO focus_details VALUES (?, ?, ?, ?)", [block, row.title, row.address, row.millis])
        }
    }

    /// The titles and sites that took the most time in a set of blocks, for review.
    static func topDetails(_ db: Database, where condition: String, _ parameters: [SQLBindable], limit: Int = 5) throws -> (titles: JSON, sites: JSON) {
        let titles = try db.query(
            "SELECT title, sum(millis) AS millis FROM focus_details JOIN focus_blocks ON focus_blocks.id = focus_details.block_id "
            + "WHERE title != '' AND \(condition) GROUP BY title ORDER BY millis DESC, title LIMIT ?", parameters + [limit])
        let sites = try db.query(
            "SELECT address, sum(millis) AS millis FROM focus_details JOIN focus_blocks ON focus_blocks.id = focus_details.block_id "
            + "WHERE address != '' AND \(condition) GROUP BY address ORDER BY millis DESC, address LIMIT ?", parameters + [limit])
        return (.array(titles.map { .object([("title", $0["title"].json), ("millis", $0["millis"].json)]) }),
                .array(sites.map { .object([("address", $0["address"].json), ("millis", $0["millis"].json)]) }))
    }

    static func config(_ db: Database) throws -> JSON {
        let rules = try db.query("SELECT * FROM focus_rules ORDER BY field, keyword COLLATE NOCASE, id").map(ruleObject)
        let chromeClients = try db.query("SELECT profile_id, client FROM chrome_profile_clients ORDER BY profile_id")
            .compactMap { row in row["profile_id"].string.map { ($0, row["client"].json) } }
        let slackClients = try db.query("SELECT * FROM slack_workspace_clients ORDER BY coalesce(desktop_name, workspace_id) COLLATE NOCASE, id")
        return .object([("enabled", .bool(try Store.setting(db, "focus_enabled", "0") == "1")),
                        ("rules", .array(rules)), ("auto_rules", .array(try autoRules(db))),
                        ("auto_rules_off", JSON.strings(pythonSorted(try autoRulesOff(db)))),
                        ("github_routes", try GitHub.routesJSON(db)), ("chrome_profile_clients", .object(chromeClients)),
                        ("slack_workspace_clients", .array(slackClients.map(\.object))),
                        ("keep_details", .bool(try keepsDetails(db)))])
    }

    static func setChromeProfileClient(_ db: Database, profileID: String, client: String?) throws {
        guard ChromeProfile.validID(profileID) else { throw EngineError.invalid("Choose an ID from the Chrome profiles list") }
        guard let client else {
            try db.execute("DELETE FROM chrome_profile_clients WHERE profile_id = ?", [profileID])
            return
        }
        guard try Store.clientList(db).contains(client) else { throw EngineError.notFound("Unknown client: \(client)") }
        // A legacy project can supply a client before it has an entry in the client catalog.
        try db.execute("INSERT OR IGNORE INTO clients VALUES (?)", [client])
        try db.execute("INSERT INTO chrome_profile_clients VALUES (?, ?) ON CONFLICT(profile_id) DO UPDATE SET client = excluded.client",
                       [profileID, client])
    }

    static func setSlackWorkspaceClient(_ db: Database, id: String?, workspace: String?, desktopName: String?, client: String?) throws {
        let id = try id.map(canonicalUUID)
        if let id, try db.first("SELECT 1 FROM slack_workspace_clients WHERE id = ?", [id]) == nil {
            throw EngineError.notFound("This Slack workspace mapping no longer exists")
        }
        guard let client else {
            guard let id else { throw EngineError.invalid("Choose a Slack workspace mapping to clear") }
            try db.execute("DELETE FROM slack_workspace_clients WHERE id = ?", [id])
            return
        }

        let workspaceID = workspace.flatMap(SlackTrackingContext.workspaceID(fromInput:))
        let name = desktopName.flatMap(SlackTrackingContext.workspaceName)
        if workspace != nil && workspaceID == nil { throw EngineError.invalid("Enter a Slack workspace ID or browser URL") }
        if desktopName != nil && name == nil { throw EngineError.invalid("Use a Slack desktop workspace name of up to 150 characters") }
        guard workspaceID != nil || name != nil else { throw EngineError.invalid("Enter a Slack workspace ID or desktop name") }
        guard try Store.clientList(db).contains(client) else { throw EngineError.notFound("Unknown client: \(client)") }

        let mappings = try db.query("SELECT id, workspace_id, desktop_name FROM slack_workspace_clients")
        if mappings.contains(where: { row in
            row["id"].string != id && (
                workspaceID.map { row["workspace_id"].string == $0 } == true
                    || name.map { row["desktop_name"].string?.caseInsensitiveCompare($0) == .orderedSame } == true
            )
        }) {
            throw EngineError.conflict("This Slack workspace is already mapped. Edit its existing mapping.")
        }
        try db.execute("INSERT OR IGNORE INTO clients VALUES (?)", [client])
        try db.execute("INSERT INTO slack_workspace_clients (id, workspace_id, desktop_name, client) VALUES (?, ?, ?, ?) "
                       + "ON CONFLICT(id) DO UPDATE SET workspace_id = excluded.workspace_id, "
                       + "desktop_name = excluded.desktop_name, client = excluded.client",
                       [id ?? UUID().uuidString.lowercased(), workspaceID, name, client])
    }

    static let autoMinLength = 3
    /// The limit `ruleValues` accepts for window keywords.
    static let autoMaxLength = 150

    /// Python's `sorted()` for strings: by code point.
    private static func pythonSorted<S: Sequence>(_ values: S) -> [String] where S.Element == String {
        values.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    static func autoRulesOff(_ db: Database) throws -> Set<String> {
        guard let list = (try? JSON.parse(try Store.setting(db, "auto_rules_off", "[]")))?.arrayValue else { return [] }
        return Set(list.compactMap(\.stringValue))
    }

    static func setAutoRules(_ db: Database, project: String, enabled: Bool) throws {
        guard try !db.query("SELECT 1 FROM projects WHERE name = ?", [project]).isEmpty else {
            throw EngineError.invalid("Unknown project: \(project)")
        }
        var names = try autoRulesOff(db)
        if enabled { names.remove(project) } else { names.insert(project) }
        try Store.setSetting(db, "auto_rules_off", JSON.strings(pythonSorted(names)).pythonText(indent: nil, ensureASCII: true))
    }

    /// Window-title rules Tracker makes by itself: a project's name routes to that project, and a client's
    /// name routes to its project when the client has only one. Names shared by several projects are left out.
    static func autoRules(_ db: Database) throws -> [JSON] {
        let projects = try db.query("SELECT name, client FROM projects ORDER BY name COLLATE NOCASE")
        let off = try autoRulesOff(db)
        let me = try Store.selfClient(db).pythonStripped.lowercased()
        var byClient: [String: [String]] = [:]
        var clientOrder: [String] = []
        for row in projects {
            guard let client = row["client"].string, !client.isEmpty, let name = row["name"].string else { continue }
            if byClient[client] == nil { clientOrder.append(client) }
            byClient[client, default: []].append(name)
        }
        struct Target: Hashable { let keyword: String; let project: String; let source: String }
        var candidates: [String: Set<Target>] = [:]
        for row in projects {
            guard let name = row["name"].string else { continue }
            candidates[name.pythonStripped.lowercased(), default: []].insert(Target(keyword: name, project: name, source: "project"))
        }
        for client in clientOrder {
            let names = byClient[client] ?? []
            let key = client.pythonStripped.lowercased()
            if names.count == 1 && key != me {
                candidates[key, default: []].insert(Target(keyword: client.pythonStripped, project: names[0], source: "client"))
            }
        }
        var result: [JSON] = []
        for key in pythonSorted(candidates.keys) {
            let targets = candidates[key] ?? []
            let length = key.unicodeScalars.count
            guard (autoMinLength...autoMaxLength).contains(length), Set(targets.map(\.project)).count == 1,
                  let target = targets.first(where: { $0.source == "project" }) ?? targets.first,
                  !off.contains(target.project) else { continue }
            result.append(.object([
                ("id", .string("auto:\(target.source):\(target.keyword)")), ("field", .string("window")),
                ("keyword", .string(target.keyword)), ("app_scope", .null), ("tag", .null),
                ("project", .string(target.project)), ("chrome_profile", .null), ("automatic", .string(target.source)),
            ]))
        }
        return result
    }

    struct Rule { let field: String; let keyword: String; let appScope: String?; let tag: String? }

    static func websiteCondition(_ text: String) -> (field: String, keyword: String) {
        let address = String(text.prefix { $0 != "?" && $0 != "#" })
        if address.contains("://") { return ("url", address) }
        if address.contains("/") || address.contains(":") { return ("url", "https://" + address) }
        return ("domain", address)
    }

    static func ruleValues(field: JSON, keyword: JSON, appScope: JSON, tag: JSON) throws -> Rule {
        guard let field = field.stringValue, ["app", "window", "domain", "url"].contains(field) else {
            throw EngineError.invalid("Choose an app, window, domain, or URL rule")
        }
        var keyword = try Values.required(keyword.stringValue, "Keyword")
        if (!appScope.isNull && appScope.stringValue == nil) || (!tag.isNull && tag.stringValue == nil) {
            throw EngineError.invalid("App scope and tag must be strings")
        }
        let scope = (appScope.stringValue ?? "").pythonStripped
        let label = (tag.stringValue ?? "").pythonStripped
        if keyword.count > (field == "url" ? 512 : 150) || scope.count > 150 || label.count > 150 {
            throw EngineError.invalid("Use up to 512 characters for a URL and 150 for other rule fields")
        }
        if field == "domain" || field == "url" { keyword = try browserRule(field, keyword) }
        return Rule(field: field, keyword: keyword, appScope: field == "app" || scope.isEmpty ? nil : scope,
                    tag: label.isEmpty ? nil : label)
    }

    /// A domain ("app.example.com") or an HTTP(S) URL without query or fragment, normalised the way
    /// Python's `urllib.parse.urlsplit` and the IDNA codec read it.
    static func browserRule(_ field: String, _ keyword: String) throws -> String {
        // An address typed without a scheme ("github.com/org") is an HTTPS URL, as the rule editor reads it.
        let keyword = field == "url" && !keyword.contains("://") ? "https://" + keyword : keyword
        if keyword.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 32 || (0x1C...0x1F).contains($0.value) }) {
            throw EngineError.invalid("A domain or URL cannot contain whitespace")
        }
        if keyword.contains("#") || keyword.contains("?") {
            throw EngineError.invalid("Use a domain or URL path without query strings or fragments")
        }
        let address = URLParts(field == "domain" ? "//" + keyword : keyword)
        let invalid = EngineError.invalid("Enter a valid domain or HTTP(S) URL")
        guard address.validBrackets else { throw invalid }
        var host = address.hostname ?? ""
        while host.hasSuffix(".") { host.removeLast() }
        guard let ascii = IDNA.toASCII(host) else { throw invalid }
        host = ascii.lowercased()
        let port: Int?
        switch address.port {
        case nil: port = nil
        case let .some(text):
            guard let value = Int(text), !text.isEmpty, (0...65535).contains(value) else { throw invalid }
            port = value
        }
        let label = try! NSRegularExpression(pattern: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
        let labelsOK = host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            let text = String(part)
            return label.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if host.isEmpty || !labelsOK || address.hasUser {
            throw EngineError.invalid("Enter a valid hostname without credentials")
        }
        if field == "domain" {
            if !address.path.isEmpty || port != nil || address.netloc.contains(":") {
                throw EngineError.invalid("Use only the domain, for example app.example.com")
            }
            return host
        }
        let scheme = address.scheme.lowercased()
        guard scheme == "http" || scheme == "https" else { throw EngineError.invalid("Start the URL with https:// or http://") }
        let defaultPort = scheme == "https" ? 443 : 80
        let origin = port.map { $0 != defaultPort ? "\(host):\($0)" : host } ?? host
        var path = address.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        if !path.hasPrefix("/") { path = "/" + path }
        return "\(scheme)://\(origin)\(path)"
    }

    static func ruleObject(_ row: Row) -> JSON {
        var result = row.object
        if row["project"].string == nil { result.set("ignore", .bool(true)) }
        if let profileID = ChromeProfile.id(fromStored: row["chrome_profile"].string) {
            result.set("chrome_profile", .null)
            result.set("chrome_profile_id", .string(profileID))
        }
        return result
    }

    @discardableResult
    static func saveRule(_ db: Database, project: String?, field: JSON, keyword: JSON, appScope: JSON, tag: JSON,
                         id: String?, chromeProfile: String?, chromeProfileID: String? = nil,
                         appID: String? = nil) throws -> (id: String, created: Bool) {
        if let project { try Store.project(db, project) }
        let rule = try ruleValues(field: field, keyword: keyword, appScope: appScope, tag: project == nil ? .null : tag)
        let appID = try appID.map { try Values.required($0, "App identifier") }
        if let appID {
            guard ["app", "window"].contains(rule.field), appID.unicodeScalars.count <= 512 else {
                throw EngineError.invalid("Use an app or window rule with a valid app identifier")
            }
        }
        let alias = (chromeProfile?.pythonStripped).nonEmpty
        let profileID = (chromeProfileID?.pythonStripped).nonEmpty
        if alias != nil || profileID != nil {
            guard rule.field == "domain" || rule.field == "url" else {
                throw EngineError.invalid("Choose a domain or URL rule to use a Chrome profile")
            }
        }
        let profile: String?
        if let profileID {
            guard alias == nil else { throw EngineError.invalid("Choose a Chrome profile or an extension label") }
            guard ChromeProfile.validID(profileID) else {
                throw EngineError.invalid("Choose an ID from the Chrome profiles list")
            }
            profile = ChromeProfile.storedID(profileID)
        } else if let alias {
            guard fullMatch("[A-Za-z0-9 _-]{1,40}", alias) else {
                throw EngineError.invalid("Use up to 40 letters, numbers, spaces, hyphens, or underscores for the Chrome profile")
            }
            profile = alias
        } else {
            profile = nil
        }
        if let id, try db.first("SELECT 1 FROM focus_rules WHERE id = ?", [id]) == nil {
            throw EngineError.notFound("This rule no longer exists")
        }
        let matches = try db.query("SELECT * FROM focus_rules WHERE field = ? ORDER BY id", [rule.field]).filter { row in
            guard row["id"].string != id else { return false }
            let keyword = row["keyword"].string ?? ""
            let sameTarget: Bool
            if let appID {
                sameTarget = row["app_id"].string == appID
                    && (rule.field != "window" || sameRuleText(keyword, rule.keyword))
            } else if rule.field == "app" || rule.field == "window" {
                sameTarget = row["app_id"].string == nil && sameRuleText(keyword, rule.keyword)
            } else {
                sameTarget = keyword == rule.keyword
            }
            return sameTarget && (appID != nil || sameRuleText(row["app_scope"].string, rule.appScope))
                && row["chrome_profile"].string?.lowercased() == profile?.lowercased()
        }
        if let conflict = matches.first(where: { !pyEqual($0["project"].string, project) || !pyEqual($0["tag"].string, rule.tag) }) {
            if let destination = conflict["project"].string {
                let route = [destination, conflict["tag"].string].compactMap { $0 }.joined(separator: " · ")
                throw EngineError.conflict("A rule with these conditions already routes to \(route). Edit it in Timeline → Rules.")
            }
            throw EngineError.conflict("A rule with these conditions already ignores matching time. Edit it in Timeline → Rules.")
        }
        if let existing = matches.first?["id"].string {
            if id == nil { return (existing, false) }
            let duplicate = project.map { "An identical rule already exists for \($0)." } ?? "An identical ignore rule already exists."
            throw EngineError.conflict("\(duplicate) Review it in Timeline → Rules.")
        }
        if let id {
            try db.execute(
                "UPDATE focus_rules SET field = ?, keyword = ?, app_scope = ?, tag = ?, project = ?, chrome_profile = ?, app_id = ? WHERE id = ?",
                [rule.field, rule.keyword, rule.appScope, rule.tag, project, profile, appID, id])
            return (id, false)
        } else {
            let id = UUID().uuidString.lowercased()
            try db.execute("INSERT INTO focus_rules (id, field, keyword, app_scope, tag, project, chrome_profile, app_id) "
                           + "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                           [id, rule.field, rule.keyword, rule.appScope, rule.tag, project, profile, appID])
            return (id, true)
        }
    }

    private static func sameRuleText(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == rhs }
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedSame
    }

    /// Closes blocks left open by a recorder that stopped. The Mac recorder holds a lease while it does this.
    static func closeInterrupted(_ db: Database) throws {
        try db.execute("UPDATE focus_blocks SET closed = 1 WHERE closed = 0")
    }

    static func classify(_ db: Database, id: String, project: String?, ignored: Bool) throws {
        if let project { try Store.project(db, project) }
        let changed = try db.execute("UPDATE focus_blocks SET project = ?, ignored = ? WHERE id = ? AND closed = 1",
                                     [project, ignored ? 1 : 0, id])
        if changed == 0 { throw EngineError.conflict("This activity is still being recorded or no longer exists") }
        try db.execute("DELETE FROM focus_matches WHERE block_id = ?", [id])
    }

    // MARK: Timeline

    static func togglIntervals(_ db: Database, start: Int, end: Int) throws -> [Row] {
        try db.query("SELECT 'toggl:' || account || ':' || id AS id, project, "
                     + "max(started_at, ?) AS started_at, min(ended_at, ?) AS ended_at "
                     + "FROM toggl_time WHERE ended_at > ? AND started_at < ?", [start, end, start, end])
    }

    static func timelineBlocks(_ db: Database, since: Int, until: Int) throws -> [JSON] {
        let rows = try db.query(
            "SELECT id, app_id, app_name, max(started_at, ?) AS started_at, "
            + "min(ended_at, ?) AS ended_at, closed, project, ignored, keyword, tag, "
            + "CASE WHEN ignored THEN NULL WHEN project IS NOT NULL THEN projects.client ELSE focus_clients.client END AS client, "
            + "focus_github.repo AS github_repo, focus_github.number AS github_pr FROM focus_blocks "
            + "LEFT JOIN focus_matches ON focus_matches.block_id = focus_blocks.id "
            + "LEFT JOIN focus_github ON focus_github.block_id = focus_blocks.id "
            + "LEFT JOIN focus_clients ON focus_clients.block_id = focus_blocks.id "
            + "LEFT JOIN projects ON projects.name = focus_blocks.project "
            + "WHERE ended_at > ? AND started_at < ?", [since, until, since, until])
        var blocks: [JSON] = rows.map { row in
            var block = row.object
            block.set("closed", .bool(row["closed"].int == 1))
            block.set("ignored", .bool(row["ignored"].int == 1))
            block.set("time_source", .string("automatic"))
            return block
        }
        for interval in try togglIntervals(db, start: since, end: until) {
            var block = interval.object
            for (key, value) in [("app_id", JSON.null), ("app_name", .string("Toggl Track")), ("closed", .bool(true)),
                                 ("ignored", .bool(false)), ("keyword", .null), ("tag", .null), ("github_repo", .null),
                                 ("github_pr", .null), ("time_source", .string("toggl"))] {
                block.set(key, value)
            }
            blocks.append(block)
        }
        return sortedNewestFirst(blocks)
    }

    static func sortedNewestFirst(_ blocks: [JSON]) -> [JSON] {
        blocks.sorted {
            let a = $0["started_at"].intValue ?? 0, b = $1["started_at"].intValue ?? 0
            return a != b ? a > b : ($0["id"].stringValue ?? "") < ($1["id"].stringValue ?? "")
        }
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// "YYYY-MM-DD" as a date at local midnight, checked like Python's `date.fromisoformat`.
    static func day(_ text: String, zone: TimeZone) throws -> DateComponents {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            throw EngineError.invalid("Invalid isoformat string: '\(text)'")
        }
        let components = DateComponents(year: year, month: month, day: dayNumber)
        guard components.isValidDate(in: calendar(zone)) else { throw EngineError.invalid("day is out of range for month") }
        return components
    }

    static func today(_ zone: TimeZone) -> DateComponents {
        calendar(zone).dateComponents([.year, .month, .day], from: Date())
    }

    /// Epoch milliseconds of local midnight on a day (shifted forward when midnight doesn't exist).
    static func midnight(_ day: DateComponents, offset: Int = 0, zone: TimeZone) -> Int {
        var components = DateComponents(year: day.year, month: day.month, day: (day.day ?? 1) + offset)
        components.hour = 0
        let date = calendar(zone).date(from: components) ?? Date(timeIntervalSince1970: 0)
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func isoDay(_ day: DateComponents, offset: Int = 0, zone: TimeZone) -> String {
        let cal = calendar(zone)
        let base = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
        let shifted = cal.date(byAdding: .day, value: offset, to: base) ?? base
        let parts = cal.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Monday-based weekday offset (Python's `date.weekday()`).
    static func weekday(_ day: DateComponents, zone: TimeZone) -> Int {
        let cal = calendar(zone)
        let date = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
        return (cal.component(.weekday, from: date) + 5) % 7
    }

    /// The Monday-to-Sunday week containing `day`, with each day's blocks and agent runtime.
    /// Closed app blocks with no project and not ignored, one row per app and fallback client, largest first.
    /// These are what get_status counts as unassigned_blocks; agent work without a project is a separate list.
    static func unassignedActivity(_ db: Database, since: Int, until: Int, bounds: (String, String), limit: Int) throws -> JSON {
        let rows = try db.query(
            "SELECT app_id, app_name, focus_clients.client AS client, count(*) AS blocks, "
            + "sum(min(ended_at, ?) - max(started_at, ?)) AS millis, max(ended_at) AS last_at, "
            + "max(focus_blocks.id) AS sample_block_id FROM focus_blocks "
            + "LEFT JOIN focus_clients ON focus_clients.block_id = focus_blocks.id "
            + "WHERE project IS NULL AND ignored = 0 AND closed = 1 AND ended_at > ? AND started_at < ? "
            + "GROUP BY app_id, app_name, focus_clients.client ORDER BY millis DESC, app_name LIMIT ?",
            [until, since, since, until, max(1, min(limit, 500))])
        let total = try db.first(
            "SELECT count(*), coalesce(sum(min(ended_at, ?) - max(started_at, ?)), 0) FROM focus_blocks "
            + "WHERE project IS NULL AND ignored = 0 AND closed = 1 AND ended_at > ? AND started_at < ?",
            [until, since, since, until])
        let zone = try Values.zone(try Store.timezoneName(db))
        return .object([
            ("start", .string(bounds.0)), ("end_exclusive", .string(bounds.1)),
            ("block_count", .int(Int64(total?[0].int ?? 0))), ("millis", .int(Int64(total?[1].int ?? 0))),
            ("keeps_details", .bool(try keepsDetails(db))),
            ("apps", .array(try rows.map { row in
                let top = try topDetails(db, where: "project IS NULL AND ignored = 0 AND closed = 1 AND ended_at > ? AND started_at < ? "
                                         + "AND app_id = ? AND app_name = ?",
                                         [since, until, row["app_id"].string ?? "", row["app_name"].string ?? ""])
                return .object([("app_id", row["app_id"].json), ("app_name", row["app_name"].json), ("client", row["client"].json),
                         ("blocks", row["blocks"].json), ("millis", row["millis"].json),
                         ("last_at", AgentOperations.instant(row["last_at"].int, zone: zone)),
                         ("sample_block_id", row["sample_block_id"].json),
                         ("top_titles", top.titles), ("top_sites", top.sites)])
            })),
        ])
    }

    static func weekTimeline(_ db: Database, day text: String?) throws -> JSON {
        let zoneName = try Store.timezoneName(db)
        let zone = try Values.zone(zoneName)
        let day = try text.map { try self.day($0, zone: zone) } ?? today(zone)
        let back = -weekday(day, zone: zone)
        let edges = (0...7).map { midnight(day, offset: back + $0, zone: zone) }
        let blocks = try timelineBlocks(db, since: edges[0], until: edges[7])
        let runs = try db.query("SELECT at, millis FROM entries WHERE kind = 'runtime' AND at >= ? AND at < ?", [edges[0], edges[7]])
        var days: [JSON] = []
        for index in 0..<7 {
            let start = edges[index], end = edges[index + 1]
            let clipped = blocks.compactMap { block -> JSON? in
                guard let from = block["started_at"].intValue, let to = block["ended_at"].intValue, to > start, from < end else {
                    return nil
                }
                var copy = block
                copy.set("started_at", .int(Int64(max(start, from))))
                copy.set("ended_at", .int(Int64(min(end, to))))
                return copy
            }
            let agentMillis = runs.reduce(0) { total, run in
                guard let at = run["at"].int, start <= at, at < end else { return total }
                return total + (run["millis"].int ?? 0)
            }
            days.append(.object([
                ("day", .string(isoDay(day, offset: back + index, zone: zone))), ("day_start", .int(Int64(start))),
                ("day_end", .int(Int64(end))), ("blocks", .array(sortedNewestFirst(clipped))), ("agents", .array([])),
                ("agent_runtime_millis", .int(Int64(agentMillis))),
            ]))
        }
        return .object([("timezone", .string(zoneName)), ("days", .array(days))])
    }
}

/// The parts of a URL as Python 3.9's `urllib.parse.urlsplit` reads them.
struct URLParts {
    var scheme = ""
    var netloc = ""
    var path = ""
    var hasNetloc = false

    init(_ text: String) {
        var rest = Substring(text)
        if let colon = rest.firstIndex(of: ":"), colon != rest.startIndex {
            let candidate = rest[..<colon]
            let schemeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")
            if candidate.allSatisfy({ schemeCharacters.contains($0) }) {
                scheme = candidate.lowercased()
                rest = rest[rest.index(after: colon)...]
            }
        }
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            let end = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
            netloc = String(rest[..<end])
            hasNetloc = true
            rest = rest[end...]
        }
        if let cut = rest.firstIndex(where: { $0 == "#" || $0 == "?" }) { rest = rest[..<cut] }
        path = String(rest)
    }

    var validBrackets: Bool { netloc.contains("[") == netloc.contains("]") }

    private var hostInfo: Substring {
        if let at = netloc.lastIndex(of: "@") { return netloc[netloc.index(after: at)...] }
        return Substring(netloc)
    }

    var hasUser: Bool { netloc.contains("@") }

    var hostname: String? {
        let info = hostInfo
        var host: Substring
        if info.contains("["), let open = info.firstIndex(of: "["), let close = info.firstIndex(of: "]"), open < close {
            host = info[info.index(after: open)..<close]
        } else {
            host = info.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        }
        return host.isEmpty ? nil : host.lowercased()
    }

    var port: String? {
        let info = hostInfo
        if info.contains("["), let close = info.firstIndex(of: "]") {
            let after = info[info.index(after: close)...]
            return after.hasPrefix(":") ? String(after.dropFirst()) : nil
        }
        guard let colon = info.firstIndex(of: ":") else { return nil }
        return String(info[info.index(after: colon)...])
    }
}

/// Host names to ASCII like Python's "idna" codec (IDNA 2003): labels of 1 to 63 characters,
/// non-ASCII labels lower-cased and Punycode-encoded with the "xn--" prefix.
enum IDNA {
    static func toASCII(_ host: String) -> String? {
        if host.isEmpty { return "" }
        var labels: [String] = []
        for part in host.split(separator: ".", omittingEmptySubsequences: false) {
            var label = String(part)
            if !label.unicodeScalars.allSatisfy(\.isASCII) {
                let prepared = label.precomposedStringWithCompatibilityMapping.lowercased()
                guard let encoded = punycode(prepared) else { return nil }
                label = "xn--" + encoded
            }
            guard (1...63).contains(label.utf8.count) else { return nil }
            labels.append(label)
        }
        return labels.joined(separator: ".")
    }

    /// RFC 3492 Punycode encoding.
    static func punycode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basic = output.count
        var handled = basic
        if basic > 0 { output.append("-") }
        func digit(_ value: Int) -> Character {
            Character(Unicode.Scalar(UInt8(value < 26 ? value + 97 : value + 22)))
        }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        var n = 0x80, delta = 0, bias = 72
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }
}
