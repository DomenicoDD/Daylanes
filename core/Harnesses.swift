import Foundation

/// Importers for coding agents beyond Claude Code, Codex and OpenCode: a port of `tracker/harnesses.py`,
/// which documents each format. Entry ids and fields match the Python engine exactly.
enum Harnesses {
    static let names: [(String, String)] = [
        ("amp", "Amp"), ("droid", "Droid"), ("codebuff", "Codebuff"), ("cline", "Cline"), ("hermes", "Hermes Agent"),
        ("pi", "pi"), ("openclaw", "OpenClaw"), ("goose", "Goose"), ("kilo", "Kilo"), ("kimi", "Kimi"),
        ("qwen", "Qwen Code"), ("copilot", "GitHub Copilot CLI"), ("gemini", "Gemini CLI"),
        ("antigravity", "Antigravity"), ("grok", "Grok Build"), ("zcode", "ZCode"), ("dsh", "DeepSeek Harness"),
    ]

    static let usdPerAIU = 0.01
    static let grokTicksPerUSD = 1e10

    private static var home: String { H.home() }

    private static func isInt(_ value: JSON) -> Bool {
        if case .int = value { return true }
        return false
    }

    private static func int(_ value: JSON) -> Int64? {
        if case let .int(number) = value { return number }
        return nil
    }

    private static func json(_ path: String) throws -> JSON {
        do { return try H.readJSON(path) } catch let error as CocoaError { throw error } catch {
            throw EngineError.invalid("\(error)")
        }
    }

    private static func parseText(_ value: JSON) -> JSON? {
        guard let text = value.stringValue, let parsed = try? JSON.parse(text) else { return nil }
        return parsed
    }

    private static func parseText(_ value: SQLValue) -> JSON? {
        switch value {
        case let .text(text): try? JSON.parse(text)
        case let .blob(data): try? JSON.parse(data)
        default: nil
        }
    }

    private static func or(_ values: String?...) -> String? {
        for value in values { if let value { return value } }
        return nil
    }

    private static func or(_ values: Int?...) -> Int? {
        for value in values { if let value, value != 0 { return value } }
        return nil
    }

    // MARK: Amp

    static func ampRoots() -> [String] { H.envRoots("AMP_DATA_DIR", [home + "/.local/share/amp"]) }

    static func ampEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let thread = H.obj(try json(path))
        guard let threadID = H.text(thread["id"]) else { return [] }
        let messages = (thread["messages"].arrayValue ?? []).map(H.obj)
        var result: [ImportItem] = []
        if let events = H.obj(thread["usageLedger"])["events"].arrayValue {
            // The ledger has one event per request; cache counts are on the message it produced.
            var cache: [Int64: (Int, Int)] = [:]
            for message in messages {
                if let id = int(message["messageId"]) {
                    let record = H.obj(message["usage"])
                    cache[id] = (H.pick(record, "cacheCreationInputTokens"), H.pick(record, "cacheReadInputTokens"))
                }
            }
            for (index, event) in events.map(H.obj).enumerated() {
                let tokens = H.obj(event["tokens"])
                let model = H.text(event["model"])
                let target = event["toMessageId"]
                let id: Int64? = int(target) ?? (target.doubleValue.flatMap { $0 == $0.rounded() && abs($0) < 9e15 ? Int64($0) : nil })
                let (writes, reads) = id.flatMap { cache[$0] } ?? (0, 0)
                let entry = H.usage("amp", key: "\(threadID):\(H.text(event["id"]) ?? String(index))",
                                    at: H.millis(event["timestamp"]), model: model, session: .text(threadID),
                                    counts: .init(input: H.pick(tokens, "input"), cached: reads, cacheWrite: writes,
                                                  output: H.pick(tokens, "output")),
                                    total: H.pick(tokens, "total"))
                if let entry, model != nil { result.append(entry) }
            }
            return result
        }
        for (index, message) in messages.enumerated() {
            let record = H.obj(message["usage"])
            guard message["role"].stringValue == "assistant", !(record.pairs ?? []).isEmpty else { continue }
            let model = H.text(record["model"]) ?? H.text(message["model"])
            let at = or(H.millis(record["timestamp"]), H.millis(message["timestamp"]))
            let key = message["messageId"].isNull ? String(index) : H.pyStr(message["messageId"])
            let entry = H.usage("amp", key: "\(threadID):\(key)", at: at, model: model, session: .text(threadID),
                                counts: .init(input: H.pick(record, "inputTokens"), cached: H.pick(record, "cacheReadInputTokens"),
                                              cacheWrite: H.pick(record, "cacheCreationInputTokens"),
                                              output: H.pick(record, "outputTokens")),
                                total: H.pick(record, "totalTokens"))
            if let entry, model != nil { result.append(entry) }
        }
        return result
    }

    // MARK: Droid (Factory)

    static func droidRoots() -> [String] { H.envRoots("DROID_SESSIONS_DIR", [home + "/.factory/sessions"]) }

    private static func replace(_ text: String, _ pattern: String, _ with: String) -> String {
        text.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }

    /// Droid writes names such as "custom:Claude-Sonnet-4.5-[Proxy]"; catalog ids use dashes.
    static func droidModel(_ raw: String) -> String {
        var name = raw.hasPrefix("custom:") ? String(raw.dropFirst(7)) : raw
        name = replace(name, #"\[[^\]]*\]"#, "")
        name = name.pythonStripped
        while name.hasSuffix("-") { name.removeLast() }
        name = replace(name.lowercased(), #"[-.\s]+"#, "-")
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The model a session's log names (`Model:\s*([^"\\\[]+)` in its first 501 lines), as Python reads it.
    static func droidSidecarModel(_ path: String) -> String? {
        guard let lines = try? Log.lines(path) else { return nil }
        let marker = Array("Model:".utf8)
        let excluded: Set<UInt8> = [0x22, 0x5C, 0x5B]
        let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C]
        for (number, line) in lines.enumerated() {
            let bytes = [UInt8](line)
            var found: [UInt8]?
            var start = 0
            while found == nil, start + marker.count <= bytes.count {
                guard Array(bytes[start..<start + marker.count]) == marker else { start += 1; continue }
                var position = start + marker.count
                let afterMarker = position
                while position < bytes.count, space.contains(bytes[position]) { position += 1 }
                if position < bytes.count, !excluded.contains(bytes[position]) {
                    var end = position
                    while end < bytes.count, !excluded.contains(bytes[end]) { end += 1 }
                    found = Array(bytes[position..<end])
                } else if position > afterMarker {
                    found = [bytes[position - 1]]
                }
                start += 1
            }
            if found != nil || number >= 500 {
                guard let found else { return nil }
                let text = String(decoding: found, as: UTF8.self).pythonStripped
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    static func droidEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        // A session's settings file holds its running totals, so the session is one entry that grows.
        let settings = H.obj(try json(path))
        let tokens = H.obj(settings["tokenUsage"])
        guard !(tokens.pairs ?? []).isEmpty else { return [] }
        let session = String(H.name(path).dropLast(".settings.json".count))
        var model = H.text(settings["model"])
        let sidecar = H.parent(path) + "/\(session).jsonl"
        if model == nil, Log.isRegularFileFollowing(sidecar) { model = droidSidecarModel(sidecar) }
        let thinking = H.pick(tokens, "thinkingTokens")
        let entry = H.usage("droid", key: "\(session):session", at: H.millis(settings["providerLockTimestamp"]) ?? H.mtime(path),
                            model: model.map(droidModel), session: .text(session), folder: H.text(settings["cwd"]),
                            counts: .init(input: H.pick(tokens, "inputTokens"), cached: H.pick(tokens, "cacheReadTokens"),
                                          cacheWrite: H.pick(tokens, "cacheCreationTokens"), output: H.pick(tokens, "outputTokens")),
                            reasoning: thinking, extra: thinking, total: H.pick(tokens, "totalTokens"))
        return entry.map { [$0] } ?? []
    }

    // MARK: Codebuff

    static func codebuffRoots() -> [String] {
        let config = home + "/.config"
        return H.envRoots("CODEBUFF_DATA_DIR", [config + "/manicode", config + "/manicode-dev", config + "/manicode-staging"])
    }

    struct CodebuffUsage {
        var counts: H.Counts
        var total: Int
        var json: JSON {
            H.countsJSON([("input", counts.input), ("cached", counts.cached), ("cache_write", counts.cacheWrite),
                          ("output", counts.output), ("total", total)])
        }
        var any: Bool { counts.any || total != 0 }
    }

    static func codebuffUsage(_ value: JSON) -> (CodebuffUsage, String?)? {
        let record = H.obj(value)
        guard !(record.pairs ?? []).isEmpty else { return nil }
        let separate = H.pick(record, "cacheReadInputTokens", "cache_read_input_tokens")
        // OpenAI-style usage counts cached tokens inside the prompt; Anthropic-style keeps them apart.
        let included = max(H.pick(H.obj(record["promptTokensDetails"]), "cachedTokens"),
                           H.pick(H.obj(record["prompt_tokens_details"]), "cached_tokens"))
        let prompt = H.pick(record, "inputTokens", "input_tokens", "promptTokens", "prompt_tokens")
        let counts = H.Counts(
            input: included != 0 && separate == 0 ? prompt - min(prompt, included) : prompt,
            cached: max(separate, included),
            cacheWrite: H.pick(record, "cacheCreationInputTokens", "cache_creation_input_tokens", "cacheCreationTokens",
                               "cache_creation_tokens", "cachedTokensCreated", "cached_tokens_created"),
            output: H.pick(record, "outputTokens", "output_tokens", "completionTokens", "completion_tokens"))
        return (CodebuffUsage(counts: counts, total: H.pick(record, "totalTokens", "total_tokens", "total")), H.text(record["model"]))
    }

    static func codebuffEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        guard let messages = try json(path).arrayValue else { return [] }
        let chatDir = H.parent(path)
        let chat = H.name(chatDir)
        let project = H.name(H.parent(H.parent(chatDir)))
        let channelName = H.name(H.parent(H.parent(H.parent(H.parent(chatDir)))))
        let channel = channelName.isEmpty ? "manicode" : channelName
        let session = "\(channel)/\(project)/\(chat)"
        var chatAt: Int?
        if let separator = chat.firstIndex(of: "T") {
            let date = chat[..<separator]
            var clock = String(chat[chat.index(after: separator)...])
            if !clock.isEmpty {
                for _ in 0..<2 {
                    if let dash = clock.firstIndex(of: "-") { clock.replaceSubrange(dash...dash, with: ":") }
                }
                chatAt = H.millis(.string("\(date)T\(clock)"))
            }
        }
        var result: [ImportItem] = []
        for (index, message) in messages.map(H.obj).enumerated() {
            guard let role = H.text(message["variant"]) ?? H.text(message["role"]), ["ai", "agent", "assistant"].contains(role) else { continue }
            let metadata = H.obj(message["metadata"])
            var candidates = [metadata["usage"], H.obj(metadata["codebuff"])["usage"]]
            let history = H.obj(H.obj(H.obj(metadata["runState"])["sessionState"])["mainAgentState"])["messageHistory"]
            for item in (history.arrayValue ?? []).reversed() {
                let options = H.obj(H.obj(item)["providerOptions"])
                if H.obj(item)["role"].stringValue == "assistant" {
                    candidates += [options["usage"], H.obj(options["codebuff"])["usage"]]
                }
            }
            guard let match = candidates.lazy.compactMap(codebuffUsage).first(where: { $0.0.any }) else { continue }
            let (found, foundModel) = match
            let at = or(H.millis(message["timestamp"]), H.millis(message["createdAt"]), H.millis(metadata["timestamp"]), chatAt)
            let model = H.text(metadata["model"]) ?? foundModel
            let key = H.text(message["id"]) ?? H.digest(H.optionalInt(at), .optional(model), .int(Int64(index)), found.json)
            if let entry = H.usage("codebuff", key: "\(session):\(key)", at: at, model: model, session: .text(session),
                                   counts: found.counts, total: found.total) {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: Cline

    static let editors = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium"]

    static func clineRoots() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let appData = environment["APPDATA"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/AppData/Roaming"
        let bases = [home + "/Library/Application Support", xdg, appData]
        let defaults = [home + "/.cline"] + bases.flatMap { base in
            editors.map { base + "/" + $0 + "/User/globalStorage/saoudrizwan.claude-dev" }
        }
        return H.envRoots("CLINE_DATA_DIR", defaults)
    }

    static func clineFiles(_ roots: [String]) -> [String] {
        H.files(roots, ["tasks/*/ui_messages.json", "data/tasks/*/ui_messages.json",
                        "data/sessions/*/*.messages.json", "sessions/*/*.messages.json"])
    }

    static func clineModel(_ info: JSON, _ key: String) -> String? {
        guard let model = H.text(H.obj(info)[key]), model.lowercased() != "unknown" else { return nil }
        return model
    }

    private static func atText(_ at: Int?) -> String { at.map(String.init) ?? "None" }

    static func clineEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let data = try json(path)
        var result: [ImportItem] = []
        if H.name(path) == "ui_messages.json" {
            // Editor extension: each finished request is an api_req_started event with its counts as JSON text.
            let session = "task:\(H.name(H.parent(path)))"
            for message in (data.arrayValue ?? []).map(H.obj) {
                guard message["type"].stringValue == "say", message["say"].stringValue == "api_req_started",
                      message["partial"] != .bool(true) else { continue }
                guard let parsed = parseText(message["text"]) else { continue }
                let metrics = H.obj(parsed)
                guard let model = clineModel(message["modelInfo"], "modelId"),
                      ["tokensIn", "tokensOut", "cacheReads", "cacheWrites"].allSatisfy({ isInt(metrics[$0]) }) else { continue }
                let at = int(message["ts"]).map { Int($0) }
                let key = or(H.text(metrics["requestId"]), H.text(metrics["id"]), H.text(message["id"])) ?? atText(at)
                let entry = H.usage("cline", key: "\(session):\(key)", at: at, model: model, session: .text(session),
                                    counts: .init(input: H.count(metrics["tokensIn"]), cached: H.count(metrics["cacheReads"]),
                                                  cacheWrite: H.count(metrics["cacheWrites"]), output: H.count(metrics["tokensOut"])),
                                    recorded: H.cost(metrics["cost"]))
                if let entry, H.hasTokens(entry) { result.append(entry) }
            }
            return result
        }
        let session = "cli:\(H.name(H.parent(path)))"
        for message in (H.obj(data)["messages"].arrayValue ?? []).map(H.obj) {
            let metrics = H.obj(message["metrics"])
            guard message["role"].stringValue == "assistant", let model = clineModel(message["modelInfo"], "id"),
                  ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"].allSatisfy({ isInt(metrics[$0]) })
            else { continue }
            // The CLI counts cache reads and writes inside its input figure.
            let reads = H.count(metrics["cacheReadTokens"]), writes = H.count(metrics["cacheWriteTokens"])
            guard reads + writes <= H.count(metrics["inputTokens"]) else { continue }
            let at = int(message["ts"]).map { Int($0) } ?? H.millis(message["timestamp"])
            let key = or(H.text(message["requestId"]), H.text(message["id"]), H.text(message["messageId"])) ?? atText(at)
            let entry = H.usage("cline", key: "\(session):\(key)", at: at, model: model, session: .text(session),
                                counts: .init(input: H.count(metrics["inputTokens"]) - reads - writes, cached: reads,
                                              cacheWrite: writes, output: H.count(metrics["outputTokens"])),
                                recorded: H.cost(metrics["cost"]))
            if let entry, H.hasTokens(entry) { result.append(entry) }
        }
        return result
    }

    // MARK: Hermes Agent

    static func hermesDatabases() -> [String] {
        H.existing(H.envRoots("HERMES_HOME", [home + "/.hermes"]).map { $0 + "/state.db" })
    }

    static func optionalColumns(_ columns: Set<String>, _ wanted: [String]) -> String {
        wanted.map { columns.contains($0) ? $0 : "NULL AS \($0)" }.joined(separator: ", ")
    }

    private static func folder(_ value: SQLValue) -> String? { value.string.flatMap { $0.isEmpty ? nil : $0 } }

    static func hermesEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let columns = try H.sqliteTables(path)["sessions"] ?? []
        guard ["id", "model", "started_at"].allSatisfy({ columns.contains($0) }) else {
            throw EngineError.invalid("Unrecognized Hermes database schema")
        }
        let selected = optionalColumns(columns, ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
                                                 "reasoning_tokens", "estimated_cost_usd", "actual_cost_usd",
                                                 "billing_provider", "cwd"])
        var result: [ImportItem] = []
        for row in try H.sqliteRows(path, "SELECT id, model, started_at, \(selected) FROM sessions "
                                        + "WHERE model IS NOT NULL AND trim(model) != ''") {
            let session = row["id"].isNull ? nil : H.text(.string(AgentLogs.pyText(row["id"])))
            // The actual cost wins over the estimate; a recorded zero says nothing, so tokens are priced instead.
            let recorded = H.cost(row["actual_cost_usd"]) ?? H.cost(row["estimated_cost_usd"])
            let reasoning = H.count(row["reasoning_tokens"])
            let model = H.prefixed(H.text(row["billing_provider"]), AgentLogs.pyText(row["model"]),
                                   ignore: ["openrouter", "custom", "local"])
            let entry = H.usage("hermes", key: "\(session ?? "None"):session", at: H.millis(row["started_at"]), model: model,
                                session: H.session(session), folder: folder(row["cwd"]),
                                counts: .init(input: H.count(row["input_tokens"]), cached: H.count(row["cache_read_tokens"]),
                                              cacheWrite: H.count(row["cache_write_tokens"]), output: H.count(row["output_tokens"])),
                                reasoning: reasoning, recorded: recorded == "0.0" ? nil : recorded, extra: reasoning)
            if session != nil, let entry { result.append(entry) }
        }
        return result
    }

    // MARK: pi-agent and OpenClaw (which writes pi's session format)

    static func piRoots() -> [String] { H.envRoots("PI_AGENT_DIR", [home + "/.pi/agent/sessions"]) }

    static func modelChange(_ row: JSON) -> (String?, String?)? {
        let type = row["type"].stringValue
        guard type == "model_change" || (type == "custom" && row["customType"].stringValue == "model-snapshot") else { return nil }
        let data = H.obj(row["data"])
        let source = (data.pairs ?? []).isEmpty ? row : data
        return (H.text(source["modelId"]) ?? H.text(source["model"]), H.text(source["provider"]))
    }

    /// An assistant message with usage. A forked log copies its parent's records with their timestamps,
    /// so a record without an id of its own is keyed by its content and counts once.
    static func piRecord(_ provider: String, _ row: JSON, session: String, folder: String?, model: String?,
                         modelProvider: String?, fallback: Int? = nil) -> ImportItem? {
        let message = H.obj(row["message"])
        let record = H.obj(message["usage"])
        guard row["type"].isNull || row["type"].stringValue == "message", message["role"].stringValue == "assistant",
              !(record.pairs ?? []).isEmpty else { return nil }
        let at = or(H.millis(message["timestamp"]), H.millis(row["timestamp"]), fallback)
        var name = H.text(message["modelId"]) ?? H.text(message["model"]) ?? model
        name = H.prefixed(H.text(message["provider"]) ?? modelProvider, name)
        let counts = H.Counts(input: H.pick(record, "input"), cached: H.pick(record, "cacheRead"),
                              cacheWrite: H.pick(record, "cacheWrite"), output: H.pick(record, "output"))
        let countsJSON = H.countsJSON([("input", counts.input), ("output", counts.output), ("cached", counts.cached),
                                       ("cache_write", counts.cacheWrite)])
        let recorded = H.cost(H.obj(record["cost"])["total"])
        let key = provider == "pi"
            ? H.digest(H.optionalInt(at), .optional(name), countsJSON, .optional(recorded))
            : "\(session):\(H.text(row["id"]) ?? H.digest(H.optionalInt(at), .optional(name), countsJSON))"
        return H.usage(provider, key: key, at: at, model: name, session: .text(session), folder: folder, counts: counts,
                       recorded: recorded, total: H.pick(record, "totalTokens"))
    }

    private static func beforeJSONL(_ path: String) -> String {
        let name = H.name(path)
        return name.components(separatedBy: ".jsonl").first ?? name
    }

    static func piEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let session = beforeJSONL(path)
        var folder: String?, model: String?, modelProvider: String?
        var result: [ImportItem] = []
        for row in try Log.records(path, stats) {
            if row["type"].stringValue == "session" {
                folder = H.text(row["cwd"])
                continue
            }
            if let changed = modelChange(row) {
                model = changed.0 ?? model
                modelProvider = changed.1 ?? modelProvider
                continue
            }
            if let entry = piRecord("pi", row, session: session, folder: folder, model: model, modelProvider: modelProvider) {
                result.append(entry)
            }
        }
        return result
    }

    static func openclawRoots() -> [String] {
        H.envRoots("OPENCLAW_DIR", [".openclaw", ".clawdbot", ".moltbot", ".moldbot"].map { home + "/" + $0 })
    }

    static func openclawFiles(_ roots: [String]) -> [String] {
        // Deleted and reset transcripts keep the usage they recorded.
        H.files(roots, ["**/*.jsonl", "**/*.jsonl.deleted.*", "**/*.jsonl.reset.*", "**/openclaw-agent.sqlite"])
    }

    private static func join(_ parts: ArraySlice<String>) -> String {
        guard let first = parts.first else { return "" }
        let rest = parts.dropFirst().joined(separator: "/")
        if first == "/" { return "/" + rest }
        return rest.isEmpty ? first : first + "/" + rest
    }

    static func openclawAgent(_ path: String) -> String? {
        let parts = H.parts(path)
        guard let index = parts.firstIndex(of: "agents"), index + 1 < parts.count - 1 else { return nil }
        return join(parts[..<(index + 2)])
    }

    /// sessions.json maps session keys such as agent:main:telegram:dm:42 to session ids.
    static func openclawChannels(_ agentDir: String) -> [String: String?] {
        guard let data = try? H.readJSON(agentDir + "/sessions/sessions.json") else { return [:] }
        var found: [String: String?] = [:]
        for (key, value) in H.obj(data).pairs ?? [] {
            guard let session = H.text(H.obj(value)["sessionId"]) else { continue }
            let channel = key.components(separatedBy: ":").dropFirst(2).filter { !$0.isEmpty }.joined(separator: "/")
            found[session] = channel.isEmpty ? nil : channel
        }
        return found
    }

    typealias OpenClawState = [String: (String?, String?, String?)]

    static func openclawEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        // An OpenClaw agent works outside any repository, so its entries carry the agent's folder, plus the
        // channel the session came from: a project's folder rule can then claim a whole agent or one channel.
        let agentDir = openclawAgent(path)
        let channels = agentDir.map(openclawChannels) ?? [:]
        let place: (String, String?) -> String? = { session, cwd in
            if cwd != nil { return cwd }
            guard let agentDir else { return nil }
            if let channel = channels[session] ?? nil, channel != "main" { return agentDir + "/channels/" + channel }
            return agentDir
        }
        var state: OpenClawState = [:]
        var result: [ImportItem] = []
        if H.name(path) == "openclaw-agent.sqlite" {
            guard try H.sqliteTables(path)["transcript_events"] != nil else { return [] }
            for row in try H.sqliteRows(path, "SELECT session_id, seq, event_json, created_at FROM transcript_events "
                                            + "ORDER BY session_id, seq") {
                guard let parsed = parseText(row["event_json"]) else { continue }
                let session = AgentLogs.pyText(row["session_id"])
                if let entry = openclawEvent(H.obj(parsed), session, &state, place, H.millis(row["created_at"])) {
                    result.append(entry)
                }
            }
            return result
        }
        let session = beforeJSONL(path)
        for row in try Log.records(path, stats) {
            if let entry = openclawEvent(row, session, &state, place, nil) { result.append(entry) }
        }
        return result
    }

    static func openclawEvent(_ row: JSON, _ session: String, _ state: inout OpenClawState,
                              _ place: (String, String?) -> String?, _ fallback: Int?) -> ImportItem? {
        let (model, modelProvider, cwd) = state[session] ?? (nil, nil, nil)
        if row["type"].stringValue == "session" {
            state[session] = (model, modelProvider, H.text(row["cwd"]) ?? cwd)
            return nil
        }
        if let changed = modelChange(row) {
            state[session] = (changed.0 ?? model, changed.1 ?? modelProvider, cwd)
            return nil
        }
        // The database and the files it was migrated from hold the same events under the same ids.
        return piRecord("openclaw", row, session: session, folder: place(session, cwd), model: model,
                        modelProvider: modelProvider, fallback: fallback)
    }

    // MARK: Goose

    static func gooseDatabases() -> [String] {
        let configured = (ProcessInfo.processInfo.environment["GOOSE_PATH_ROOT"] ?? "").pythonStripped
        if !configured.isEmpty { return H.existing([AgentLogs.expand(configured) + "/data/sessions/sessions.db"]) }
        return H.existing([home + "/.local/share/goose/sessions/sessions.db",
                           home + "/Library/Application Support/goose/sessions/sessions.db",
                           home + "/.local/share/Block/goose/sessions/sessions.db"])
    }

    static func gooseEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let columns = try H.sqliteTables(path)["sessions"] ?? []
        guard ["id", "model_config_json", "created_at"].allSatisfy({ columns.contains($0) }) else {
            throw EngineError.invalid("Unrecognized Goose database schema")
        }
        let selected = optionalColumns(columns, ["provider_name", "total_tokens", "input_tokens", "output_tokens",
                                                 "accumulated_total_tokens", "accumulated_input_tokens",
                                                 "accumulated_output_tokens", "working_dir"])
        var result: [ImportItem] = []
        for row in try H.sqliteRows(path, "SELECT id, model_config_json, created_at, \(selected) FROM sessions "
                                        + "WHERE model_config_json IS NOT NULL AND trim(model_config_json) != ''") {
            guard let config = parseText(row["model_config_json"]) else { continue }
            let model = H.text(H.obj(config)["model_name"])
            // Session totals: the accumulated columns include every turn, the plain ones only the last.
            func first(_ names: String...) -> Int {
                for name in names where !row[name].isNull { return H.count(row[name]) }
                return 0
            }
            // Goose keeps no cache counts. Tokens in the total beyond input and output are reasoning.
            let id = AgentLogs.pyText(row["id"])
            let entry = H.usage("goose", key: "\(id):session", at: H.millis(row["created_at"]),
                                model: H.prefixed(H.text(row["provider_name"]), model), session: .text(id),
                                folder: folder(row["working_dir"]),
                                counts: .init(input: first("accumulated_input_tokens", "input_tokens"),
                                              output: first("accumulated_output_tokens", "output_tokens")),
                                total: first("accumulated_total_tokens", "total_tokens"))
            if model != nil, let entry { result.append(entry) }
        }
        return result
    }

    // MARK: Kilo

    static func kiloDatabases() -> [String] {
        H.existing(H.envRoots("KILO_DATA_DIR", [home + "/.local/share/kilo"]).map { $0 + "/kilo.db" })
    }

    private static func pyTruthy(_ value: JSON) -> Bool { Log.truthy(value) }

    static func kiloEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let tables = try H.sqliteTables(path)
        guard ["id", "session_id", "data"].allSatisfy({ (tables["message"] ?? []).contains($0) }) else {
            throw EngineError.invalid("Unrecognized Kilo database schema")
        }
        var directories: [String: SQLValue] = [:]
        if ["id", "directory"].allSatisfy({ (tables["session"] ?? []).contains($0) }) {
            for row in try H.sqliteRows(path, "SELECT id, directory FROM session") {
                directories[sqlKey(row["id"])] = row["directory"]
            }
        }
        var result: [ImportItem] = []
        for row in try H.sqliteRows(path, "SELECT id, session_id, data FROM message") {
            guard let parsed = parseText(row["data"]) else { continue }
            let data = H.obj(parsed)
            let tokens = H.obj(data["tokens"])
            guard data["role"].stringValue == "assistant", !(tokens.pairs ?? []).isEmpty else { continue }
            let cache = H.obj(tokens["cache"])
            let reasoning = H.pick(tokens, "reasoning")
            let key = pyTruthy(data["id"]) ? H.pyStr(data["id"]) : AgentLogs.pyText(row["id"])
            let folder = H.text(H.obj(data["path"])["cwd"]) ?? directories[sqlKey(row["session_id"])]?.string
            let entry = H.usage("kilo", key: key, at: H.millis(H.obj(data["time"])["created"]),
                                model: H.prefixed(H.text(data["providerID"]), H.text(data["modelID"]), ignore: ["kilo", "unknown"]),
                                session: row["session_id"], folder: folder,
                                counts: .init(input: H.pick(tokens, "input"), cached: H.pick(cache, "read"),
                                              cacheWrite: H.pick(cache, "write"), output: H.pick(tokens, "output")),
                                reasoning: reasoning, recorded: H.cost(data["cost"]), extra: reasoning,
                                total: H.pick(tokens, "total"))
            if let entry { result.append(entry) }
        }
        return result
    }

    /// A dictionary key for an SQLite value that, like Python, treats 1 and 1.0 alike.
    private static func sqlKey(_ value: SQLValue) -> String {
        switch value {
        case let .real(number) where number == number.rounded() && abs(number) < 9e15: "n:\(Int64(number))"
        case let .integer(number): "n:\(number)"
        default: "v:\(AgentLogs.pyText(value))"
        }
    }

    // MARK: Kimi

    static func kimiRoots() -> [String] { H.envRoots("KIMI_DATA_DIR", [home + "/.kimi", home + "/.kimi-code"]) }

    static func kimiFiles(_ roots: [String]) -> [String] {
        H.files(roots, ["sessions/*/*/wire.jsonl", "sessions/*/*/agents/*/wire.jsonl"])
    }

    static func kimiEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let parts = H.parts(path)
        guard let index = parts.lastIndex(of: "sessions"), index + 2 < parts.count else { return [] }
        let root = join(parts[..<index])
        let session = parts[index + 2]
        var configured: String?
        var result: [ImportItem] = []
        for row in try Log.records(path, stats) {
            let at: Int?, name: String, counts: H.Counts
            var total = 0
            let countsJSON: JSON
            if row["type"].stringValue == "usage.record" {
                // Kimi Code: turn records count once; session records repeat them as running totals.
                let record = H.obj(row["usage"])
                guard row["usageScope"].stringValue == "turn", !(record.pairs ?? []).isEmpty else { continue }
                at = H.millis(row["time"])
                let raw = H.text(row["model"]) ?? "kimi-for-coding"
                name = raw.hasPrefix("kimi-code/") ? String(raw.dropFirst("kimi-code/".count)) : raw
                counts = .init(input: H.pick(record, "inputOther"), cached: H.pick(record, "inputCacheRead"),
                               cacheWrite: H.pick(record, "inputCacheCreation"), output: H.pick(record, "output"))
                countsJSON = H.countsJSON([("input", counts.input), ("output", counts.output), ("cached", counts.cached),
                                           ("cache_write", counts.cacheWrite)])
            } else {
                let message = H.obj(row["message"])
                let record = H.obj(H.obj(message["payload"])["token_usage"])
                guard message["type"].stringValue == "StatusUpdate", !(record.pairs ?? []).isEmpty else { continue }
                if configured == nil {
                    if let config = try? H.readJSON(root + "/config.json") {
                        configured = H.text(H.obj(config)["model"]) ?? "kimi-for-coding"
                    } else {
                        configured = "kimi-for-coding"
                    }
                }
                at = H.millis(row["timestamp"])
                name = configured ?? "kimi-for-coding"
                counts = .init(input: H.pick(record, "input_other"), cached: H.pick(record, "input_cache_read"),
                               cacheWrite: H.pick(record, "input_cache_creation"), output: H.pick(record, "output"))
                total = H.pick(record, "total")
                countsJSON = H.countsJSON([("input", counts.input), ("output", counts.output), ("cached", counts.cached),
                                           ("cache_write", counts.cacheWrite), ("total", total)])
            }
            let key = H.digest(.string(session), H.optionalInt(at), .string(name), countsJSON)
            if let entry = H.usage("kimi", key: key, at: at, model: name, session: .text(session), counts: counts, total: total) {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: Qwen Code

    static func qwenRoots() -> [String] { H.envRoots("QWEN_DATA_DIR", [home + "/.qwen"]) }

    static func qwenFiles(_ roots: [String]) -> [String] {
        H.files(roots, ["projects/*/chats/*.jsonl", "projects/*/chats/archive/*.jsonl"])
    }

    static func qwenEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let parent = H.parent(path)
        let chats = H.name(parent) == "chats" ? parent : H.parent(parent)
        let project = H.name(H.parent(chats))
        var result: [ImportItem] = []
        for row in try Log.records(path, stats) {
            let record = H.obj(row["usageMetadata"])
            guard row["type"].stringValue == "assistant", !(record.pairs ?? []).isEmpty else { continue }
            // Gemini-style usage: the prompt count includes the cached content.
            let prompt = H.pick(record, "promptTokenCount")
            let cached = min(H.pick(record, "cachedContentTokenCount"), prompt)
            let thoughts = H.pick(record, "thoughtsTokenCount")
            let session = H.text(row["sessionId"]) ?? "\(project)-\(H.stem(path))"
            let model = H.text(row["model"]), at = H.millis(row["timestamp"])
            let counts = H.Counts(input: prompt - cached, cached: cached, output: H.pick(record, "candidatesTokenCount"))
            let countsJSON = H.countsJSON([("input", counts.input), ("cached", cached), ("output", counts.output)])
            // An archived copy of a chat holds the same records: the same id keeps them once.
            let key = H.text(row["uuid"])
                ?? H.digest(.string(session), row["timestamp"], .optional(model), countsJSON, .int(Int64(thoughts)))
            if let entry = H.usage("qwen", key: key, at: at, model: model, session: .text(session), folder: H.text(row["cwd"]),
                                   counts: counts, reasoning: thoughts, extra: thoughts,
                                   total: H.pick(record, "totalTokenCount")) {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: GitHub Copilot CLI

    static func copilotRoots() -> [String] {
        let root = (ProcessInfo.processInfo.environment["COPILOT_HOME"] ?? "").pythonStripped
        return [root.isEmpty ? home + "/.copilot" : AgentLogs.expand(root)]
    }

    static func copilotCounts(_ record: JSON) -> (H.Counts, Int) {
        // inputTokens includes both cache buckets; reasoning is part of output.
        let reads = H.pick(record, "cacheReadTokens"), writes = H.pick(record, "cacheWriteTokens")
        return (H.Counts(input: max(H.pick(record, "inputTokens") - reads - writes, 0), cached: reads, cacheWrite: writes,
                         output: H.pick(record, "outputTokens")), H.pick(record, "reasoningTokens"))
    }

    /// A number as Python sees it (booleans are 0 and 1); nil for anything else.
    enum Number {
        case int(Int64), double(Double)
        init?(_ value: JSON) {
            switch value {
            case let .int(number): self = .int(number)
            case let .double(number): self = .double(number)
            case let .bool(flag): self = .int(flag ? 1 : 0)
            default: return nil
            }
        }
        var double: Double {
            switch self {
            case let .int(number): Double(number)
            case let .double(number): number
            }
        }
        func minus(_ other: Number) -> Number {
            switch (self, other) {
            case let (.int(a), .int(b)): .int(a &- b)
            default: .double(double - other.double)
            }
        }
        var atLeastZero: Number { double < 0 ? .int(0) : self }
    }

    static func creditsUSD(_ nano: Number?) -> String? {
        guard let nano else { return nil }
        return H.cost(nano.double / 1e9 * usdPerAIU)
    }

    static func copilotEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        // Current versions write one usage record per call. Older sessions only have shutdown snapshots
        // with running totals per model.
        let session = H.name(H.parent(path))
        let rows = Array(try Log.records(path, stats))  // read twice below
        let records = rows.filter { $0["type"].stringValue == "session.usage_record" }
        let firstRecord = records.isEmpty ? nil : records.map { H.millis($0["timestamp"]) ?? 0 }.min()
        var result: [ImportItem] = []
        for row in records {
            let record = H.obj(H.obj(row["data"])["usage"])
            let accounting = H.obj(record["accounting"])
            let source = H.text(accounting["sourceSessionId"])
            // A record repeated in several sessions' files carries one accounting identity.
            let key: String
            if let source, let sequence = int(accounting["sequence"]), sequence > 0 {
                key = "\(source):\(sequence)"
            } else {
                key = "\(session):\(H.text(row["id"]) ?? H.digest(row))"
            }
            let (counts, reasoning) = copilotCounts(record)
            if let entry = H.usage("copilot", key: "call:\(key)", at: H.millis(row["timestamp"]),
                                   model: H.stripSuffixes(H.text(record["model"]), "-1m-internal", "-1m"),
                                   session: .text(source ?? session), counts: counts, reasoning: reasoning,
                                   recorded: creditsUSD(Number(H.obj(record["copilotUsage"])["totalNanoAiu"]))) {
                result.append(entry)
            }
        }
        // Each shutdown adds what grew since the previous one. Once a session writes a record per call,
        // its later shutdowns repeat those calls, so only the earlier ones count.
        var previous: [String: (H.Counts, Int, Number?)] = [:]
        for (index, row) in rows.enumerated() {
            let at = H.millis(row["timestamp"])
            guard row["type"].stringValue == "session.shutdown", let at else { continue }
            if let firstRecord, at >= firstRecord { continue }
            let data = H.obj(row["data"])
            if Log.truthy(data["usageAccountingWatermarks"]) { continue }
            for (model, value) in H.obj(data["modelMetrics"]).pairs ?? [] {
                let metrics = H.obj(value)
                let (counts, reasoning) = copilotCounts(H.obj(metrics["usage"]))
                let nano = Number(metrics["totalNanoAiu"])
                let before: (H.Counts, Int, Number?) = previous[model] ?? (H.Counts(), 0, Number.int(0))
                previous[model] = (counts, reasoning, nano)
                let delta = H.Counts(input: max(counts.input - before.0.input, 0), cached: max(counts.cached - before.0.cached, 0),
                                     cacheWrite: max(counts.cacheWrite - before.0.cacheWrite, 0),
                                     output: max(counts.output - before.0.output, 0))
                var spent: String?
                if let nano, let earlier = before.2 { spent = creditsUSD(nano.minus(earlier).atLeastZero) }
                if !delta.any && (spent == nil || spent == "0.0") { continue }
                if let entry = H.usage("copilot", key: "shutdown:\(session):\(model):\(index)", at: at,
                                       model: H.stripSuffixes(model, "-1m-internal", "-1m"), session: .text(session),
                                       counts: delta, reasoning: max(reasoning - before.1, 0), recorded: spent) {
                    result.append(entry)
                }
            }
        }
        return result
    }

    // MARK: Gemini CLI

    static let geminiKeys: [(String, [String])] = [
        ("input", ["input", "prompt", "input_tokens", "prompt_tokens"]),
        ("output", ["output", "candidates", "output_tokens", "candidates_tokens"]),
        ("cached", ["cached", "cached_tokens"]),
        ("thoughts", ["thoughts", "reasoning", "thoughts_tokens", "reasoning_tokens"]),
        ("tool", ["tool", "tool_tokens"]),
    ]

    struct GeminiTokens {
        var counts: H.Counts
        var extra: Int
        var total: Int
    }

    private static func pick(_ record: JSON, _ keys: [String]) -> Int {
        for key in keys where !record[key].isNull { return H.count(record[key]) }
        return 0
    }

    static func geminiTokens(_ value: JSON, message: Bool) -> GeminiTokens? {
        let record = H.obj(value)
        guard let pairs = record.pairs, !pairs.isEmpty else { return nil }
        var values: [String: Int] = [:]
        for (name, keys) in geminiKeys { values[name] = pick(record, keys) }
        let input = values["input"]!, output = values["output"]!, cached = values["cached"]!
        let thoughts = values["thoughts"]!, tool = values["tool"]!
        let total: Int? = ["total", "total_tokens"].first { key in pairs.contains { $0.0 == key } }.map { H.count(record[$0]) }
        let overlap: Bool
        if message {
            // A message's input includes its cached prompt only when the total says so.
            let inclusive = input + output + thoughts + tool
            overlap = cached > 0 && total == inclusive && total != inclusive + cached
        } else {
            overlap = true  // session statistics count the cached prompt inside input
        }
        let fresh = overlap ? input - min(input, cached) : input
        return GeminiTokens(counts: .init(input: fresh + tool, cached: cached, output: output), extra: thoughts,
                            total: total ?? fresh + tool + output + cached + thoughts)
    }

    static func geminiStats(_ record: JSON, _ hint: String?) -> [(String, GeminiTokens)] {
        var stats = H.obj(record["stats"])
        if (stats.pairs ?? []).isEmpty { stats = H.obj(H.obj(record["result"])["stats"]) }
        var found: [(String, GeminiTokens)] = []
        for (model, data) in H.obj(stats["models"]).pairs ?? [] {
            if let tokens = geminiTokens(H.obj(data)["tokens"], message: false) { found.append((model, tokens)) }
        }
        if found.isEmpty, !(stats.pairs ?? []).isEmpty, let tokens = geminiTokens(stats, message: false),
           tokens.counts.input != 0 || tokens.counts.cached != 0 || tokens.counts.output != 0 || tokens.extra != 0 {
            found.append((hint ?? "unknown", tokens))
        }
        return found
    }

    static func geminiRoots() -> [String] { H.envRoots("GEMINI_DATA_DIR", [home + "/.gemini/tmp"]) }

    private static func geminiUsage(_ key: String, _ at: Int?, _ model: String, _ session: String, _ tokens: GeminiTokens) -> ImportItem? {
        H.usage("gemini", key: key, at: at, model: model, session: .text(session), counts: tokens.counts,
                reasoning: tokens.extra, extra: tokens.extra, total: tokens.total)
    }

    static func geminiEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        var session = H.stem(path)
        // Python dict semantics: a key keeps its first position; "0" and 0 are different keys.
        var order: [String] = [], labels: [String: String] = [:], events: [String: (JSON, String?, Int?)] = [:]
        func setEvent(_ id: String?, _ value: (JSON, String?, Int?)) {
            let key = id.map { "s:" + $0 } ?? "i:\(events.count)"
            if events[key] == nil { order.append(key); labels[key] = id ?? String(events.count) }
            events[key] = value
        }
        var totals: [(JSON, String?, Int?)] = []
        var model: String?
        if H.suffix(path) == ".json" {
            let document = H.obj(try json(path))
            session = H.text(document["sessionId"]) ?? H.text(document["session_id"]) ?? session
            let start = or(H.millis(document["startTime"]), H.millis(document["lastUpdated"]), H.mtime(path))
            if let messages = document["messages"].arrayValue {
                for record in messages.map(H.obj) {
                    model = H.text(record["model"]) ?? model
                    if record["type"].stringValue == "gemini" { setEvent(H.text(record["id"]), (record, model, start)) }
                }
            } else if document["type"].stringValue == "gemini" {
                setEvent("0", (document, H.text(document["model"]), H.mtime(path)))
            } else {
                totals.append((document, H.text(document["model"]), H.mtime(path)))
            }
        } else {
            for record in try Log.records(path, stats) {
                session = H.text(record["sessionId"]) ?? H.text(record["session_id"]) ?? session
                model = H.text(record["model"]) ?? model
                if record["type"].stringValue == "gemini" {
                    // A message written again as it streams keeps its id: the last copy wins.
                    setEvent(H.text(record["id"]), (record, model, nil))
                } else {
                    totals.append((record, model, nil))
                }
            }
        }
        var result: [ImportItem] = []
        for key in order {
            let (record, known, fallback) = events[key]!
            let at = or(H.millis(record["timestamp"]), H.millis(record["created_at"]), fallback)
            guard let tokens = geminiTokens(record["tokens"], message: true), let name = H.text(record["model"]) ?? known else { continue }
            if let entry = geminiUsage("\(session):\(labels[key]!)", at, name, session, tokens) { result.append(entry) }
        }
        if !order.isEmpty { return result }  // session statistics repeat the messages above
        for (index, (record, name, fallback)) in totals.enumerated() {
            let at = or(H.millis(record["timestamp"]), H.millis(record["created_at"]), fallback)
            for (modelName, tokens) in geminiStats(record, name) {
                if let entry = geminiUsage("\(session):stats:\(index):\(modelName)", at, modelName, session, tokens) {
                    result.append(entry)
                }
            }
        }
        return result
    }

    // MARK: Antigravity

    static let antigravityIDs: [Int: String] = [
        246: "gemini-2.5-pro", 312: "gemini-2.5-flash", 313: "gemini-2.5-flash-thinking", 329: "gemini-2.5-flash-thinking",
        330: "gemini-2.5-flash-lite", 281: "claude-sonnet-4", 282: "claude-sonnet-4", 290: "claude-opus-4", 291: "claude-opus-4",
        333: "claude-sonnet-4.5", 334: "claude-sonnet-4.5", 340: "claude-haiku-4.5", 341: "claude-haiku-4.5", 342: "gpt-oss-120b",
    ]
    static let antigravityNames: [String: String] = [
        "model_placeholder_m26": "claude-opus-4-6", "model_placeholder_m35": "claude-sonnet-4-6",
        "model_placeholder_m402": "claude-opus-5-5", "model_placeholder_m50": "gemini-3.1-flash-lite",
        "model_placeholder_m36": "gemini-3.1-pro", "model_placeholder_m37": "gemini-3.1-pro",
        "model_placeholder_m16": "gemini-3.1-pro", "model_placeholder_m18": "gemini-3-flash-preview",
        "model_placeholder_m84": "gemini-3-flash-preview", "model_placeholder_m47": "gemini-3-flash-preview",
        "model_placeholder_m417": "gemini-4-argon", "model_placeholder_m418": "gemini-4-argon",
        "model_placeholder_m419": "gemini-4-argon", "model_placeholder_m318": "gemini-3.8-flash-high",
        "model_placeholder_m319": "gemini-3.8-flash-medium", "model_placeholder_m320": "gemini-3.8-flash-low",
        "model_placeholder_m298": "gemini-3.7-flash-high", "model_placeholder_m299": "gemini-3.7-flash-medium",
        "model_placeholder_m300": "gemini-3.7-flash-low", "model_placeholder_m71": "gemini-3.6-flash-high",
        "model_placeholder_m72": "gemini-3.6-flash-medium", "model_placeholder_m73": "gemini-3.6-flash-low",
        "model_placeholder_m132": "gemini-3.5-flash-high", "model_placeholder_m133": "gemini-3.5-flash-high",
        "model_placeholder_m187": "gemini-3.5-flash-extra-low", "model_placeholder_m20": "gemini-3.5-flash-medium",
        "gemini-pro-default": "gemini-3.1-pro", "gemini-pro-agent": "gemini-3.1-pro",
        "gemini-3-flash": "gemini-3-flash-preview", "gemini-3-flash-c": "gemini-3-flash-preview",
        "gemini-3.1-pro-high": "gemini-3.1-pro", "gemini-3.1-pro-low": "gemini-3.1-pro",
        "gemini-3-pro-high": "gemini-3-pro", "gemini-3-pro-low": "gemini-3-pro",
        "model_openai_gpt_oss_120b_medium": "gpt-oss-120b",
    ]

    static func antigravityRoots() -> [String] {
        let gemini = home + "/.gemini"
        let defaults = ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup", "antigravity-acp"]
            .map { gemini + "/" + $0 + "/conversations" }
        let roots = H.envRoots("ANTIGRAVITY_DATA_DIR", defaults + [home + "/.config/antigravity/conversations"])
        return roots.map { Log.isDirectory($0 + "/conversations") ? $0 + "/conversations" : $0 }
    }

    enum ProtoValue: Equatable {
        case int(UInt64)
        case bytes([UInt8])
    }

    typealias Proto = [(Int, ProtoValue)]

    static func varint(_ blob: [UInt8], _ position: inout Int) throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard position < blob.count, shift <= 63 else { throw EngineError.invalid("Truncated protobuf") }
            let byte = blob[position]
            position += 1
            value |= UInt64(byte & 0x7F) &<< shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    /// Decode one protobuf message into (field number, value) pairs.
    static func proto(_ blob: [UInt8]) throws -> Proto {
        var fields: Proto = [], position = 0
        while position < blob.count {
            let tag = try varint(blob, &position)
            let number = Int(truncatingIfNeeded: tag >> 3), wire = tag & 7
            guard number != 0 else { throw EngineError.invalid("Invalid protobuf field") }
            switch wire {
            case 0:
                fields.append((number, .int(try varint(blob, &position))))
            case 2:
                let length = try varint(blob, &position)
                guard length <= UInt64(blob.count - position) else { throw EngineError.invalid("Truncated protobuf") }
                fields.append((number, .bytes(Array(blob[position..<position + Int(length)]))))
                position += Int(length)
            case 1: position += 8
            case 5: position += 4
            default: throw EngineError.invalid("Unsupported protobuf wire type")
            }
        }
        return fields
    }

    static func proto(_ value: SQLValue) throws -> Proto {
        switch value {
        case .null: return []
        case let .blob(data): return try proto([UInt8](data))
        case let .text(text): return try proto([UInt8](text.utf8))
        default: throw EngineError.invalid("Expected protobuf bytes")
        }
    }

    static func protoInts(_ fields: Proto, _ number: Int) -> [UInt64] {
        fields.compactMap { field, value in if field == number, case let .int(found) = value { return found }; return nil }
    }

    static func protoBytes(_ fields: Proto, _ number: Int) -> [[UInt8]] {
        fields.compactMap { field, value in if field == number, case let .bytes(found) = value { return found }; return nil }
    }

    static func protoInt(_ fields: Proto, _ number: Int) -> Int {
        protoInts(fields, number).last.map { Int(truncatingIfNeeded: $0) } ?? 0
    }

    static func protoMessage(_ fields: Proto, _ number: Int) throws -> Proto {
        guard let first = protoBytes(fields, number).first else { return [] }
        return try proto(first)
    }

    static func protoText(_ fields: Proto, _ number: Int) -> String? {
        for value in protoBytes(fields, number).reversed() {
            guard let decoded = String(bytes: value, encoding: .utf8) else { continue }
            if !decoded.pythonStripped.isEmpty { return decoded }
        }
        return nil
    }

    static func protoTime(_ fields: Proto) -> Int? {
        let seconds = protoInt(fields, 1)
        return seconds > 0 ? seconds * 1000 + min(protoInt(fields, 2), 999_999_999) / 1_000_000 : nil
    }

    static func packedInts(_ fields: Proto, _ number: Int) -> [UInt64] {
        var found = protoInts(fields, number)
        for blob in protoBytes(fields, number) {
            var position = 0
            while position < blob.count, let value = try? varint(blob, &position) { found.append(value) }
        }
        return found
    }

    struct AntigravityCall: Equatable {
        var modelID = 0, input = 0, totalOutput = 0, cacheWrite = 0, cached = 0, reasoning = 0, visible = 0
        var identities: [String] = []
        var any: Bool { [input, totalOutput, cacheWrite, cached, reasoning, visible].contains { $0 != 0 } }
    }

    static func antigravityUsage(_ fields: Proto) -> AntigravityCall {
        let identities = [("response", protoText(fields, 11)), ("provider", protoText(fields, 12)), ("message", protoText(fields, 7))]
            .compactMap { prefix, value in value.map { "\(prefix):\($0)" } }
        return AntigravityCall(modelID: protoInt(fields, 1), input: protoInt(fields, 2), totalOutput: protoInt(fields, 3),
                               cacheWrite: protoInt(fields, 4), cached: protoInt(fields, 5), reasoning: protoInt(fields, 9),
                               visible: protoInt(fields, 10), identities: identities)
    }

    /// The primary usage of a step or generation, then its retries. The retry list repeats the primary
    /// attempt once, which is dropped.
    static func antigravityCalls(_ fields: Proto, _ primary: Int, _ retries: Int) throws -> [AntigravityCall] {
        let first = try protoBytes(fields, primary).prefix(1).map { antigravityUsage(try proto($0)) }
        var again = try protoBytes(fields, retries).map { antigravityUsage(try protoMessage(try proto($0), 2)) }
        if let primaryCall = first.first, let mirror = again.firstIndex(of: primaryCall) { again.remove(at: mirror) }
        return first + again
    }

    static func antigravityModel(_ raw: String?, _ modelID: Int) -> String? {
        if let raw, !raw.isEmpty {
            var base = (raw.pythonStripped.lowercased().components(separatedBy: "(").first ?? "").pythonStripped
            if let known = antigravityNames[base] { return known }
            base = replace(base, #"\s+thinking$"#, "")
            return ["gemini", "claude", "gpt"].contains(where: { base.hasPrefix($0) }) ? base.replacingOccurrences(of: " ", with: "-")
                : raw.pythonStripped
        }
        if let known = antigravityIDs[modelID] { return known }
        if modelID >= 1000 {
            let placeholder = "model_placeholder_m\(modelID - 1000)"
            return antigravityNames[placeholder] ?? placeholder
        }
        return nil
    }

    static func antigravityEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let tables = try H.sqliteTables(path)
        guard tables["gen_metadata"] != nil else { return [] }
        let session = H.stem(path)
        var fallback: Int?
        if tables["trajectory_metadata_blob"] != nil {
            for row in try H.sqliteRows(path, "SELECT data FROM trajectory_metadata_blob ORDER BY rowid") {
                let time = protoTime(try protoMessage(try proto(row["data"]), 2))
                if fallback == nil || fallback == 0 { fallback = time }
            }
        }
        if fallback == nil || fallback == 0 { fallback = H.mtime(path) }
        var calls: [([String], Int?, String?, AntigravityCall)] = []
        if tables["steps"] != nil {
            for row in try H.sqliteRows(path, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx") {
                let fields = try proto(row["metadata"])
                let info = try protoMessage(fields, 24)
                let model = antigravityModel(protoText(info, 12) ?? protoText(info, 8), protoInt(info, 1))
                var stamp = try protoMessage(fields, 8)
                if stamp.isEmpty { stamp = try protoMessage(fields, 1) }
                let at = protoTime(stamp)
                for (number, call) in try antigravityCalls(fields, 9, 28).enumerated() {
                    let ids = call.identities.isEmpty ? ["step:\(session):\(AgentLogs.pyText(row["idx"])):\(number)"] : call.identities
                    calls.append((ids, at, model, call))
                }
            }
        }
        var current: String?
        for row in try H.sqliteRows(path, "SELECT idx, data FROM gen_metadata ORDER BY idx") {
            let root = try proto(row["data"])
            let fields = try protoMessage(root, 1)
            guard !fields.isEmpty else { continue }
            // Continuation rows without a model use the last one named.
            current = antigravityModel(protoText(fields, 19) ?? protoText(fields, 21), protoInt(fields, 3)) ?? current
            let at = protoTime(try protoMessage(try protoMessage(fields, 9), 4))
            let steps = packedInts(root, 2).map { "step:\(session):\($0)" }
            for (number, call) in try antigravityCalls(fields, 4, 17).enumerated() {
                let fallbackIDs = steps.isEmpty ? ["gen:\(session):\(AgentLogs.pyText(row["idx"])):\(number)"]
                    : steps.map { "\($0):\(number)" }
                calls.append((call.identities.isEmpty ? fallbackIDs : call.identities, at, current, call))
            }
        }
        // A step and its generation list the same call: calls that share an identity count once.
        var merged: [(String, Int?, String?, AntigravityCall)] = []
        var owner: [String: Int] = [:]
        for (identities, at, model, call) in calls where call.any {
            if let index = identities.lazy.compactMap({ owner[$0] }).first {
                let known = [merged[index].1, at].compactMap { $0 }.filter { $0 != 0 }
                merged[index].1 = known.min()
                if merged[index].2 == nil || merged[index].2 == "" { merged[index].2 = model }
                for identity in identities where owner[identity] == nil { owner[identity] = index }
            } else {
                let index = merged.count
                merged.append((identities[0], at, model, call))
                for identity in identities where owner[identity] == nil { owner[identity] = index }
            }
        }
        var result: [ImportItem] = []
        for (key, at, known, call) in merged {
            let model = call.modelID != 0 && (known ?? "").isEmpty ? antigravityModel(nil, call.modelID) : known
            let output = max(call.totalOutput, call.visible + call.reasoning)
            let when = (at ?? 0) != 0 ? at : fallback
            if let entry = H.usage("antigravity", key: "\(session):\(key)", at: when,
                                   model: (model ?? "").isEmpty ? "gemini-internal-model" : model, session: .text(session),
                                   counts: .init(input: call.input, cached: call.cached, cacheWrite: call.cacheWrite, output: output),
                                   reasoning: call.reasoning) {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: Grok Build

    static func grokRoots() -> [String] {
        let root = (ProcessInfo.processInfo.environment["GROK_HOME"] ?? "").pythonStripped
        return [root.isEmpty ? home + "/.grok" : AgentLogs.expand(root)]
    }

    static func grokEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let parent = H.parent(path)
        var session = H.name(parent)
        let quoted = H.name(H.parent(parent))
        var folder = quoted.removingPercentEncoding ?? quoted
        var defaultModel: String?
        let summary = parent + "/summary.json"
        if Log.isRegularFileFollowing(summary), let data = try? H.readJSON(summary) {
            let document = H.obj(data)
            let info = H.obj(document["info"])
            session = H.text(info["id"]) ?? session
            folder = H.text(info["cwd"]) ?? H.text(document["git_root_dir"]) ?? folder
            defaultModel = H.text(document["current_model_id"])
        }
        var result: [ImportItem] = []
        for row in try Log.records(path, stats) {
            let params = H.obj(row["params"])
            let update = H.obj(params["update"])
            let record = H.obj(update["usage"])
            guard update["sessionUpdate"].stringValue == "turn_completed", !(record.pairs ?? []).isEmpty else { continue }
            let meta = H.obj(params["_meta"])
            // agentTimestampMs is in milliseconds, the envelope's timestamp in seconds.
            let at = or(H.count(meta["agentTimestampMs"]), H.count(row["timestamp"]) * 1000)
            var byModel = H.obj(record["modelUsage"]).pairs ?? []
            if byModel.isEmpty { byModel = [(defaultModel ?? "unknown", record)] }
            let event = H.text(meta["eventId"])
            let sessionID = H.text(params["sessionId"]) ?? session
            for (model, value) in byModel.sorted(by: { Log.pyLess($0.0, $1.0) }) {
                let part = H.obj(value)
                // inputTokens includes cache reads and writes; reasoning is part of output.
                let prompt = H.pick(part, "inputTokens")
                let reads = min(H.pick(part, "cachedReadTokens"), prompt)
                let writes = min(H.pick(part, "cacheCreationTokens"), prompt - reads)
                let counts = H.Counts(input: prompt - reads - writes, cached: reads, cacheWrite: writes,
                                      output: H.pick(part, "outputTokens"))
                let ticks = H.pick(part, "costUsdTicks")
                let key = event.map { "\($0):\(model)" } ?? H.digest(
                    .string(sessionID), H.optionalInt(at), .string(model),
                    H.countsJSON([("input", counts.input), ("cached", reads), ("cache_write", writes), ("output", counts.output)]))
                if let entry = H.usage("grok", key: key, at: at, model: H.stripSuffixes(model, "-build"), session: .text(sessionID),
                                       folder: folder.hasPrefix("/") ? folder : nil, counts: counts,
                                       reasoning: H.pick(part, "reasoningTokens"),
                                       recorded: ticks != 0 ? H.cost(Double(ticks) / grokTicksPerUSD) : nil) {
                    result.append(entry)
                }
            }
        }
        return result
    }

    // MARK: ZCode

    static func zcodeDatabases() -> [String] {
        H.existing(H.envRoots("ZCODE_HOME", [home + "/.zcode"]).map { $0 + "/cli/db/db.sqlite" })
    }

    static func zcodeEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        let tables = try H.sqliteTables(path)
        let columns = tables["model_usage"] ?? []
        let required = ["id", "session_id", "started_at", "model_id", "status", "input_tokens", "output_tokens"]
        guard required.allSatisfy({ columns.contains($0) }), ["id", "directory"].allSatisfy({ (tables["session"] ?? []).contains($0) }) else {
            throw EngineError.invalid("Unrecognized ZCode database schema")
        }
        func column(_ name: String, _ fallback: String = "0") -> String { columns.contains(name) ? "m.\(name)" : fallback }
        let query = """
            SELECT m.id, m.session_id, m.started_at, m.model_id, m.input_tokens, m.output_tokens,
                   \(column("cache_creation_input_tokens")) AS writes, \(column("cache_read_input_tokens")) AS reads,
                   \(column("computed_total_tokens", "m.input_tokens + m.output_tokens")) AS total,
                   \(column("provider_id", "NULL")) AS provider, s.directory
            FROM model_usage m LEFT JOIN session s ON s.id = m.session_id WHERE m.status = 'completed'
            """
        var result: [ImportItem] = []
        for row in try H.sqliteRows(path, query) {
            // input_tokens includes both cache buckets.
            let prompt = H.count(row["input_tokens"])
            let reads = min(H.count(row["reads"]), prompt)
            let writes = min(H.count(row["writes"]), prompt - reads)
            var model = H.text(row["model_id"])
            let provider = (H.text(row["provider"]) ?? "").lowercased()
            if let name = model, !name.contains("/"),
               provider.contains("zai") || (provider.isEmpty && name.lowercased().hasPrefix("glm")) {
                model = "z-ai/\(name.lowercased())"
            }
            let entry = H.usage("zcode", key: AgentLogs.pyText(row["id"]), at: H.millis(row["started_at"]), model: model,
                                session: .text(AgentLogs.pyText(row["session_id"])), folder: folder(row["directory"]),
                                counts: .init(input: prompt - reads - writes, cached: reads, cacheWrite: writes,
                                              output: H.count(row["output_tokens"])),
                                total: H.count(row["total"]))
            if let entry, model != nil { result.append(entry) }
        }
        return result
    }

    // MARK: DeepSeek Harness

    static func dshRoots() -> [String] { H.envRoots("DSH_HOME", [home + "/.dsh"]) }

    private static let dshName = try! NSRegularExpression(pattern: #"^session(?:\.v(\d+))?\.jsonl(\.zstd)?$"#)

    /// Only the newest log generation in each session folder: older ones hold the same requests.
    static func dshFiles(_ roots: [String]) -> [String] {
        var newest: [String: ((Int, Bool), String)] = [:]
        for path in H.files(roots, ["sessions/*/*/session*.jsonl", "sessions/*/*/session*.jsonl.zstd"]) {
            let name = H.name(path)
            guard let match = dshName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { continue }
            let version = Range(match.range(at: 1), in: name).flatMap { Int(name[$0]) } ?? 1
            let plain = match.range(at: 2).location == NSNotFound
            let rank = (version, plain)
            let folder = H.parent(path)
            if let known = newest[folder], !(rank.0 > known.0.0 || (rank.0 == known.0.0 && rank.1 && !known.0.1)) { continue }
            newest[folder] = (rank, path)
        }
        return newest.values.map(\.1).sorted(by: Log.pathLess)
    }

    static func dshEntries(_ path: String, _ stats: ImportStats) throws -> [ImportItem] {
        var header: JSON?
        var route: (String?, String?) = (nil, nil)
        var seeded = false
        var found: [(JSON, JSON, (String?, String?))] = []
        for row in try Log.records(path, stats) {
            guard let _ = header else {
                guard row["type"].stringValue == "session" else { return [] }
                header = row
                seeded = Log.truthy(row["isSeeded"])
                continue
            }
            let data = H.obj(row["data"])
            switch row["type"].stringValue {
            case "request/header", "request/context":
                let source = row["type"].stringValue == "request/header" ? H.obj(H.obj(data["header"])["config"]) : data
                if H.text(source["model"]) != nil { route = (H.text(source["provider"]), H.text(source["model"])) }
            case "session/end-seed":
                if Log.truthy(data["inherited"]) {
                    found = []  // everything so far was copied from the parent session
                    seeded = false
                }
            case "assistant/message", "assistant/attempt":
                var record = H.obj(data["usage"])
                if (record.pairs ?? []).isEmpty {
                    for chunk in (data["stream"].arrayValue ?? []).reversed() {
                        let inner = H.obj(H.obj(chunk)["chunk"])
                        if H.obj(chunk)["type"].stringValue == "chunk", inner["type"].stringValue == "usage",
                           !(H.obj(inner["usage"]).pairs ?? []).isEmpty {
                            record = H.obj(inner["usage"])  // the last usage the stream reported
                            break
                        }
                    }
                }
                if !(record.pairs ?? []).isEmpty { found.append((row, record, route)) }
            case "compaction/summary":
                let usage = H.obj(data["usage"])
                if !(usage.pairs ?? []).isEmpty { found.append((row, usage, (H.text(data["provider"]), H.text(data["model"])))) }
            default:
                break
            }
        }
        // A fork's log cut off before its own requests holds only its parent's usage.
        guard let start = header, !seeded else { return [] }
        let session = H.text(start["id"]) ?? H.name(H.parent(path))
        var result: [ImportItem] = []
        for (row, record, (provider, model)) in found {
            var name: String? = model ?? "unknown"
            if let provider, !provider.hasPrefix("deepseek") { name = H.prefixed(provider, name) }
            let key = int(row["seq"]).map { "\(session):\($0)" } ?? H.digest(.string(session), row)
            if let entry = H.usage("dsh", key: key, at: or(H.millis(row["time"]), H.millis(start["createdAt"])), model: name,
                                   session: .text(session), folder: H.text(start["cwd"]),
                                   counts: .init(input: H.pick(record, "inputTokens"), cached: H.pick(record, "cacheReadTokens"),
                                                 cacheWrite: H.pick(record, "cacheWriteTokens"), output: H.pick(record, "outputTokens")),
                                   total: H.pick(record, "totalTokens")) {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: Registry

    static func fileSources() -> [FileSource] {
        var sources: [FileSource] = []
        func add(_ name: String, _ roots: [String], _ read: @escaping (String, ImportStats) throws -> [ImportItem],
                 _ list: @escaping ([String]) -> [String], database: Bool = false) {
            sources.append(FileSource(name: name, directories: roots, read: read, files: { list(roots) }, database: database))
        }
        add("amp", ampRoots().map { $0 + "/threads" }, ampEntries) { H.files($0, ["**/*.json"]) }
        add("droid", droidRoots(), droidEntries) { H.files($0, ["**/*.settings.json"]) }
        add("codebuff", codebuffRoots(), codebuffEntries) { H.files($0, ["projects/*/chats/*/chat-messages.json"]) }
        add("cline", clineRoots(), clineEntries, clineFiles)
        add("pi", piRoots(), piEntries) { H.files($0, ["**/*.jsonl"]) { H.parts($0).contains("subagent-artifacts") } }
        add("openclaw", openclawRoots(), openclawEntries, openclawFiles, database: true)
        add("kimi", kimiRoots(), kimiEntries, kimiFiles)
        add("qwen", qwenRoots(), qwenEntries, qwenFiles)
        add("copilot", copilotRoots(), copilotEntries) { H.files($0, ["session-state/*/events.jsonl"]) }
        add("gemini", geminiRoots(), geminiEntries) { H.files($0, ["*/chats/*.json", "*/chats/*.jsonl"]) }
        add("grok", grokRoots(), grokEntries) { H.files($0, ["sessions/*/*/updates.jsonl"]) }
        add("dsh", dshRoots(), dshEntries, dshFiles)
        add("antigravity", antigravityRoots(), antigravityEntries, { H.files($0, ["*.db"]) }, database: true)
        let databases: [(String, () -> [String], (String, ImportStats) throws -> [ImportItem])] = [
            ("hermes", hermesDatabases, hermesEntries), ("goose", gooseDatabases, gooseEntries),
            ("kilo", kiloDatabases, kiloEntries), ("zcode", zcodeDatabases, zcodeEntries),
        ]
        for (name, list, read) in databases {
            let found = list()
            let roots = Set(found.map(H.parent)).sorted(by: Log.pathLess)
            add(name, roots, read, { _ in found }, database: true)
        }
        return sources
    }
}
