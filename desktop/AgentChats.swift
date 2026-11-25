import Foundation

struct AgentChat: Decodable, Identifiable {
    let id: String
    let lastAt: Double
    var title: String?
    var sourceContext: String?
    var claudeDesktopID: String?

    var menuTitle: String {
        let date = Date(timeIntervalSince1970: lastAt / 1000).formatted(date: .abbreviated, time: .shortened)
        return [title, sourceContext, date].compactMap { $0 }.joined(separator: " · ")
    }

    func url(provider: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        switch provider {
        case "codex":
            return URL(string: "codex://threads/\(id)")
        case "claude":
            var url = URLComponents()
            url.scheme = "claude"
            url.host = claudeDesktopID == nil ? "resume" : "code"
            if claudeDesktopID != nil { url.path = "/continue" }
            url.queryItems = [URLQueryItem(name: "session", value: claudeDesktopID ?? id)]
            return url.url
        default:
            return nil
        }
    }
}

/// Reads optional metadata from the installed agents. The ledger still owns activity and assignment.
enum AgentChatMetadata {
    private struct Details {
        var title: String?
        var context: String?
        var claudeDesktopID: String?
    }

    static func enrich(_ activities: inout [Activity]) {
        func ids(for provider: String) -> Set<String> {
            Set(activities.filter { $0.provider == provider }.flatMap { ($0.sessions ?? []).map(\.id) })
        }
        let codex = codexDetails(ids: ids(for: "codex"))
        let claude = claudeDetails(ids: ids(for: "claude"))
        for index in activities.indices {
            let activity = activities[index]
            let details = activity.provider == "codex" ? codex : claude
            activities[index].sessions = activity.sessions?.map { session in
                var chat = session
                let detail = details[session.id]
                chat.title = detail?.title.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.nonEmpty
                chat.sourceContext = detail?.context
                chat.claudeDesktopID = detail?.claudeDesktopID
                return chat
            }
        }
    }

    private static func codexDetails(ids: Set<String>) -> [String: Details] {
        guard !ids.isEmpty else { return [:] }
        var details: [String: Details] = [:]
        for home in AgentLogs.codexHomes() {
            let state = readJSON(home + "/.codex-global-state.json") ?? .null
            let titles = state["thread-titles"]["titles"]
            let assignments = state["thread-project-assignments"]
            let projects = state["local-projects"]
            var threads: [String: (title: String?, project: String?, section: String?)] = [:]
            // Recent Codex versions can store project and section names in their state database.
            // The desktop state also carries sidebar assignments and title overrides.
            if let db = try? Database.readOnly(home + "/state_5.sqlite", timeout: 0.1) {
                let rows = (try? db.query("""
                    SELECT threads.id, COALESCE(NULLIF(threads.name, ''), threads.title) AS title,
                           projects.name AS project, thread_sections.name AS section
                    FROM threads LEFT JOIN projects ON projects.id = threads.project_id
                    LEFT JOIN thread_sections ON thread_sections.id = threads.thread_section_id
                    """)) ?? (try? db.query("SELECT id, title FROM threads")) ?? []
                for row in rows {
                    guard let id = row["id"].string, ids.contains(id) else { continue }
                    threads[id] = (row["title"].string.nonEmpty, row["project"].string.nonEmpty,
                                   row["section"].string.nonEmpty)
                }
            }
            if let index = try? String(contentsOfFile: home + "/session_index.jsonl", encoding: .utf8) {
                for line in index.split(separator: "\n") {
                    guard let row = try? JSON.parse(String(line)), let id = row["id"].stringValue,
                          ids.contains(id), let title = row["thread_name"].stringValue.nonEmpty else { continue }
                    threads[id, default: (nil, nil, nil)].title = title
                }
            }
            for id in ids {
                let project = assignments[id]["projectId"].stringValue.flatMap { projects[$0]["name"].stringValue.nonEmpty }
                let title = titles[id].stringValue.nonEmpty ?? threads[id]?.title
                let context = [threads[id]?.project ?? project, threads[id]?.section].compactMap { $0 }
                    .joined(separator: " / ").nonEmptyString
                if details[id] == nil, title != nil || context != nil {
                    details[id] = Details(title: title, context: context)
                }
            }
        }
        return details
    }

    private static func claudeDetails(ids: Set<String>) -> [String: Details] {
        guard !ids.isEmpty else { return [:] }
        let root = AgentLogs.home() + "/Library/Application Support/Claude/claude-code-sessions"
        guard let files = FileManager.default.enumerator(atPath: root) else { return [:] }
        var matches: [String: (details: Details, updated: Double)] = [:]
        for case let file as String in files {
            let name = URL(fileURLWithPath: file).lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json"), let row = readJSON(root + "/" + file),
                  let desktopID = row["sessionId"].stringValue, desktopID.hasPrefix("local_"),
                  UUID(uuidString: String(desktopID.dropFirst("local_".count))) != nil else { continue }
            let sessionIDs = [row["cliSessionId"]] + (row["previousCliSessionIds"].arrayValue ?? [])
            let folder = row["originCwd"].stringValue.nonEmpty ?? row["cwd"].stringValue.nonEmpty
            let detail = Details(title: row["title"].stringValue.nonEmpty,
                                 context: folder.map { URL(fileURLWithPath: $0).lastPathComponent },
                                 claudeDesktopID: row["isArchived"] == .bool(true) ? nil : desktopID)
            let updated = row["lastActivityAt"].doubleValue ?? 0
            for case let id? in sessionIDs.map(\.stringValue) where ids.contains(id) {
                if let match = matches[id], match.updated >= updated { continue }
                matches[id] = (detail, updated)
            }
        }
        return matches.mapValues(\.details)
    }

    private static func readJSON(_ path: String) -> JSON? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSON.parse(data)
    }
}
