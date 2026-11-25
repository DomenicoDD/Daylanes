import CryptoKit
import Foundation

/// Shared helpers for the agent importers beyond Codex, Claude Code and OpenCode
/// (the top of Python's `tracker/harnesses.py`).
enum H {
    static func home() -> String { AgentLogs.home() }

    /// A tool's data roots: a comma-separated environment variable replaces the defaults.
    static func envRoots(_ variable: String, _ defaults: [String]) -> [String] {
        let configured = AgentLogs.configured(variable)
        return AgentLogs.uniquePaths(configured.isEmpty ? defaults : configured)
    }

    /// A token count: whole numbers (floats truncated) between 0 and 10**12, else 0.
    static func count(_ value: JSON) -> Int {
        switch value {
        case let .int(number): return number >= 0 && number <= 1_000_000_000_000 ? Int(number) : 0
        case let .double(number):
            guard number.isFinite else { return 0 }
            let whole = number.rounded(.towardZero)
            return whole >= 0 && whole <= 1e12 ? Int(whole) : 0
        default: return 0
        }
    }

    static func count(_ value: SQLValue) -> Int { count(value.json) }

    static func pick(_ record: JSON, _ keys: String...) -> Int {
        for key in keys where record.pairs != nil && !record[key].isNull { return count(record[key]) }
        return 0
    }

    /// A nonblank string, stripped (unlike `Log.text`).
    static func text(_ value: JSON) -> String? {
        guard let text = value.stringValue?.pythonStripped, !text.isEmpty else { return nil }
        return text
    }

    static func text(_ value: SQLValue) -> String? { text(value.json) }

    static func obj(_ value: JSON) -> JSON { Log.obj(value) }

    /// A cost in USD the tool recorded: `repr(round(float(value), 10))`, or nil when it isn't one.
    static func cost(_ value: JSON) -> String? {
        if case .bool = value { return nil }
        guard let number = value.doubleValue else { return nil }
        return cost(number)
    }

    static func cost(_ value: SQLValue) -> String? { cost(value.json) }

    static func cost(_ number: Double) -> String? {
        guard number.isFinite, number >= 0, number <= 1_000_000 else { return nil }
        let rounded = Double(String(format: "%.10f", number)) ?? number
        return JSON.pythonFloat(rounded)
    }

    /// A timestamp in whatever form a tool writes it: ISO text, SQLite datetime text, Unix seconds or milliseconds.
    static func millis(_ value: JSON) -> Int? {
        switch value {
        case .null, .bool: return nil
        case let .int(number):
            guard number > 0, number <= 100_000_000_000_000 else { return nil }
            return number < 100_000_000_000 ? Int(number) * 1000 : Int(number)
        case let .double(number):
            guard number.isFinite, number > 0, number <= 1e14 else { return nil }
            return number < 1e11 ? Int(number * 1000) : Int(number)
        case let .string(raw):
            let trimmed = raw.pythonStripped
            guard !trimmed.isEmpty else { return nil }
            if trimmed.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil, !trimmed.contains("\n") {
                guard let number = Double(trimmed) else { return nil }
                return millis(.double(number))
            }
            var normalized = trimmed
            if normalized.hasSuffix("Z") { normalized = String(normalized.dropLast()) + "+00:00" }
            if let space = normalized.firstIndex(of: " ") { normalized.replaceSubrange(space...space, with: "T") }
            return Values.parseAt(normalized, zone: TimeZone(secondsFromGMT: 0)!) ?? Values.parseAt(trimmed, zone: TimeZone(secondsFromGMT: 0)!)
        default:
            return nil
        }
    }

    static func millis(_ value: SQLValue) -> Int? { millis(value.json) }

    /// A file's modification time in milliseconds, as Python computes `int(st_mtime * 1000)`.
    static func mtime(_ path: String) -> Int? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let seconds = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) * 1e-9
        return Int(seconds * 1000)
    }

    /// Python's `str(value)` of a value read from JSON.
    static func pyStr(_ value: JSON) -> String {
        switch value {
        case let .string(text): text
        default: pyRepr(value)
        }
    }

    static func pyRepr(_ value: JSON) -> String {
        switch value {
        case .null: return "None"
        case let .bool(flag): return flag ? "True" : "False"
        case let .int(number): return String(number)
        case let .double(number): return JSON.pythonFloat(number).replacingOccurrences(of: "Infinity", with: "inf")
        case let .string(text):
            let quote: Character = text.contains("'") && !text.contains("\"") ? "\"" : "'"
            var out = String(quote)
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if Character(scalar) == quote { out += "\\" + String(quote) }
                    else if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\x%02x", scalar.value) }
                    else { out.unicodeScalars.append(scalar) }
                }
            }
            return out + String(quote)
        case let .array(items): return "[" + items.map(pyRepr).joined(separator: ", ") + "]"
        case let .object(pairs): return "{" + pairs.map { pyRepr(.string($0.0)) + ": " + pyRepr($0.1) }.joined(separator: ", ") + "}"
        }
    }

    static func sortedKeys(_ value: JSON) -> JSON {
        switch value {
        case let .array(items): .array(items.map(sortedKeys))
        case let .object(pairs): .object(pairs.sorted { Log.pyLess($0.0, $1.0) }.map { ($0.0, sortedKeys($0.1)) })
        default: value
        }
    }

    /// `sha1(json.dumps(parts, sort_keys=True))[:20]`: a stable key for a record without an id of its own.
    static func digest(_ parts: JSON...) -> String {
        let text = sortedKeys(.array(parts)).pythonText(indent: nil, ensureASCII: true)
        return Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    static func optionalInt(_ value: Int?) -> JSON { value.map { .int(Int64($0)) } ?? .null }

    /// Token counts as the JSON object Python's `dict(input=…, …)` would serialise to.
    static func countsJSON(_ pairs: [(String, Int)]) -> JSON { .object(pairs.map { ($0.0, .int(Int64($0.1))) }) }

    struct Counts {
        var input = 0, cached = 0, cacheWrite = 0, output = 0
        var array: [Int] { [input, cached, cacheWrite, output] }
        var any: Bool { array.contains { $0 != 0 } }
    }

    /// One usage entry. Tokens a tool counts in its total but in none of the parts are billed as output.
    static func usage(_ provider: String, key: String, at: Int?, model: String?, session: SQLValue = .null,
                      folder: String? = nil, branch: String? = nil, counts: Counts, reasoning: Int = 0,
                      recorded: String? = nil, extra: Int = 0, total: Int? = nil) -> ImportItem? {
        var counts = counts
        var extra = extra
        let known = counts.array.reduce(0, +) + extra
        if let total, total != 0, total > known { extra += total - known }
        counts.output += extra
        guard let at, counts.any || recorded != nil else { return nil }
        var fields = Log.merged(Log.metadata(provider, session: nil, folder: folder, branch: branch), Log.tokens(counts.array))
        fields["session"] = session
        fields["id"] = .text("harness:\(provider):\(key)")
        fields["kind"] = .text("usage")
        fields["at"] = .integer(Int64(at))
        fields["model"] = .text(model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown")
        fields["prompt_tokens"] = .integer(Int64(counts.input + counts.cached + counts.cacheWrite))
        fields["reasoning"] = .integer(Int64(max(reasoning, extra)))
        fields["recorded_usd"] = recorded.map(SQLValue.text) ?? .null
        return .entry(fields)
    }

    /// Whether an entry kept any tokens (Python's `any(entry[field] for field in TOKENS)`).
    static func hasTokens(_ item: ImportItem) -> Bool {
        guard case let .entry(fields, _) = item else { return false }
        return Log.tokenFields.contains { (fields[$0]?.int ?? 0) != 0 }
    }

    static func session(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }

    // MARK: Files and databases

    static func readJSON(_ path: String) throws -> JSON {
        try JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func sqliteRows(_ path: String, _ query: String, _ parameters: [SQLBindable] = []) throws -> [Row] {
        let db = try Database.readOnly(Values.resolvedPath(path))
        try db.script("BEGIN")
        defer { try? db.script("ROLLBACK") }
        return try db.query(query, parameters)
    }

    static func sqliteTables(_ path: String) throws -> [String: Set<String>] {
        let db = try Database.readOnly(Values.resolvedPath(path))
        try db.script("BEGIN")
        defer { try? db.script("ROLLBACK") }
        var tables: [String: Set<String>] = [:]
        for row in try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") {
            guard let name = row["name"].string else { continue }
            let quoted = name.replacingOccurrences(of: "\"", with: "")
            tables[name] = Set(try db.query("PRAGMA table_info(\"\(quoted)\")").compactMap { $0["name"].string })
        }
        return tables
    }

    /// fnmatch with `*` and `?`, case-sensitive.
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let n = Array(name.unicodeScalars), p = Array(pattern.unicodeScalars)
        var i = 0, j = 0, star = -1, mark = 0
        while i < n.count {
            if j < p.count, p[j] == "?" || p[j] == n[i] && p[j] != "*" {
                i += 1; j += 1
            } else if j < p.count, p[j] == "*" {
                star = j; mark = i; j += 1
            } else if star >= 0 {
                j = star + 1; mark += 1; i = mark
            } else {
                return false
            }
        }
        while j < p.count, p[j] == "*" { j += 1 }
        return j == p.count
    }

    private static func children(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { folder == "/" ? "/" + $0 : folder + "/" + $0 }
    }

    /// Folders below `folder` (itself first), not entering symlinked folders, like `**` in pathlib.
    private static func recursiveFolders(_ folder: String) -> [String] {
        var result = [folder]
        for child in children(folder) {
            var info = stat()
            guard lstat(child, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            result += recursiveFolders(child)
        }
        return result
    }

    /// `Path.glob(pattern)` for patterns of literal, `*`-style and `**` segments.
    static func glob(_ root: String, _ pattern: String) -> [String] {
        var current = [root]
        let segments = pattern.split(separator: "/").map(String.init)
        for (index, segment) in segments.enumerated() {
            let last = index == segments.count - 1
            var next: [String] = []
            for folder in current {
                if segment == "**" {
                    next += recursiveFolders(folder)
                } else if !segment.contains("*") && !segment.contains("?") {
                    let path = folder + "/" + segment
                    if last ? Log.exists(path) : Log.isDirectory(path) { next.append(path) }
                } else {
                    for child in children(folder) where matches((child as NSString).lastPathComponent, segment) {
                        if last || Log.isDirectory(child) { next.append(child) }
                    }
                }
            }
            current = next
        }
        return current
    }

    static func files(_ roots: [String], _ patterns: [String], skip: ((String) -> Bool)? = nil) -> [String] {
        var found = Set<String>()
        for root in roots where Log.isDirectory(root) {
            for pattern in patterns {
                for path in glob(root, pattern) where Log.isRegularFile(path) && !(skip?(path) ?? false) {
                    found.insert(path)
                }
            }
        }
        return found.sorted(by: Log.pathLess)
    }

    static func existing(_ paths: [String]) -> [String] {
        AgentLogs.uniquePaths(paths).filter(Log.isRegularFileFollowing)
    }

    static func stripSuffixes(_ model: String?, _ suffixes: String...) -> String? {
        guard let model else { return nil }
        for suffix in suffixes where model.hasSuffix(suffix) { return String(model.dropLast(suffix.count)) }
        return model
    }

    /// Qualify a bare model name with the provider an agent logged, so the price lookup finds it.
    static func prefixed(_ provider: String?, _ model: String?, ignore: [String] = []) -> String? {
        if let model, !model.isEmpty, let provider, !provider.isEmpty, !model.contains("/"), !ignore.contains(provider.lowercased()) {
            return "\(provider.lowercased())/\(model)"
        }
        return model
    }

    static func name(_ path: String) -> String { path == "/" ? "" : (path as NSString).lastPathComponent }
    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    /// `Path.stem`: the name without its last suffix.
    static func stem(_ path: String) -> String {
        let name = self.name(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
    static func suffix(_ path: String) -> String {
        let name = self.name(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[dot...])
    }
    static func parts(_ path: String) -> [String] { ["/"] + path.split(separator: "/").map(String.init) }
}
