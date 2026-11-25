import Foundation

/// Codex, Claude Code and OpenCode history (Python's `tracker/importers.py`).
enum AgentLogs {
    static let longPromptTokens = 100_000
    static let idleGapMillis = 5 * 60 * 1000

    // MARK: Codex

    static let codexTiers: [String: String?] = ["priority": "fast", "fast": "fast", "flex": "flex", "ultrafast": "ultrafast",
                                                "default": nil, "standard": nil]

    /// Codex turn ids are unique across logs, so a forked log's copy of a turn lands on the same entry.
    static func realTurn(_ key: String) -> Bool { !key.isEmpty && key != "session" && !key.hasPrefix("at-") }

    private struct Observation {
        let at: Int
        let model: String?
        let folder: String?
        let branch: String?
        let raw: JSON
        let tier: String?
    }

    private static func stamp(_ value: Int?) -> String { value.map(String.init) ?? "None" }

    static func codexEntries(_ records: some Sequence<JSON>, fileID: String) -> [ImportItem] {
        var session = fileID
        var folder: String?, branch: String?, model: String?, turn: String?, turnStart: Int?, tier: String?
        var forkedAt: Int?
        var turnOrder: [String] = []
        var turns: [String: ImportItem] = [:]
        var keyOrder: [String] = []
        var legacy: [String: [(String?, Observation)]] = [:]
        var modern: [String: [(String?, Observation)]] = [:]
        var lastTotals: JSON?
        var limits: JSON?

        func noteKey(_ key: String) { if !keyOrder.contains(key) { keyOrder.append(key) } }
        func setTurn(_ key: String, _ item: ImportItem) {
            if turns[key] == nil { turnOrder.append(key) }
            turns[key] = item
        }

        for row in records {
            let kind = row["type"].stringValue
            let payload = Log.obj(row["payload"])
            let at = Values.parseAt(row["timestamp"])
            switch kind {
            case "session_meta":
                session = Log.text(payload["id"]) ?? Log.text(payload["session_id"]) ?? session
                folder = Log.text(payload["cwd"]) ?? folder
                branch = Log.text(Log.obj(payload["git"])["branch"]) ?? branch
                if Log.text(payload["forked_from_id"]) != nil {
                    // A fork starts by copying its parent's history, written in one burst at the fork time.
                    let parsed = Values.parseAt(payload["timestamp"])
                    forkedAt = (parsed != nil && parsed != 0) ? parsed : at
                }
            case "turn_context":
                turn = Log.text(payload["turn_id"]) ?? turn
                folder = Log.text(payload["cwd"]) ?? folder
                branch = Log.text(Log.obj(payload["git"])["branch"]) ?? branch
                model = Log.text(payload["model"]) ?? model
            case "token_usage_record":
                let response = Log.text(payload["response_id"])
                let raw = Log.obj(payload["usage"])
                let observedAt = at ?? turnStart
                if let response, Log.truthy(raw), let observedAt {
                    let key = Log.text(payload["turn_id"]) ?? turn ?? "session"
                    let reported = Log.text(payload["model"]) ?? model
                    noteKey(key)
                    if !(modern[key] ?? []).contains(where: { $0.0 == response }) {
                        modern[key, default: []].append((response, Observation(at: observedAt, model: reported, folder: folder,
                                                                               branch: branch, raw: raw, tier: tier)))
                    }
                }
            case "event_msg":
                let event = payload["type"].stringValue
                if event == "thread_settings_applied" {
                    let settings = Log.obj(payload["thread_settings"])
                    if settings.pairs?.contains(where: { $0.0 == "service_tier" }) == true {
                        tier = Log.text(settings["service_tier"]).flatMap { codexTiers[$0] ?? nil }
                    }
                } else if event == "task_started" || event == "turn_started" {
                    turnStart = Values.parseAt(payload["started_at"]) ?? at
                    turn = Log.text(payload["turn_id"]) ?? "at-\(stamp(turnStart))"
                } else if event == "task_complete" || event == "turn_complete" || event == "turn_aborted" {
                    let key = Log.text(payload["turn_id"]) ?? turn
                    let start = Values.parseAt(payload["started_at"]) ?? turnStart
                    let end = Values.parseAt(payload["completed_at"]) ?? at
                    var duration = Log.number(payload["duration_ms"])
                    if let start, duration == 0, let end { duration = max(0, end - start) }
                    if duration != 0, let start, let key, !key.isEmpty {
                        let id = realTurn(key) ? "codex:turn:\(key):runtime" : "codex:\(session):\(key):runtime"
                        var fields = Log.metadata("codex", session: session, folder: folder, branch: branch)
                        fields["id"] = .text(id)
                        fields["kind"] = .text("runtime")
                        fields["at"] = .integer(Int64(start))
                        fields["millis"] = .integer(Int64(duration))
                        fields["model"] = model.map(SQLValue.text) ?? .null
                        fields["label"] = .text("turn elapsed")
                        setTurn(key, .entry(fields))
                        if realTurn(key) { setTurn(key + ":old", .remove("codex:\(session):\(key):runtime")) }
                    }
                    turn = nil
                    turnStart = nil
                } else if event == "token_count" {
                    if payload["rate_limits"].pairs != nil, let at {
                        var snapshot = payload["rate_limits"]
                        snapshot.set("observed_at", .int(Int64(at)))
                        limits = snapshot
                    }
                    let info = Log.obj(payload["info"])
                    let totals = Log.obj(info["total_token_usage"])
                    let hasTotals = Log.truthy(totals)
                    if hasTotals, let lastTotals, totals == lastTotals { continue }
                    var latest = Log.obj(info["last_token_usage"])
                    if !Log.truthy(latest), hasTotals, let lastTotals, Log.truthy(lastTotals) {
                        latest = .object((totals.pairs ?? []).map { key, value in
                            (key, .int(Int64(max(0, Log.number(value) - Log.number(lastTotals[key])))))
                        })
                    }
                    if hasTotals { lastTotals = totals }
                    if let forkedAt, let at, abs(at - forkedAt) <= 2000 { continue }  // the parent's usage, replayed
                    if let at, Log.truthy(latest) {
                        if info["last_usage_includes_reasoning"] == .bool(false) {
                            latest.set("output_tokens", .int(Int64(Log.number(latest["output_tokens"])
                                + Log.number(latest["reasoning_output_tokens"]))))
                        }
                        let key = turn ?? "session"
                        noteKey(key)
                        legacy[key, default: []].append((nil, Observation(at: at, model: model, folder: folder,
                                                                          branch: branch, raw: latest, tier: tier)))
                    }
                }
            default:
                break
            }
        }

        var items: [ImportItem] = []
        for key in keyOrder {
            let observations = modern[key] ?? legacy[key] ?? []
            var byModel: [(String, [String: SQLValue])] = []
            var longRequests: [ImportItem] = []
            var kept = Set<String>()
            var oldIDs = Set<String>()
            for (response, seen) in observations {
                let counts = Log.normalizedUsage(seen.raw, provider: "codex")
                guard counts.contains(where: { $0 != 0 }) else { continue }
                let prompt = counts[0] + counts[1] + counts[2]
                let label = seen.model ?? "unknown"
                let oldTurnID = "codex:\(session):\(key):\(label):usage"
                let turnID = (realTurn(key) ? "codex:turn:\(key):\(label)" : String(oldTurnID.dropLast(":usage".count)))
                    + (seen.tier.map { ":\($0)" } ?? "") + ":usage"
                var detail = Log.metadata("codex", session: session, folder: seen.folder, branch: seen.branch)
                detail["tier"] = seen.tier.map(SQLValue.text) ?? .null
                let reasoning = Log.number(seen.raw["reasoning_output_tokens"])
                oldIDs.formUnion([oldTurnID, turnID])
                if prompt >= longPromptTokens {
                    let request = response ?? "at-\(seen.at)"
                    oldIDs.insert("codex:\(session):\(key):\(request):\(label):usage")
                    var fields = Log.merged(detail, Log.tokens(counts))
                    let id = response.map { "codex:response:\($0):usage" } ?? "codex:\(session):\(key):\(request):\(label):usage"
                    fields["id"] = .text(id)
                    fields["kind"] = .text("usage")
                    fields["at"] = .integer(Int64(seen.at))
                    fields["model"] = seen.model.map(SQLValue.text) ?? .null
                    fields["prompt_tokens"] = .integer(Int64(prompt))
                    fields["reasoning"] = .integer(Int64(reasoning))
                    longRequests.append(.entry(fields, inherit: oldTurnID))
                    kept.insert(id)
                    continue
                }
                if let index = byModel.firstIndex(where: { $0.0 == turnID }) {
                    var fields = byModel[index].1
                    fields["prompt_tokens"] = .integer(Int64(max(fields["prompt_tokens"]?.int ?? 0, prompt)))
                    fields["reasoning"] = .integer(Int64((fields["reasoning"]?.int ?? 0) + reasoning))
                    for (field, count) in zip(Log.tokenFields, counts) {
                        fields[field] = .integer(Int64((fields[field]?.int ?? 0) + count))
                    }
                    byModel[index].1 = fields
                } else {
                    var fields = Log.merged(detail, Log.tokens(counts))
                    fields["id"] = .text(turnID)
                    fields["kind"] = .text("usage")
                    fields["at"] = .integer(Int64(seen.at))
                    fields["model"] = seen.model.map(SQLValue.text) ?? .null
                    fields["prompt_tokens"] = .integer(Int64(prompt))
                    fields["reasoning"] = .integer(Int64(reasoning))
                    fields["inherit"] = .text(oldTurnID)
                    byModel.append((turnID, fields))
                    kept.insert(turnID)
                }
            }
            // New entries first, so they take over a project assigned to an entry an earlier version wrote,
            // then remove those old entries.
            items += longRequests
            items += byModel.map { _, fields in
                var copy = fields
                let inherit = copy.removeValue(forKey: "inherit")?.string
                return ImportItem.entry(copy, inherit: inherit)
            }
            for old in oldIDs.subtracting(kept).sorted(by: Log.pyLess) { items.append(.remove(old)) }
        }
        let runtime = turnOrder.compactMap { turns[$0] }
        items += runtime.filter { if case .entry = $0 { return true }; return false }
        items += runtime.filter { if case .remove = $0 { return true }; return false }
        if let limits { items.append(.limits(provider: "codex", limits)) }
        return items
    }

    // MARK: Claude Code

    /// A message the person typed, as opposed to a tool result or a note Claude Code adds itself.
    static func humanPrompt(_ row: JSON) -> Bool {
        if Log.truthy(row["isMeta"]) || Log.truthy(row["isCompactSummary"]) || !row["toolUseResult"].isNull { return false }
        let content = Log.obj(row["message"])["content"]
        if let parts = content.arrayValue {
            return !parts.contains { $0.pairs != nil && $0["type"] == .string("tool_result") }
        }
        return content.stringValue != nil
    }

    struct Activity {
        let at: Int
        let startsTurn: Bool
        let context: (session: String, model: String?, fields: [String: SQLValue])?
    }

    /// Spans the agent was working: from a prompt through its replies and tool calls, until the next
    /// prompt or a pause longer than the idle gap.
    static func activeSpans(_ events: [Activity]) -> [(Int, Int, Activity)] {
        let ordered = events.enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map(\.element)
        var spans: [(Int, Int, Activity)] = []
        var span: (Int, Int, Activity)?
        for event in ordered {
            if var current = span, !event.startsTurn, event.at - current.1 <= idleGapMillis {
                current.1 = event.at
                if event.context != nil { current.2 = event }
                span = current
                continue
            }
            if let current = span, current.1 > current.0 { spans.append(current) }
            span = (event.at, event.at, event)
        }
        if let current = span, current.1 > current.0 { spans.append(current) }
        return spans
    }

    static func claudeDetail(_ raw: JSON, _ row: JSON) -> [String: SQLValue] {
        let creation = Log.obj(raw["cache_creation"])
        var recorded: SQLValue = .null
        switch row["costUSD"] {
        case let .int(value) where value >= 0: recorded = .text(String(value))
        case let .double(value) where value >= 0: recorded = .text(JSON.pythonFloat(value))
        default: break
        }
        return [
            "cache_write_1h": .integer(Int64(min(Log.number(raw["cache_creation_input_tokens"]),
                                                 Log.number(creation["ephemeral_1h_input_tokens"])))),
            "reasoning": .integer(Int64(Log.number(Log.obj(raw["output_tokens_details"])["thinking_tokens"]))),
            "web_searches": .integer(Int64(Log.number(Log.obj(raw["server_tool_use"])["web_search_requests"]))),
            "tier": raw["speed"] == .string("fast") ? .text("fast") : .null,
            "recorded_usd": recorded,
        ]
    }

    static let noDetail: [String: SQLValue] = ["cache_write_1h": .integer(0), "reasoning": .integer(0), "web_searches": .integer(0),
                                               "tier": .null, "recorded_usd": .null, "dedupe_key": .null, "replica": .integer(0),
                                               "prompt_tokens": .null]

    static func claudeEntries(_ records: some Sequence<JSON>, fileID: String) -> [ImportItem] {
        var requestStarts: [String: Int] = [:]
        var responseOrder: [String] = []
        var responses: [String: (entry: [String: SQLValue], start: Int?, end: Int)] = [:]
        var advisorOrder: [String] = []
        var advisors: [String: [String: SQLValue]] = [:]
        var activity: [Activity] = []
        for row in records {
            let kind = row["type"].stringValue
            guard let at = Values.parseAt(row["timestamp"]) else { continue }
            if kind == "user", !Log.truthy(row["isSidechain"]) {
                activity.append(Activity(at: at, startsTurn: humanPrompt(row), context: nil))
            } else if kind == "api-request", let id = Log.text(row["id"]) {
                requestStarts[id] = at
            } else if kind == "assistant" || kind == "progress" {
                let message: JSON, wrapper: JSON
                if kind == "assistant" {
                    message = Log.obj(row["message"])
                    wrapper = row
                } else {
                    // Subagent progress wraps the subagent's own assistant message.
                    wrapper = Log.obj(Log.obj(row["data"])["message"])
                    message = Log.obj(wrapper["message"])
                    if message["role"] != .string("assistant") { continue }
                }
                let model = Log.text(message["model"])
                let raw = Log.obj(message["usage"])
                let messageID = Log.text(message["id"])
                let key = Log.text(wrapper["requestId"]) ?? Log.text(row["requestId"]) ?? messageID ?? Log.text(row["uuid"])
                guard Log.truthy(raw), let key, !(model?.hasPrefix("<") ?? false) else { continue }
                let counts = Log.normalizedUsage(raw, provider: "claude")
                guard counts.contains(where: { $0 != 0 }) else { continue }
                let session = Log.text(row["sessionId"]) ?? fileID
                let context = Log.metadata("claude", session: session, folder: Log.text(row["cwd"]),
                                           branch: Log.text(row["gitBranch"]))
                let sidechain = Log.truthy(row["isSidechain"]) || kind == "progress"
                if !sidechain { activity.append(Activity(at: at, startsTurn: false, context: (session, model, context))) }
                var start = Log.text(row["requestRef"]).flatMap { requestStarts[$0] }
                let detail = claudeDetail(raw, row)
                if let existing = responses[key] {
                    var previous = existing.entry
                    if start == nil { start = existing.start }
                    let effectiveAt = max(at, existing.end)
                    for (field, count) in zip(Log.tokenFields, counts) {
                        previous[field] = .integer(Int64(max(previous[field]?.int ?? 0, count)))
                    }
                    for field in ["cache_write_1h", "reasoning", "web_searches"] {
                        previous[field] = .integer(Int64(max(previous[field]?.int ?? 0, detail[field]?.int ?? 0)))
                    }
                    if previous["tier"]?.isNull ?? true { previous["tier"] = detail["tier"] ?? .null }
                    if previous["recorded_usd"]?.isNull ?? true || previous["recorded_usd"] == .text("") {
                        previous["recorded_usd"] = detail["recorded_usd"] ?? .null
                    }
                    previous["replica"] = .integer((previous["replica"]?.int ?? 0) != 0 && sidechain ? 1 : 0)
                    previous["prompt_tokens"] = .integer(Int64(Log.tokenFields.prefix(3).reduce(0) { $0 + (previous[$1]?.int ?? 0) }))
                    responses[key] = (previous, start, effectiveAt)
                } else {
                    var entry = Log.merged(Log.tokens(counts), context, detail)
                    entry["id"] = .text("claude:\(key):usage")
                    entry["kind"] = .text("usage")
                    entry["at"] = .integer(Int64(at))
                    entry["model"] = model.map(SQLValue.text) ?? .null
                    entry["prompt_tokens"] = .integer(Int64(counts[0] + counts[1] + counts[2]))
                    let dedupe = messageID.flatMap { $0.hasPrefix("msg_") || $0.hasPrefix("resp_") ? $0 : nil }
                    entry["dedupe_key"] = dedupe.map(SQLValue.text) ?? .null
                    entry["replica"] = .integer(sidechain ? 1 : 0)
                    responseOrder.append(key)
                    responses[key] = (entry, start, at)
                }
                // The advisor model's own calls are listed inside the response and billed at its rates.
                for (index, iteration) in (raw["iterations"].arrayValue ?? []).enumerated() {
                    let step = Log.obj(iteration)
                    guard step["type"] == .string("advisor_message") else { continue }
                    let usage = Log.normalizedUsage(step, provider: "claude")
                    guard usage.contains(where: { $0 != 0 }) else { continue }
                    let id = "claude:\(key):advisor:\(index):usage"
                    var entry = Log.merged(Log.tokens(usage), context, claudeDetail(step, .object([])))
                    entry["id"] = .text(id)
                    entry["kind"] = .text("usage")
                    entry["at"] = .integer(Int64(at))
                    let advisorModel = Log.text(step["model"]) ?? Log.text(row["advisorModel"]) ?? model
                    entry["model"] = advisorModel.map(SQLValue.text) ?? .null
                    entry["prompt_tokens"] = .integer(Int64(usage[0] + usage[1] + usage[2]))
                    entry["replica"] = .integer(sidechain ? 1 : 0)
                    if advisors[id] == nil { advisorOrder.append(id) }
                    advisors[id] = entry
                }
            }
        }
        var items: [ImportItem] = []
        if requestStarts.isEmpty {
            // Claude Code logs usually carry no request timings, so measure time from the conversation itself.
            for (start, end, event) in activeSpans(activity) {
                guard let context = event.context else { continue }
                var fields = Log.merged(context.fields, Log.tokens([0, 0, 0, 0]))
                fields["id"] = .text("claude:\(context.session):\(start):runtime")
                fields["kind"] = .text("runtime")
                fields["at"] = .integer(Int64(start))
                fields["millis"] = .integer(Int64(end - start))
                fields["model"] = context.model.map(SQLValue.text) ?? .null
                fields["label"] = .text("active session estimate")
                items.append(.entry(fields))
            }
        }
        for key in responseOrder {
            guard let (entry, start, end) = responses[key] else { continue }
            if let start, end > start {
                var runtime = Log.merged(entry, Log.tokens([0, 0, 0, 0]), noDetail)
                let usageID = entry["id"]?.string ?? ""
                runtime["id"] = .text(String(usageID.dropLast("usage".count)) + "runtime")
                runtime["kind"] = .text("runtime")
                runtime["at"] = .integer(Int64(start))
                runtime["millis"] = .integer(Int64(end - start))
                runtime["label"] = .text("request window estimate")
                items.append(.entry(runtime))
            }
            items.append(.entry(entry))
        }
        items += advisorOrder.compactMap { advisors[$0].map { ImportItem.entry($0) } }
        return items
    }

    // MARK: Where the logs are

    static func home() -> String { ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() }

    static func expand(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? home() + path.dropFirst() : path
    }

    static func configured(_ variable: String) -> [String] {
        (ProcessInfo.processInfo.environment[variable] ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).pythonStripped }.filter { !$0.isEmpty }.map(expand)
    }

    /// ~/.config/claude (newer) and ~/.claude (older), or the folders CLAUDE_CONFIG_DIR names.
    static func claudeHomes() -> [String] {
        let listed = configured("CLAUDE_CONFIG_DIR")
        if !listed.isEmpty { return listed }
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : expand($0) }
        return [(xdg ?? home() + "/.config") + "/claude", home() + "/.claude"]
    }

    static func codexHomes() -> [String] {
        let listed = configured("CODEX_HOME")
        return listed.isEmpty ? [home() + "/.codex"] : listed
    }

    static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(realPath($0)).inserted }
    }

    /// `os.path.realpath`: resolves what exists and keeps the rest.
    static func realPath(_ path: String) -> String { Values.resolvedPath(path) }

    static func roots(codex: String?, claude: String?) -> [String: [String]] {
        [
            "codex": codex.map { [expand($0)] }
                ?? uniquePaths(codexHomes().flatMap { [$0 + "/sessions", $0 + "/archived_sessions"] }),
            "claude": claude.map { [expand($0)] } ?? uniquePaths(claudeHomes().map { $0 + "/projects" }),
        ]
    }

    // MARK: OpenCode

    static func openCodeDatabases(_ path: String?) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let data = (environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : expand($0) } ?? home() + "/.local/share") + "/opencode"
        if let configured = path ?? environment["OPENCODE_DB"].flatMap({ $0.isEmpty ? nil : $0 }) {
            if configured == ":memory:" { return [] }
            let database = expand(configured)
            if path == nil, !database.hasPrefix("/") { return [data + "/" + database] }
            return [database]
        }
        let extra = ((try? FileManager.default.contentsOfDirectory(atPath: data)) ?? [])
            .filter { $0.hasPrefix("opencode-") && $0.hasSuffix(".db") }.map { data + "/" + $0 }.sorted(by: Log.pathLess)
        return [data + "/opencode.db"] + extra
    }

    static func openCodeRows(_ db: Database, since: Int) throws -> [Row] {
        let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0].string })
        var layouts: [(String, String, String, String, String)] = []
        if tables.contains("message"), tables.contains("session") {
            layouts.append(("message", "session", "json_extract(m.data, '$.role') = 'assistant'", "$.modelID", "$.providerID"))
        }
        if tables.contains("session_message") {
            // Recent 1.x builds also ship the projection, attached to the legacy session table.
            let sessions = tables.contains("session_v2") ? "session_v2" : "session"
            if tables.contains(sessions) {
                layouts.append(("session_message", sessions, "m.type IN ('assistant', 'compaction')", "$.model.id", "$.model.providerID"))
            }
        }
        guard !layouts.isEmpty else { throw EngineError.invalid("Unrecognized OpenCode database schema") }
        var rows: [Row] = []
        for (messages, sessions, condition, model, provider) in layouts {
            // Forks copy earlier messages with their original creation times.
            rows += try db.query("""
                SELECT m.id, m.session_id, m.time_created, s.directory,
                       json_extract(m.data, ?) AS model,
                       json_extract(m.data, ?) AS model_provider,
                       json_extract(m.data, '$.path.cwd') AS cwd,
                       json_extract(m.data, '$.tokens') AS tokens,
                       json_extract(m.data, '$.time.streamed') AS streamed,
                       json_extract(m.data, '$.time.completed') AS completed
                FROM \(messages) AS m JOIN \(sessions) AS s ON s.id = m.session_id
                WHERE m.time_created >= ? AND m.time_created >= s.time_created
                    AND CASE WHEN json_valid(m.data) THEN (\(condition)) AND json_type(m.data, '$.tokens') = 'object' END
                """, [model, provider, since])
        }
        return rows
    }

    /// Python's str() of a value from SQLite, for ids built into entry keys.
    static func pyText(_ value: SQLValue) -> String {
        switch value {
        case .null: "None"
        case let .integer(number): String(number)
        case let .real(number): JSON.pythonFloat(number)
        case let .text(text): text
        case let .blob(data): "b'" + data.map { String(format: "\\x%02x", $0) }.joined() + "'"
        }
    }

    static func openCodeEntries(_ path: String, since: Int) throws -> [ImportItem] {
        let db = try Database.readOnly(Values.resolvedPath(path))
        try db.script("BEGIN")
        defer { try? db.script("ROLLBACK") }
        var items: [ImportItem] = []
        for row in try openCodeRows(db, since: since) {
            let tokens = Log.obj((try? JSON.parse(row["tokens"].string ?? "null")) ?? .null)
            let cache = Log.obj(tokens["cache"])
            var counts = [Log.number(tokens["input"]), Log.number(cache["read"]), Log.number(cache["write"]),
                          Log.number(tokens["output"])]
            // Older records can include reasoning in output. Honor the reported total when it matches.
            let total = counts.reduce(0, +)
            if tokens["total"].doubleValue.map({ $0 != Double(total) }) ?? true {
                counts[3] += Log.number(tokens["reasoning"])
            }
            guard counts.contains(where: { $0 != 0 }) else { continue }
            var model = row["model"].string.flatMap { $0.pythonStripped.isEmpty ? nil : $0 }
            if let name = model, let provider = row["model_provider"].string, !provider.pythonStripped.isEmpty, !name.contains("/") {
                model = "\(provider)/\(name)"
            }
            let folder = row["cwd"].string.flatMap { $0.pythonStripped.isEmpty ? nil : $0 }
                ?? row["directory"].string.flatMap { $0.pythonStripped.isEmpty ? nil : $0 }
            let session = row["session_id"].string
            let context = Log.metadata("opencode", session: session, folder: folder, branch: nil)
            let at = row["time_created"]
            let id = pyText(row["id"])
            var fields = Log.merged(context, Log.tokens(counts))
            fields["id"] = .text("harness:opencode:\(id)")
            fields["kind"] = .text("usage")
            fields["at"] = at
            fields["model"] = model.map(SQLValue.text) ?? .null
            fields["prompt_tokens"] = .integer(Int64(counts[0] + counts[1] + counts[2]))
            items.append(.entry(fields))
            let streamed = row["streamed"]
            let end = (streamed.isNull || streamed == .integer(0) || streamed == .real(0) || streamed == .text("")) ? row["completed"] : streamed
            if case let .integer(finish) = end, case let .integer(begin) = at, finish - begin > 0, finish - begin <= 1_000_000_000_000 {
                var runtime = context
                runtime["id"] = .text("opencode:\(id):runtime")
                runtime["kind"] = .text("runtime")
                runtime["at"] = at
                runtime["model"] = model.map(SQLValue.text) ?? .null
                runtime["millis"] = .integer(finish - begin)
                runtime["label"] = .text("request window estimate")
                items.append(.entry(runtime))
            }
        }
        return items
    }

    static func syncOpenCode(_ db: Database, _ stats: ImportStats, path: String?, since: Int) throws {
        let databases = openCodeDatabases(path).filter { Log.isRegularFile(Values.resolvedPath($0)) || Log.isRegularFileFollowing($0) }
        stats.setDirectories("opencode", databases)
        if let path, path != ":memory:", databases.isEmpty {
            stats.sourceErrors.append("OpenCode database not found at \(path)")
        }
        var seen = Set<String>()
        for database in databases {
            let items: [ImportItem]
            do {
                items = try openCodeEntries(database, since: since)
            } catch {
                stats.sourceErrors.append("Could not read OpenCode history in \((database as NSString).lastPathComponent): \(error)")
                continue
            }
            stats.filesRead += 1
            for item in items {
                guard case let .entry(fields, _) = item, let id = fields["id"]?.string, seen.insert(id).inserted else { continue }
                try Store.addEntry(db, fields, refresh: true)
                stats.eventsProcessed += 1
            }
        }
    }

    // MARK: Normalised usage from any harness

    static func importHarness(_ db: Database, harness: String, input: Data) throws -> JSON {
        let harness = try Store.harnessID(harness)
        if harness == "codex" || harness == "claude" { throw EngineError.invalid("Use sync for Codex or Claude Code history") }
        var processed = 0
        let text = String(decoding: input, as: UTF8.self)
        var number = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            if line.pythonStrippedIsEmpty { continue }
            let row: JSON, event: String, model: String, at: Int
            var counts: [Int] = []
            do {
                do { row = try JSON.parse(String(line)) } catch { throw EngineError.invalid(pythonJSONError(String(line))) }
                guard row.pairs != nil else { throw EngineError.invalid("Expected a usage object") }
                event = try Values.required(row["id"].stringValue, "Event ID")
                model = try Values.required(row["model"].stringValue, "Model")
                guard let stamp = Values.parseAt(row["timestamp"]) else {
                    throw EngineError.invalid("Provide an ISO timestamp or Unix seconds")
                }
                at = stamp
                for field in Log.tokenFields {
                    let value = (row.pairs ?? []).contains { $0.0 == field } ? row[field] : .int(0)
                    guard case let .int(count) = value, count >= 0, count <= 1_000_000_000_000 else {
                        throw EngineError.invalid("Provide nonnegative integer token counts and at least one token")
                    }
                    counts.append(Int(count))
                }
                if !counts.contains(where: { $0 != 0 }) {
                    throw EngineError.invalid("Provide nonnegative integer token counts and at least one token")
                }
            } catch let error as EngineError {
                throw EngineError.invalid("Line \(number): \(error.message)")
            }
            var fields = Log.merged(Log.metadata(harness, session: Log.text(row["session"]), folder: Log.text(row["folder"]),
                                                 branch: Log.text(row["branch"])), Log.tokens(counts))
            fields["id"] = .text("harness:\(harness):\(event)")
            fields["at"] = .integer(Int64(at))
            fields["kind"] = .text("usage")
            fields["model"] = .text(model)
            fields["prompt_tokens"] = .integer(Int64(counts[0] + counts[1] + counts[2]))
            try Store.addEntry(db, fields, refresh: true)
            processed += 1
        }
        return .object([("harness", .string(harness)), ("events_processed", .int(Int64(processed)))])
    }

    /// Close to Python's json error text, which the import-harness message includes.
    static func pythonJSONError(_ line: String) -> String { "Expecting value: line 1 column 1 (char 0)" }
}

extension Substring {
    var pythonStrippedIsEmpty: Bool { String(self).pythonStripped.isEmpty }
}

extension Log {
    static func isRegularFileFollowing(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}
