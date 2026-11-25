import Foundation

/// `sync`: reads every agent's local history into the ledger (Python's `importers.sync`).
enum Sync {
    /// Raise when an importer change should apply to history already imported: the next full sync reads
    /// every log again, once. Keep equal to IMPORTER_VERSION in tracker/importers.py.
    static let importerVersion = 3

    static let providers = ["codex", "claude", "opencode", "amp", "droid", "codebuff", "cline", "hermes", "pi", "openclaw",
                            "goose", "kilo", "kimi", "qwen", "copilot", "gemini", "antigravity", "grok", "zcode", "dsh"]

    static func fileSources(codex: String?, claude: String?) -> [FileSource] {
        let found = AgentLogs.roots(codex: codex, claude: claude)
        return [
            FileSource(name: "codex", directories: found["codex"] ?? [], read: { path, stats in
                AgentLogs.codexEntries(try Log.records(path, stats), fileID: Log.transcriptID(path))
            }),
            FileSource(name: "claude", directories: found["claude"] ?? [], read: { path, stats in
                AgentLogs.claudeEntries(try Log.records(path, stats), fileID: Log.transcriptID(path))
            }),
        ] + Harnesses.fileSources()
    }

    static func store(_ db: Database, _ items: [ImportItem]) throws {
        for item in items {
            switch item {
            case let .remove(id):
                try db.execute("DELETE FROM entries WHERE id = ?", [id])
            case let .limits(provider, limits):
                try rememberLimits(db, provider: provider, limits: limits)
            case let .entry(fields, inherit):
                var entry = fields
                if let inherit, let assigned = try db.first("SELECT project FROM entries WHERE id = ?", [inherit])?["project"],
                   let project = assigned.string, !project.isEmpty {
                    entry["project"] = .text(project)
                }
                try Store.addEntry(db, entry, refresh: true)
            }
        }
    }

    /// Keeps the newest plan-limit snapshot a tool logged.
    static func rememberLimits(_ db: Database, provider: String, limits: JSON) throws {
        let key = "\(provider)_rate_limits"
        let previous = (try? JSON.parse(try Store.setting(db, key, "{}"))) ?? .object([])
        let newer = limits["observed_at"].doubleValue ?? 0
        if newer >= (previous["observed_at"].doubleValue ?? 0) {
            try Store.setSetting(db, key, limits.pythonText(indent: nil, ensureASCII: true))
        }
    }

    /// A response copied into another log (a Claude subagent replaying its parent's messages) counts once.
    static func dropReplicas(_ db: Database) throws {
        try db.execute(
            "DELETE FROM entries WHERE replica = 1 AND dedupe_key IS NOT NULL AND EXISTS ("
            + "SELECT 1 FROM entries AS original WHERE original.dedupe_key = entries.dedupe_key "
            + "AND original.provider = entries.provider AND original.replica = 0 AND original.id <> entries.id)")
    }

    static func isMissingOrDenied(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError {
            return [.fileNoSuchFile, .fileReadNoSuchFile, .fileReadNoPermission].contains(cocoa.code)
        }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(EACCES), Int(EPERM)].contains(ns.code)
    }

    static func run(_ db: Database, provider: String = "all", codex: String? = nil, claude: String? = nil,
                    recentDays: Int? = nil, opencode: String? = nil, rescan: Bool = false) throws -> JSON {
        if let recentDays, recentDays < 1 { throw EngineError.invalid("Recent days must be positive") }
        let modifiedSince = recentDays.map { Date().timeIntervalSince1970 - Double($0) * 86400 } ?? 0
        let stats = ImportStats()
        try db.beginImmediate()
        let upgrade = (Int(try Store.setting(db, "importer_version", "1")) ?? 1) < importerVersion
            && provider == "all" && recentDays == nil
        // A rescan reads every file again, to apply importer improvements to history already imported.
        let everything = rescan || upgrade
        var cached: [String: String] = [:]
        if !everything {
            for row in try db.query("SELECT * FROM sources") {
                if let path = row["path"].string, let signature = row["signature"].string { cached[path] = signature }
            }
        }
        for source in fileSources(codex: codex, claude: claude) where provider == "all" || provider == source.name {
            stats.setDirectories(source.name, source.directories.filter(Log.exists))
            for path in source.list() {
                let key = "\(source.name):\(Values.resolvedPath(path))"
                let before: String
                let items: [ImportItem]
                do {
                    if try Log.modified(path) < modifiedSince {
                        stats.filesOutsideWindow += 1
                        continue
                    }
                    before = try source.signature(path)
                    if before == cached[key] {
                        stats.filesUnchanged += 1
                        continue
                    }
                    // Foundation hands back decoded logs autoreleased: drain them after each file, or a
                    // command-line sync keeps every log it read alive until it exits.
                    items = try autoreleasepool { try source.read(path, stats) }
                    if try source.signature(path) != before {
                        stats.filesDeferred += 1
                        continue
                    }
                } catch where isMissingOrDenied(error) {
                    stats.filesDeferred += 1
                    continue
                } catch let error as UnreadableSource {
                    stats.filesDeferred += 1
                    if stats.sourceErrors.count < 20 { stats.sourceErrors.append("\(source.name): \(error.description)") }
                    continue
                } catch let error as EngineError {
                    stats.filesDeferred += 1
                    if stats.sourceErrors.count < 20 { stats.sourceErrors.append("\(source.name): \(error.message)") }
                    continue
                } catch let error as SQLiteError {
                    stats.filesDeferred += 1
                    if stats.sourceErrors.count < 20 { stats.sourceErrors.append("\(source.name): \(error.message)") }
                    continue
                } catch {
                    if source.name == "codex" || source.name == "claude" { throw error }
                    stats.filesDeferred += 1
                    if stats.sourceErrors.count < 20 {
                        stats.sourceErrors.append("\(source.name): \((path as NSString).lastPathComponent): \(type(of: error)): \(error)")
                    }
                    continue
                }
                try store(db, items)
                try db.execute("INSERT OR REPLACE INTO sources VALUES (?, ?)", [key, before])
                stats.filesRead += 1
                stats.eventsProcessed += items.count
                cached[key] = before
            }
        }
        if provider == "all" || provider == "opencode" {
            try AgentLogs.syncOpenCode(db, stats, path: opencode, since: Int(modifiedSince * 1000))
        }
        try dropReplicas(db)
        if upgrade { try Store.setSetting(db, "importer_version", String(importerVersion)) }
        return stats.json
    }
}
