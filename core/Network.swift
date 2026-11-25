import Foundation

/// A message for the caller, raised inside a network source before it is reported (Python's `ValueError`).
private struct Problem: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

func fullMatch(_ pattern: String, _ text: String) -> Bool {
    text.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
}

extension JSON {
    /// Python truthiness of a JSON value.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case let .bool(value): value
        case let .int(value): value != 0
        case let .double(value): value != 0
        case let .string(value): !value.isEmpty
        case let .array(values): !values.isEmpty
        case let .object(pairs): !pairs.isEmpty
        }
    }

    /// Python's `str(value)` for a value from `json.loads`.
    var pythonString: String {
        if case let .string(value) = self { return value }
        return reprText
    }

    /// Python's `repr(value)` for a value from `json.loads`.
    var reprText: String {
        switch self {
        case .null: return "None"
        case let .bool(value): return value ? "True" : "False"
        case let .int(value): return String(value)
        case let .double(value): return JSON.pythonFloat(value)
        case let .string(value):
            let quote = value.contains("'") && !value.contains("\"") ? "\"" : "'"
            var out = quote
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if String(scalar) == quote { out += "\\" + quote }
                    else if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\x%02x", scalar.value) }
                    else { out.unicodeScalars.append(scalar) }
                }
            }
            return out + quote
        case let .array(values): return "[" + values.map(\.reprText).joined(separator: ", ") + "]"
        case let .object(pairs):
            return "{" + pairs.map { JSON.string($0.0).reprText + ": " + $0.1.reprText }.joined(separator: ", ") + "}"
        }
    }

    /// Sets `key`, in place when it exists and at the end otherwise (a Python dict assignment).
    func setting(_ key: String, _ value: JSON) -> JSON {
        guard case var .object(pairs) = self else { return self }
        if let index = pairs.firstIndex(where: { $0.0 == key }) { pairs[index].1 = value } else { pairs.append((key, value)) }
        return .object(pairs)
    }
}

/// Upserts into an ordered list of pairs the way a Python dict assignment does: a known key keeps its place.
private func upsert<Key: Equatable, Value>(_ pairs: inout [(Key, Value)], _ key: Key, _ value: Value) {
    if let index = pairs.firstIndex(where: { $0.0 == key }) { pairs[index].1 = value } else { pairs.append((key, value)) }
}

// MARK: - OpenRouter catalog

/// Public OpenRouter token prices, cached in the ledger (Python's `pricing.refresh`).
enum Prices {
    static let url = "https://openrouter.ai/api/v1/models"
    static let cacheKey = "openrouter_catalog"
    static let rateFields: [(String, String)] = [
        ("input", "prompt"), ("cached", "input_cache_read"), ("cache_write", "input_cache_write"),
        ("cache_write_1h", "input_cache_write_1h"), ("output", "completion"), ("web_search", "web_search"),
    ]
    /// A 1-hour cache write costs twice the input rate on Anthropic models when the catalog has no own rate.
    static let oneHourWrite: [String: PyDecimal] = ["anthropic": PyDecimal(2)]
    static let limit = 8 * 1024 * 1024

    /// Python's `pricing.rate`: `str(Decimal(str(raw)))` for a finite value from 0 to 100, else nil.
    static func rate(_ raw: JSON) -> String? {
        let text: String
        switch raw {
        case let .string(value): text = value
        case let .int(value): text = String(value)
        case let .double(value): text = JSON.pythonFloat(value)
        default: return nil
        }
        guard let value = PyDecimal(text), !(value < .zero), !(PyDecimal(100) < value) else { return nil }
        return value.description
    }

    private static func rates(_ prices: JSON) -> [(String, String?)] {
        rateFields.map { ($0.0, rate(prices[$0.1])) }
    }

    private static func ratesJSON(_ rates: [(String, String?)]) -> JSON {
        .object(rates.map { ($0.0, JSON.optional($0.1)) })
    }

    /// Long-context prices: overrides that apply once a request's prompt reaches `min_prompt_tokens`.
    static func tiers(_ overrides: JSON, base: [(String, String?)], multiplier: PyDecimal?) -> JSON {
        var found: [(Int, Int, JSON)] = []
        for override in overrides.arrayValue ?? [] {
            guard override.pairs != nil, case let .int(threshold) = override["min_prompt_tokens"], threshold > 0 else { continue }
            var values = rates(override)
            guard values.contains(where: { $0.1 != nil }) else { continue }
            if let index = values.firstIndex(where: { $0.0 == "cache_write_1h" }), values[index].1 == nil,
               let input = values.first(where: { $0.0 == "input" })?.1, let multiplier, let decimal = PyDecimal(input) {
                values[index].1 = (decimal * multiplier).description
            }
            let filled = values.enumerated().map { index, pair in (pair.0, pair.1 ?? base[index].1) }
            found.append((Int(threshold), found.count,
                          .object([("min_prompt_tokens", .int(threshold)), ("rates", ratesJSON(filled))])))
        }
        found.sort { ($0.0, $0.1) < ($1.0, $1.1) }   // Python's sort is stable
        return .array(found.map(\.2))
    }

    private static func fetchModels() throws -> JSON {
        let response: HTTP.Response
        do {
            response = try HTTP.send(url, headers: ["Accept": "application/json"], timeout: 8, limit: limit, redirects: true)
        } catch HTTP.Failure.tooLarge {
            throw Problem("Catalog exceeds the size limit")
        } catch let failure as HTTP.Failure {
            throw Problem(failure.pythonText)
        }
        let parsed: JSON
        do {
            parsed = try JSON.parse(response.body)
        } catch let error as EngineError {
            throw Problem(error.message)
        }
        guard let pairs = parsed.pairs else {
            throw Problem(parsed.arrayValue != nil ? "list indices must be integers or slices, not str"
                                                   : "'\(parsed.pythonTypeName)' object is not subscriptable")
        }
        guard let data = pairs.first(where: { $0.0 == "data" })?.1 else { throw Problem("'data'") }
        return data
    }

    static func refresh(_ db: Database, ifStale: Bool, now: Int) throws -> JSON {
        if ifStale {
            let previous = try JSON.parse(try Store.setting(db, cacheKey, #"{"models": {}}"#))
            let fetched = previous.pairs?.first(where: { $0.0 == "fetched_at" })?.1.intValue ?? 0
            if (0..<86400).contains(now - fetched) {
                return .object([("models", .int(Int64(previous["models"].pairs?.count ?? 0))),
                                ("fetched_at", previous["fetched_at"]), ("refreshed", .bool(false))])
            }
        }
        var models: [(String, JSON)] = []
        do {
            guard let rows = try fetchModels().arrayValue else { throw Problem("Invalid catalog") }
            for row in rows {
                guard row.pairs != nil, let model = row["id"].stringValue, fullMatch(#"[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._:-]*"#, model),
                      row["pricing"].pairs != nil else { continue }
                let prices = row["pricing"]
                var values = rates(prices)
                guard let input = values[0].1, values[4].1 != nil else { continue }
                let namespace = String(model.prefix { $0 != "/" })
                if values[3].1 == nil, let multiplier = oneHourWrite[namespace], let decimal = PyDecimal(input) {
                    values[3].1 = (decimal * multiplier).description
                }
                let canonical = row["canonical_slug"].stringValue
                upsert(&models, model, .object([
                    ("rates", ratesJSON(values)), ("canonical", JSON.optional(canonical)),
                    ("tiers", tiers(prices["overrides"], base: values, multiplier: oneHourWrite[namespace])),
                ]))
            }
            if models.isEmpty { throw Problem("No token rates found") }
        } catch let problem as Problem {
            throw EngineError.invalid("Could not refresh OpenRouter prices: \(problem.message)")
        }
        let cache = JSON.object([("fetched_at", .int(Int64(now))), ("models", .object(models))])
        try Store.setSetting(db, cacheKey, cache.pythonText(indent: nil, ensureASCII: true))
        return .object([("models", .int(Int64(models.count))), ("fetched_at", .int(Int64(now))), ("refreshed", .bool(true))])
    }
}

extension JSON {
    /// Python's type name for a value from `json.loads`.
    var pythonTypeName: String {
        switch self {
        case .null: "NoneType"
        case .bool: "bool"
        case .int: "int"
        case .double: "float"
        case .string: "str"
        case .array: "list"
        case .object: "dict"
        }
    }
}

// MARK: - OpenRouter account activity

/// Account activity from OpenRouter's completed UTC days (Python's `tracker/openrouter.py`).
enum OpenRouterActivity {
    static let url = "https://openrouter.ai/api/v1/activity"
    static let cacheKey = "openrouter_account_activity"
    static let limit = 8 * 1024 * 1024
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let maximum = PyDecimal(1_000_000_000_000)

    struct Row {
        let day: String
        let model: String
        let requests: Int
        let tokens: Int
        let spend: PyDecimal
    }

    static func fetch(_ key: String) throws -> [JSON] {
        let key = key.pythonStripped
        guard fullMatch("[a-zA-Z0-9_-]{1,512}", key) else { throw EngineError.invalid("Enter an OpenRouter management key") }
        let response: HTTP.Response
        do {
            response = try HTTP.send(url, headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
                                     timeout: 8, limit: limit, redirects: false)
        } catch HTTP.Failure.status(let code, _) {
            if code == 401 || code == 403 {
                throw EngineError.invalid("OpenRouter denied access. Use a valid management key with activity access.")
            }
            throw EngineError.invalid("OpenRouter activity request failed (HTTP \(code)).")
        } catch HTTP.Failure.tooLarge {
            throw EngineError.invalid("OpenRouter activity response exceeded the size limit.")
        } catch {
            throw EngineError.invalid("Could not reach OpenRouter to refresh account activity.")
        }
        guard let parsed = try? JSON.parse(bytes: [UInt8](response.body), decimalFloats: true),
              let rows = parsed.pairs?.first(where: { $0.0 == "data" })?.1.arrayValue else {
            throw EngineError.invalid("OpenRouter returned an unreadable activity response.")
        }
        return rows
    }

    private static func decimal(_ value: JSON) -> PyDecimal? {
        let raw = value.decimalText ?? value.stringValue ?? value.intValue.map(String.init)
        guard let raw, raw.utf8.count <= 128, let number = PyDecimal(raw),
              (-128...128).contains(number.exponent), (.zero...maximum).contains(number) else { return nil }
        return number
    }

    private static func count(_ value: JSON) -> Int? {
        guard let number = decimal(value) else { return nil }
        let integer = number.truncated
        return number == PyDecimal(integer) ? integer : nil
    }

    private static func day(_ value: JSON) -> String? {
        guard let date = value.stringValue, date.utf8.count <= 40,
              date.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        if let day = try? Day.parse(date) { return day.iso }
        guard date.utf8.count > 10, let stamp = Values.parseAt(date, zone: utc) else { return nil }
        return Day.local(stamp, utc).iso
    }

    static func decodeRows(_ rows: [JSON], start: String, end: String) throws -> [Row] {
        try rows.enumerated().compactMap { index, row in
            func invalid(_ field: String) -> EngineError {
                .invalid("OpenRouter returned an invalid activity row (row \(index + 1), \(field)).")
            }
            guard let date = day(row["date"]) else { throw invalid("date") }
            guard start <= date, date < end else { return nil }
            guard let requests = count(row["requests"]) else { throw invalid("requests") }
            guard let prompt = count(row["prompt_tokens"]) else { throw invalid("prompt_tokens") }
            guard let output = count(row["completion_tokens"]) else { throw invalid("completion_tokens") }
            guard let spend = decimal(row["usage"]) else { throw invalid("usage") }
            let model = ["model", "model_permaslug"].lazy.compactMap { row[$0].stringValue?.pythonStripped }
                .first { !$0.isEmpty && $0.unicodeScalars.count <= 256 && !$0.contains("\u{0}") } ?? "Unknown model"
            // Completion already includes reasoning and prompt already includes cache hits.
            return Row(day: date, model: model, requests: requests, tokens: prompt + output, spend: spend)
        }
    }

    static func refresh(_ db: Database, key: String, now: Int) throws -> JSON {
        let end = Day.local(now, utc)
        let start = end.adding(days: -30)
        var groups: [(String, (requests: Int, tokens: Int, spend: PyDecimal))] = []
        for row in try decodeRows(fetch(key), start: start.iso, end: end.iso) {
            let group = row.day + "\u{0}" + row.model
            if let index = groups.firstIndex(where: { $0.0 == group }) {
                groups[index].1.requests += row.requests
                groups[index].1.tokens += row.tokens
                groups[index].1.spend += row.spend
            } else {
                groups.append((group, (row.requests, row.tokens, PyDecimal.zero + row.spend)))
            }
        }
        let records: [JSON] = groups.map { group, value in
            let parts = group.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return .object([("day", .string(parts[0])), ("model", .string(parts[1])), ("requests", .int(Int64(value.requests))),
                            ("tokens", .int(Int64(value.tokens))), ("spend_usd", .string(value.spend.description))])
        }
        let cache = JSON.object([("start", .string(start.iso)), ("end_exclusive", .string(end.iso)),
                                 ("fetched_at", .int(Int64(now.floorDivided(by: 1000)))), ("records", .array(records))])
        try Store.setSetting(db, cacheKey, cache.pythonText(indent: nil, ensureASCII: true))
        return .object([("days", .int(30)), ("groups", .int(Int64(records.count)))])
    }

    static func clear(_ db: Database) throws {
        try db.execute("DELETE FROM settings WHERE key = ?", [cacheKey])
    }
}

private extension Int {
    func floorDivided(by divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}

// MARK: - Toggl Track

/// Read-only Toggl Track imports for the local ledger (Python's `tracker/toggl.py`).
enum Toggl {
    static let baseURL = "https://api.track.toggl.com/api/v9"
    static let reportsURL = "https://api.track.toggl.com/reports/api/v3"
    static let limit = 8 * 1024 * 1024
    static let entryLimit = 1000

    /// The requested dates are older than Toggl's time entry API allows; detailed reports still have them.
    struct HistoryDateLimit: Error {}

    static func requestJSON(_ key: String, _ url: String, payload: JSON? = nil) throws -> (JSON, [String: String]) {
        let key = key.pythonStripped
        guard fullMatch("[!-~]{1,512}", key), !key.contains(":") else { throw EngineError.invalid("Enter a Toggl Track API token.") }
        let auth = Data((key + ":api_token").utf8).base64EncodedString()
        var headers = ["Authorization": "Basic " + auth, "Accept": "application/json"]
        var body: Data?
        if let payload {
            headers["Content-Type"] = "application/json"
            body = Data(payload.pythonText(indent: nil, ensureASCII: true).utf8)
        }
        let response: HTTP.Response
        do {
            response = try HTTP.send(url, method: body == nil ? "GET" : "POST", headers: headers, body: body,
                                     timeout: 12, limit: limit, redirects: false)
        } catch HTTP.Failure.status(let code, let detail) {
            if code == 400, url.hasPrefix(baseURL + "/me/time_entries?") {
                let text = String(decoding: detail.prefix(1024), as: UTF8.self)
                if text.range(of: #"start_date must not be earlier than \d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                    throw HistoryDateLimit()
                }
            }
            if code == 403, url.hasPrefix(reportsURL + "/") {
                throw EngineError.invalid("Toggl Track denied access to detailed reports for this workspace.")
            }
            if code == 401 || code == 403 {
                throw EngineError.invalid("Toggl Track denied access. Check the API token in your Toggl Track profile.")
            }
            throw EngineError.invalid("Toggl Track request failed (HTTP \(code)).")
        } catch HTTP.Failure.tooLarge {
            throw EngineError.invalid("Toggl Track response exceeded the size limit.")
        } catch {
            throw EngineError.invalid("Could not reach Toggl Track. Check your connection and try again.")
        }
        guard let parsed = try? JSON.parse(response.body) else {
            throw EngineError.invalid("Toggl Track returned an unreadable response.")
        }
        return (parsed, response.headers)
    }

    static func fetch(_ key: String, _ path: String, _ params: [(String, String)]) throws -> JSON {
        let suffix = params.isEmpty ? "" : "?" + HTTP.query(params)
        return try requestJSON(key, baseURL + path + suffix).0
    }

    static func projects(_ key: String) throws -> JSON {
        var rows = try fetch(key, "/me/projects", [("include_archived", "true")])
        if rows.pairs != nil { rows = rows["items"] }
        guard let list = rows.arrayValue else { throw EngineError.invalid("Toggl Track returned an invalid project list.") }
        var result: [(archived: Bool, name: String, id: Int, row: JSON)] = []
        for row in list {
            guard row.pairs != nil, case let .int(number) = row["id"], number > 0, let raw = row["name"].stringValue,
                  let name = try? Values.required(raw, "Project") else {
                throw EngineError.invalid("Toggl Track returned an invalid project.")
            }
            let archived = row["active"] == .bool(false)
            let workspace = row["workspace_id"].isTruthy ? row["workspace_id"] : row["wid"]
            result.append((archived, name, Int(number), .object([
                ("id", .int(number)), ("name", .string(name)), ("archived", .bool(archived)), ("workspace_id", workspace),
            ])))
        }
        let sorted = result.enumerated().sorted { a, b in
            if a.element.archived != b.element.archived { return !a.element.archived }
            let left = Reports.casefold(a.element.name), right = Reports.casefold(b.element.name)
            if left != right { return Array(left.unicodeScalars.map(\.value)).lexicographicallyPrecedes(right.unicodeScalars.map(\.value)) }
            if a.element.id != b.element.id { return a.element.id < b.element.id }
            return a.offset < b.offset
        }
        return .array(sorted.map(\.element.row))
    }

    /// Verifies a token and describes the account: name, email and workspaces. Nothing secret is returned.
    static func account(_ key: String) throws -> JSON {
        let me = try fetch(key, "/me", [])
        let spaces = try fetch(key, "/me/workspaces", [])
        guard me.pairs != nil, let list = spaces.arrayValue else { throw EngineError.invalid("Toggl Track returned an unreadable account.") }
        var workspaces: [JSON] = []
        for row in list {
            guard row.pairs != nil, case let .int(id) = row["id"] else { continue }
            let name = row["name"].isTruthy ? row["name"].pythonString : "Workspace \(id)"
            workspaces.append(.object([("id", .int(id)), ("name", .string(name))]))
        }
        if workspaces.isEmpty { throw EngineError.invalid("This Toggl Track account has no workspaces.") }
        func text(_ field: String) -> String { me[field].isTruthy ? me[field].pythonString : "" }
        return .object([("name", .string(text("fullname"))), ("email", .string(text("email"))),
                        ("default_workspace_id", me["default_workspace_id"]), ("workspaces", .array(workspaces))])
    }

    /// Verifies the token and remembers who is connected and which workspace Tracker reads.
    static func link(_ db: Database, key: String, workspace: Int?) throws -> JSON {
        var details = try account(key)
        let ids = (details["workspaces"].arrayValue ?? []).map { $0["id"] }
        var chosen = workspace.map { JSON.int(Int64($0)) } ?? details["default_workspace_id"]
        if !ids.contains(chosen) { chosen = ids[0] }
        details = details.setting("workspace_id", chosen)
        try Store.setSetting(db, "toggl_account", details.pythonText(indent: nil, ensureASCII: true))
        return details
    }

    static func linked(_ db: Database) throws -> JSON? {
        guard let value = try Store.setting(db, "toggl_account"), !value.isEmpty else { return nil }
        return try? JSON.parse(value)
    }

    static func chooseWorkspace(_ db: Database, _ workspace: Int) throws -> JSON {
        guard let details = try linked(db) else { throw EngineError.invalid("Connect Toggl Track first.") }
        let ids = (details["workspaces"].arrayValue ?? []).map { $0["id"] }
        guard ids.contains(.int(Int64(workspace))) else { throw EngineError.invalid("Choose one of this account's workspaces.") }
        let updated = details.setting("workspace_id", .int(Int64(workspace)))
        try Store.setSetting(db, "toggl_account", updated.pythonText(indent: nil, ensureASCII: true))
        return updated
    }

    static func unlink(_ db: Database) throws {
        try db.execute("DELETE FROM settings WHERE key = 'toggl_account'")
    }

    /// `datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(timespec="milliseconds")`.
    static func utcStamp(_ millis: Int) -> String {
        let day = Day.local(millis, TimeZone(secondsFromGMT: 0)!)
        var rest = millis % 86_400_000
        if rest < 0 { rest += 86_400_000 }
        let hours = rest / 3_600_000, minutes = rest / 60_000 % 60, seconds = rest / 1000 % 60, fraction = rest % 1000
        return day.iso + String(format: "T%02d:%02d:%02d.%03d+00:00", hours, minutes, seconds, fraction)
    }

    static func history(_ key: String, _ start: Int, _ end: Int) throws -> [JSON] {
        let rows = try fetch(key, "/me/time_entries", [("start_date", utcStamp(start)), ("end_date", utcStamp(end))])
        guard let list = rows.arrayValue else { throw EngineError.invalid("Toggl Track returned an invalid time entry list.") }
        guard list.count >= entryLimit else { return list }
        if end - start <= 60_000 {
            throw EngineError.invalid("Toggl Track returned too many entries in one minute to safely import.")
        }
        let middle = (start + end).floorDivided(by: 2)
        return try history(key, start, middle) + history(key, middle, end)
    }

    /// Older dates come from the detailed report of the project's workspace, page by page; `visit` sees each
    /// entry as soon as its page arrives, like the Python generator.
    static func reportHistory(_ key: String, source: Int, account: Int, first: Day, last: Day,
                              visit: (JSON) throws -> Void) throws {
        let listed = try projects(key).arrayValue ?? []
        let found = listed.first(where: { $0["id"] == .int(Int64(source)) })?["workspace_id"]
        guard case let .int(workspace)? = found, workspace > 0 else {
            throw EngineError.invalid("Toggl Track could not find the workspace for this project.")
        }
        let url = "\(reportsURL)/workspace/\(workspace)/search/time_entries"
        // Report dates use the Toggl profile's timezone. The ledger window is enforced on each timestamp later.
        var payload = JSON.object([
            ("start_date", .string(first.adding(days: -2).iso)), ("end_date", .string(last.adding(days: 1).iso)),
            ("user_ids", .array([.int(Int64(account))])), ("project_ids", .array([.int(Int64(source))])),
            ("grouped", .bool(false)), ("hide_amounts", .bool(true)), ("page_size", .int(100)),
        ])
        let cursorFields = [("x-next-id", "first_id"), ("x-next-row-number", "first_row_number"),
                            ("x-next-timestamp", "first_timestamp")]
        var seen: Set<String> = []
        while true {
            let (rows, headers) = try requestJSON(key, url, payload: payload)
            guard let list = rows.arrayValue else { throw EngineError.invalid("Toggl Track returned an invalid detailed report.") }
            for row in list {
                guard row.pairs != nil else { throw EngineError.invalid("Toggl Track returned an invalid detailed report row.") }
                if row["user_id"] != .int(Int64(account)) || row["project_id"] != .int(Int64(source)) { continue }
                guard let items = row["time_entries"].arrayValue, items.allSatisfy({ $0.pairs != nil }) else {
                    throw EngineError.invalid("Toggl Track returned invalid detailed report entries.")
                }
                for item in items {
                    try visit(item.setting("project_id", .int(Int64(source))).setting("duration", item["seconds"]))
                }
            }
            var cursor: [(String, Int)] = []
            for (header, field) in cursorFields {
                guard let value = headers[header] else { continue }
                guard let number = pythonInt(value) else {
                    throw EngineError.invalid("Toggl Track returned an invalid detailed report page cursor.")
                }
                cursor.append((field, number))
            }
            if cursor.isEmpty { return }
            let position = cursor.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
            if seen.contains(position) { throw EngineError.invalid("Toggl Track returned a repeated detailed report page cursor.") }
            seen.insert(position)
            if case let .object(pairs) = payload {
                payload = .object(pairs.filter { pair in !cursorFields.contains { $0.1 == pair.0 } }
                                  + cursor.map { ($0.0, JSON.int(Int64($0.1))) })
            }
        }
    }

    /// Python's `int(text)` for a header value: surrounding whitespace, a sign and underscores between digits.
    static func pythonInt(_ text: String) -> Int? {
        var body = Substring(text.pythonStripped)
        var negative = false
        if let sign = body.first, sign == "+" || sign == "-" { negative = sign == "-"; body = body.dropFirst() }
        guard let first = body.first, first.isASCII, first.isNumber, let last = body.last, last != "_",
              !body.contains("__") else { return nil }
        let digits = body.replacingOccurrences(of: "_", with: "")
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else { return nil }
        return negative ? -value : value
    }

    static func importTime(_ db: Database, key: String, source: Int, project: String, start: String, end: String) throws -> JSON {
        try Store.project(db, project)
        let range = try EntryStore.dayRange(db, start: start, end: end, period: "week")
        let first = try Day.parse(range.first), last = try Day.parse(range.last)
        let (after, before) = (range.since, range.until)
        if last.ordinal - first.ordinal > 31 { throw EngineError.invalid("Choose a Toggl date range of at most 31 days.") }
        guard source > 0 else { throw EngineError.invalid("Choose a Toggl Track project.") }
        let profile = try fetch(key, "/me", [("with_related_data", "false")])
        guard profile.pairs != nil, case let .int(number) = profile["id"], number > 0 else {
            throw EngineError.invalid("Toggl Track returned an invalid account.")
        }
        let account = Int(number)
        let invalid = EngineError.invalid("Toggl Track returned an invalid time entry.")
        var entries: [(Int, (Int, Int))] = []
        func handle(_ row: JSON) throws {
            guard row.pairs != nil else { throw invalid }
            let owner = row["project_id"].isTruthy ? row["project_id"] : row["pid"]
            if owner != .int(Int64(source)) || row["server_deleted_at"].isTruthy { return }
            let duration = row["duration"]
            if case let .int(seconds) = duration, seconds < 0 { return }
            let start = Values.parseAt(row["start"])
            let stop: Int?
            if row["stop"] == .null {
                guard let start, case let .int(seconds) = duration, seconds < 2_147_483_648 else { throw invalid }
                stop = start + Int(seconds) * 1000
            } else {
                stop = Values.parseAt(row["stop"])
            }
            guard case let .int(id) = row["id"], id > 0, let began = start, let stopped = stop, stopped >= began else { throw invalid }
            if after <= began, began < before, stopped > began { upsert(&entries, Int(id), (began, stopped)) }
        }
        var rows: [JSON]?
        do {
            rows = try history(key, after, before)
        } catch is HistoryDateLimit {
            rows = nil
        }
        if let rows {
            for row in rows { try handle(row) }
        } else {
            try reportHistory(key, source: source, account: account, first: first, last: last, visit: handle)
        }
        try db.beginImmediate()
        try db.execute("DELETE FROM toggl_time WHERE account = ? AND toggl_project = ? AND started_at >= ? AND started_at < ?",
                       [account, source, after, before])
        for (id, (began, stopped)) in entries {
            try db.execute("INSERT OR REPLACE INTO toggl_time VALUES (?, ?, ?, ?, ?, ?)",
                           [id, account, source, project, began, stopped])
        }
        return .object([("entries", .int(Int64(entries.count)))])
    }
}
