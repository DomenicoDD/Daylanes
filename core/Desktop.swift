import Foundation

/// The desktop app's reads (snapshot, day timeline), group assignment and the CSV export
/// (Python's `tracker/desktop.py` and the day view of `tracker/focus.py`).
enum Desktop {
    struct GroupKey: Hashable {
        let provider: String?, folder: String?, branch: String?, project: String?, task: String?

        init(_ entry: Entry) {
            provider = entry.provider
            folder = entry.folder
            branch = entry.branch
            project = entry.project
            task = entry.task
        }

        init(provider: String?, folder: String?, branch: String?, project: String?, task: String?) {
            self.provider = provider
            self.folder = folder
            self.branch = branch
            self.project = project
            self.task = task
        }

        func matches(_ other: GroupKey) -> Bool {
            pyEqual(provider, other.provider) && pyEqual(folder, other.folder) && pyEqual(branch, other.branch)
                && pyEqual(project, other.project) && pyEqual(task, other.task)
        }
    }

    static func togglAccount(_ db: Database) throws -> JSON {
        guard let value = try Store.setting(db, "toggl_account"), !value.isEmpty else { return .null }
        return (try? JSON.parse(value)) ?? .null
    }

    static func snapshot(_ db: Database, start: String?, end: String?, period: String,
                         includeHumanTime: Bool = false) throws -> JSON {
        var repositories: [String: [String]] = [:]
        func repos(_ path: String) -> [String] {
            if let cached = repositories[path] { return cached }
            let names = GitHub.worktreeRepos(path)
            repositories[path] = names
            return names
        }
        let (bounds, entries) = try EntryStore.scope(db, start: start, end: end, period: period, worktreeRepos: repos)
        var groups = Ordered<GroupKey, [Entry]>()
        var projects = Ordered<String, [Entry]>()
        for entry in entries {
            if entry.provider.nonEmpty != nil { groups.append(entry, to: GroupKey(entry)) }
            if let project = entry.project.nonEmpty { projects.append(entry, to: project) }
        }
        let prices = try Reports.prices(db)
        let catalog = try Catalog(db)
        var local: [String: (String?, String?)] = [:]
        func localGit(_ path: String) -> (String?, String?) {
            if let found = local[path] { return found }
            let repo = repos(path).first
            let value = (repo, repo != nil ? GitHub.headCommit(path) : nil)
            local[path] = value
            return value
        }
        var activity: [JSON] = []
        for (key, rows) in groups.pairs {
            let (repo, commit) = key.folder.nonEmpty.map(localGit) ?? (nil, nil)
            let last = rows[rows.count - 1]
            var seenSessions = Set<String>()
            let sessions: [JSON] = key.provider == "codex" || key.provider == "claude" ? rows.reversed().compactMap { row in
                guard let id = row.session.nonEmpty, seenSessions.insert(id).inserted else { return nil }
                return .object([("id", .string(id)), ("last_at", .int(Int64(row.at)))])
            } : []
            activity.append(.object([
                ("provider", .optional(key.provider)), ("folder", .optional(key.folder)), ("branch", .optional(key.branch)),
                ("project", .optional(key.project)), ("task", .optional(key.task)), ("client", .optional(last.client)),
                ("sessions", .array(sessions)),
                ("folder_repo", .optional(repo)), ("head_commit", .optional(commit)),
                ("first_at", .int(Int64(rows.map(\.at).min() ?? last.at))), ("last_at", .int(Int64(last.at))),
                ("ended_at", .int(Int64(rows.map { $0.at + ($0.kind == "runtime" ? $0.millis ?? 0 : 0) }.max() ?? last.at))),
                ("entry_count", .int(Int64(rows.count))), ("summary", Reports.timeAndUsage(rows, prices, catalog)),
                ("pull_request", last.hasPullRequest ? last.pullRequest : .null),
                ("github_repo", last.hasGitHub ? .optional(last.githubRepo) : .null),
            ]))
        }
        activity = activity.stableSorted { ($0["last_at"].intValue ?? 0) > ($1["last_at"].intValue ?? 0) }
        let knownModels = try db.query("SELECT DISTINCT provider, model FROM entries WHERE kind = 'usage' AND model IS NOT NULL "
                                       + "ORDER BY provider, model")
        var pullRequests: [String: [JSON]] = [:]
        for row in try db.query("SELECT project, number, title, state, url FROM github_prs ORDER BY project, number DESC") {
            guard let project = row["project"].string else { continue }
            pullRequests[project, default: []].append(.object(["number", "title", "state", "url"].map { ($0, row[$0].json) }))
        }
        var projectList: [JSON] = []
        for var project in try Store.projectList(db).arrayValue ?? [] {
            let folders = project["folders"].arrayValue?.compactMap(\.stringValue) ?? []
            project.set("folder_sources", .array(folders.map { path in
                .object([("path", .string(path)), ("repo", .optional(repos(path).first))])
            }))
            if project["github_repo"].stringValue.nonEmpty != nil {
                project.set("github_pull_requests", .array(pullRequests[project["name"].stringValue ?? ""] ?? []))
            }
            projectList.append(project)
        }
        var result = bounds
        result.set("totals", Reports.timeAndUsage(entries, prices, catalog))
        if includeHumanTime {
            let zone = try Values.zone(bounds["timezone"].stringValue ?? "UTC")
            let first = try Day.parse(bounds["start"].stringValue!)
            let last = try Day.parse(bounds["end_exclusive"].stringValue!)
            let since = first.midnight(zone), until = last.midnight(zone)
            let review = try db.first(
                "SELECT COALESCE(SUM(min(ended_at, ?) - max(started_at, ?)), 0) AS millis FROM focus_blocks "
                + "WHERE project IS NULL AND closed = 1 AND ignored = 0 AND ended_at > ? AND started_at < ?",
                [until, since, since, until])
            let daily = humanTimeByDay(entries, zone: zone)
            result.set("daily_human_millis", .object(daily.map { ($0.key, .int(Int64($0.value))) }))
            result.set("unassigned_focus_millis", review?["millis"].json ?? .int(0))
        }
        result.set("activity", .array(activity))
        result.set("clients", .strings(try Store.clientList(db)))
        result.set("self_client", .string(try Store.selfClient(db)))
        result.set("projects", .array(projectList))
        result.set("project_totals", .object(projects.pairs.map { ($0.0, Reports.timeAndUsage($0.1, prices, catalog)) }))
        result.set("ever_imported", .bool(try db.first("SELECT 1 FROM sources UNION ALL "
                                                       + "SELECT 1 FROM entries WHERE kind = 'usage' LIMIT 1") != nil))
        result.set("subscriptions", try Store.subscriptions(db))
        result.set("billing", try Billing.summary(db, entries, catalog))
        result.set("billing_terms", try Billing.termsListing(db))
        result.set("toggl_account", try togglAccount(db))
        result.set("appearance", try Store.appearanceList(db))
        result.set("openrouter_account", try Reports.openRouterSummary(db, start: bounds["start"].stringValue!,
                                                                       end: bounds["end_exclusive"].stringValue!))
        if let usage = try ProviderUsage.report(db, start: bounds["start"].stringValue!, end: bounds["end_exclusive"].stringValue!) {
            result.set("provider_usage", usage)
        }
        result.set("api_prices_fetched_at", catalog.fetchedAt)
        result.set("models", .array(knownModels.map { row in
            let provider = row["provider"].string, model = row["model"].string
            return .object([
                ("provider", .optional(provider)), ("model", .optional(model)),
                ("prices", prices[Reports.priceKey(provider, model)]?.row.object ?? .null),
                ("openrouter_model", .optional(catalog.model(provider, model))),
            ])
        }))
        return result
    }

    /// Intervals are already clipped to the report period. Split them at local day boundaries,
    /// while keeping manual durations on the day they were logged.
    private static func humanTimeByDay(_ entries: [Entry], zone: TimeZone) -> [String: Int] {
        var totals: [Day: Int] = [:]
        var midnights: [Day: Int] = [:]
        for entry in entries where entry.kind == "human" {
            guard let millis = entry.millis, millis > 0 else { continue }
            var day = Day.local(entry.at, zone)
            if entry.source == .record {
                totals[day, default: 0] += millis
                continue
            }
            var start = entry.at
            let end = start + millis
            while start < end {
                let next = day.adding(days: 1)
                let midnight = midnights[next] ?? next.midnight(zone)
                midnights[next] = midnight
                let segmentEnd = min(midnight, end)
                if segmentEnd > start {
                    totals[day, default: 0] += segmentEnd - start
                    start = segmentEnd
                }
                day = next
            }
        }
        return Dictionary(uniqueKeysWithValues: totals.map { ($0.key.iso, $0.value) })
    }

    static func assignGroup(_ db: Database, target: String, provider: String, folder: String?, branch: String?,
                            project: String?, task: String?, start: String, end: String, saveFolder: Bool) throws -> JSON {
        _ = try Store.project(db, target)
        let (_, entries) = try EntryStore.scope(db, start: start, end: end, period: "week")
        let key = GroupKey(provider: provider, folder: folder, branch: branch, project: project, task: task)
        let ids = entries.filter { GroupKey($0).matches(key) }.map(\.id)
        if ids.isEmpty { throw EngineError.conflict("This activity changed since it was loaded. Reload and try again.") }
        for id in ids { try db.execute("UPDATE entries SET project = ? WHERE id = ?", [target, id]) }
        if saveFolder, let folder = folder.nonEmpty { try Store.mapFolder(db, project: target, folder: folder) }
        return .object([("assigned", .int(Int64(ids.count)))])
    }

    // MARK: CSV export

    static let exportFields = [
        "date", "client", "project", "project_kind", "task", "type", "activity", "provider",
        "model", "hours", "runtime_method", "uncached_input_tokens", "cached_input_tokens", "cache_write_tokens",
        "output_tokens", "currency", "actual_expense", "estimated_token_cost", "reimbursable", "time_source", "tag",
        "github_repo", "github_pr", "openrouter_model", "api_equivalent_usd", "bill_rate", "bill_markup", "bill_amount",
    ]
    static let invoiceItems = ["you": "Your time", "agent_time": "Agent time", "agent_usage": "Agent usage"]

    static func spreadsheetText(_ value: String?) -> String {
        guard let text = value else { return "" }
        let stripped = String(String.UnicodeScalarView(text.unicodeScalars.drop {
            $0.properties.isWhitespace || (0x1C...0x1F).contains($0.value)
        }))
        let first = text.unicodeScalars.first
        if (["=", "+", "-", "@"] as [Unicode.Scalar]).contains(where: { stripped.unicodeScalars.first == $0 }) || first == "\t" || first == "\r" || first == "\n" {
            return "'" + text
        }
        return text
    }

    /// One row the way Python's `csv.writer` writes it (excel dialect, minimal quoting, CRLF).
    static func csvRow(_ fields: [String]) -> String {
        let row = fields.map { field -> String in
            if field.contains(",") || field.contains("\"") || field.unicodeScalars.contains("\r") || field.unicodeScalars.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }
        if row.count == 1 && row[0].isEmpty { return "\"\"\r\n" }
        return row.joined(separator: ",") + "\r\n"
    }

    static func exportCSV(_ db: Database, start: String?, end: String?, period: String, project: String?,
                          client: String?) throws -> String {
        let (bounds, entries) = try EntryStore.scope(db, start: start, end: end, period: period)
        let prices = try Reports.prices(db)
        let catalog = try Catalog(db)
        let zone = try Values.zone(bounds["timezone"].stringValue ?? "UTC")
        let currency = bounds["currency"].stringValue ?? ""
        var out = csvRow(exportFields)
        for entry in entries {
            if let project, !pyEqual(entry.project, project) { continue }
            if let client, !pyEqual(entry.client, client) { continue }
            let kind = entry.kind
            let tokens = kind == "usage"
                ? [entry.input, entry.cached, entry.cacheWrite, entry.output].map { $0.map(String.init) ?? "" }
                : ["", "", "", ""]
            let price = prices[Reports.priceKey(entry.provider, entry.model)]
            let estimate = price != nil && kind == "usage" ? Reports.tokenCents(entry, price!) : nil
            let quote = kind == "usage" ? catalog.quote(entry) : nil
            var fields = [Day.local(entry.at, zone).iso]
            fields += [entry.client, entry.project, entry.projectKind, entry.task].map(spreadsheetText)
            fields += [kind, spreadsheetText(kind != "runtime" ? entry.label : nil), entry.provider ?? "",
                       spreadsheetText(entry.model)]
            fields.append(kind == "human" || kind == "runtime" ? PyDecimal.hours(entry.millis ?? 0) : "")
            fields.append(kind == "runtime" ? entry.label ?? "" : "")
            fields += tokens
            fields.append(currency)
            fields.append(kind == "expense" ? PyDecimal.money(entry.cents ?? 0) : "")
            fields.append(estimate.map { ($0 / PyDecimal(100)).fixedText(6) } ?? "")
            fields.append(kind == "expense" ? ((entry.reimbursable ?? 0) != 0 ? "yes" : "no") : "")
            fields.append(kind == "human" ? entry.timeSource ?? "manual" : "")
            fields.append(spreadsheetText(entry.tag))
            fields.append(spreadsheetText(entry.hasGitHub ? entry.githubRepo : nil))
            fields.append(entry.hasGitHub ? entry.githubPR.map(String.init) ?? "" : "")
            fields.append(quote != nil ? catalog.model(entry.provider, entry.model) ?? "" : "")
            fields.append(quote.map { $0.fixedText(8) } ?? "")
            fields += ["", "", ""]
            out += csvRow(fields)
        }
        let chosen = entries.filter { (project == nil || pyEqual($0.project, project)) && (client == nil || pyEqual($0.client, client)) }
        let invoice = try Billing.summary(db, chosen, catalog)
        for item in invoice["clients"].arrayValue ?? [] {
            var lines: [(String?, JSON)] = []
            for row in item["projects"].arrayValue ?? [] {
                for line in row["lines"].arrayValue ?? [] where line["amount"].stringValue.nonEmpty != nil {
                    lines.append((row["project"].stringValue, line))
                }
            }
            if let reduction = item["cap_reduction"].stringValue.nonEmpty {
                lines.append((nil, .object([("item", .string("cap")), ("amount", .string("-" + reduction))])))
            }
            for (name, line) in lines {
                var row = Dictionary(uniqueKeysWithValues: exportFields.map { ($0, "") })
                row["date"] = bounds["start"].stringValue ?? ""
                row["client"] = spreadsheetText(item["client"].stringValue)
                row["project"] = spreadsheetText(name)
                row["type"] = "invoice"
                row["activity"] = invoiceItems[line["item"].stringValue ?? ""] ?? "Monthly cap on agents"
                row["hours"] = line["hours"].stringValue.nonEmpty ?? ""
                row["currency"] = currency
                row["api_equivalent_usd"] = line["api_usd"].stringValue.nonEmpty ?? ""
                row["bill_rate"] = line["rate"].stringValue.nonEmpty ?? ""
                row["bill_markup"] = line["markup"].stringValue.nonEmpty ?? ""
                row["bill_amount"] = line["amount"].stringValue.nonEmpty ?? ""
                out += csvRow(exportFields.map { row[$0]! })
            }
        }
        return out
    }

    // MARK: Day timeline

    static let threadMergeGap = 20 * 60 * 1000
    static let minRun = 60 * 1000
    static let laneClearance = 20 * 60 * 1000

    static func dayTimeline(_ db: Database, day text: String?, includeHumanTime: Bool = false) throws -> JSON {
        let zoneName = try Store.timezoneName(db)
        let zone = try Values.zone(zoneName)
        let day = try text.map(Day.parse) ?? Day.local(Values.nowMillis(), zone)
        let since = day.midnight(zone), until = day.adding(days: 1).midnight(zone)
        let blocks = try Focus.timelineBlocks(db, since: since, until: until)
        struct Key: Hashable { let provider: String?, project: String?, folder: String? }
        var agents = Ordered<Key, (client: String?, tokens: Int, runtime: Int?, method: String?)>()
        let entries = try EntryStore.entries(db, since: since, until: until)
        for entry in entries where entry.kind == "runtime" || entry.kind == "usage" {
            let key = Key(provider: entry.provider, project: entry.project, folder: entry.project == nil ? entry.folder : nil)
            var row = agents[key] ?? (entry.client, 0, nil, nil)
            if entry.kind == "usage" {
                row.tokens += entry.tokenTotal
            } else {
                row.runtime = (row.runtime ?? 0) + (entry.millis ?? 0)
                row.method = entry.label
            }
            agents[key] = row
        }
        var result: JSON = .object([
            ("day", .string(day.iso)), ("timezone", .string(zoneName)), ("day_start", .int(Int64(since))),
            ("day_end", .int(Int64(until))), ("blocks", .array(blocks)),
            ("agents", .array(agents.pairs.map { key, value in
                .object([("provider", .optional(key.provider)), ("project", .optional(key.project)),
                         ("folder", .optional(key.folder)), ("client", .optional(value.client)),
                         ("tokens", .int(Int64(value.tokens))), ("runtime_millis", .optional(value.runtime)),
                         ("runtime_method", .optional(value.method))])
            })),
            ("agent_threads", .array(agentThreads(entries))),
            ("billing", try Billing.daySpans(db, entries)),
        ])
        if includeHumanTime {
            let humanMillis = entries.filter { $0.kind == "human" }.reduce(0) { $0 + ($1.millis ?? 0) }
            result.set("logged_human_millis", .int(Int64(humanMillis)))
        }
        return result
    }

    static func agentThreads(_ entries: [Entry]) -> [JSON] {
        final class Thread {
            let id: String, provider: String, session: String?, folder: String?
            var project: String?, client: String?, branch: String?
            var spans: [(Int, Int)] = []
            var runs: [(start: Int, end: Int, tokens: Int)] = []
            var startedAt = 0, endedAt = 0, tokens = 0, runtime = 0, lane = 0

            init(_ entry: Entry, key: String) {
                provider = entry.provider ?? ""
                id = "\(provider):\(key)"
                session = entry.session
                project = entry.project
                client = entry.client
                folder = entry.folder
                branch = entry.branch
            }
        }
        var threads = Ordered<String, Thread>()
        var usage: [String: [(Int, Int)]] = [:]
        for entry in entries where (entry.kind == "runtime" || entry.kind == "usage") && entry.provider.nonEmpty != nil {
            let key = Billing.threadKey(entry)
            let thread: Thread
            if let found = threads[key] { thread = found } else {
                thread = Thread(entry, key: Billing.threadName(entry))
                threads[key] = thread
            }
            thread.project = thread.project.nonEmpty ?? entry.project
            thread.client = thread.client.nonEmpty ?? entry.client
            thread.branch = thread.branch.nonEmpty ?? entry.branch
            if entry.kind == "runtime", let millis = entry.millis, millis != 0 {
                thread.spans.append((entry.at, entry.at + millis))
            } else if entry.kind == "usage" {
                usage[key, default: []].append((entry.at, entry.tokenTotal))
            }
        }
        var rows: [Thread] = []
        for (key, thread) in threads.pairs {
            let points = usage[key] ?? []
            let spans = (thread.spans.isEmpty ? points.map { ($0.0, $0.0 + minRun) } : thread.spans)
                .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            var busy: [(Int, Int)] = []
            for (start, end) in spans {
                if let last = busy.last, start <= last.1 { busy[busy.count - 1].1 = max(last.1, end) } else { busy.append((start, end)) }
            }
            var merged: [(start: Int, end: Int, tokens: Int)] = []
            for (start, end) in spans {
                if let last = merged.last, start - last.end <= threadMergeGap {
                    merged[merged.count - 1].end = max(last.end, end)
                } else {
                    merged.append((start, max(end, start + minRun), 0))
                }
            }
            for (at, tokens) in points {
                if let index = merged.indices.reversed().first(where: { merged[$0].start <= at }) ?? (merged.isEmpty ? nil : 0) {
                    merged[index].tokens += tokens
                }
            }
            if merged.isEmpty { continue }
            thread.runs = merged
            thread.startedAt = merged[0].start
            thread.endedAt = merged.map(\.end).max()!
            thread.tokens = merged.reduce(0) { $0 + $1.tokens }
            thread.runtime = busy.reduce(0) { $0 + $1.1 - $1.0 }
            rows.append(thread)
        }
        rows = rows.stableSorted { a, b in
            if a.provider != b.provider { return pyLess(a.provider, b.provider) }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return pyLess(a.id, b.id)
        }
        var lanes: [String: [[(Int, Int)]]] = [:]
        for row in rows {
            var providerLanes = lanes[row.provider] ?? []
            func overlaps(_ taken: [(Int, Int)]) -> Bool {
                row.runs.contains { run in taken.contains { run.start < $0.1 + laneClearance && $0.0 < run.end + laneClearance } }
            }
            let lane = providerLanes.firstIndex { !overlaps($0) } ?? providerLanes.count
            if lane == providerLanes.count { providerLanes.append([]) }
            providerLanes[lane] += row.runs.map { ($0.start, $0.end) }
            lanes[row.provider] = providerLanes
            row.lane = lane
        }
        return rows.map { row in
            .object([
                ("id", .string(row.id)), ("provider", .string(row.provider)), ("session", .optional(row.session)),
                ("project", .optional(row.project)), ("client", .optional(row.client)), ("folder", .optional(row.folder)),
                ("branch", .optional(row.branch)),
                ("runs", .array(row.runs.map { .object([("started_at", .int(Int64($0.start))), ("ended_at", .int(Int64($0.end))),
                                                        ("tokens", .int(Int64($0.tokens)))]) })),
                ("started_at", .int(Int64(row.startedAt))), ("ended_at", .int(Int64(row.endedAt))),
                ("tokens", .int(Int64(row.tokens))), ("runtime_millis", .int(Int64(row.runtime))), ("lane", .int(Int64(row.lane))),
            ])
        }
    }
}
