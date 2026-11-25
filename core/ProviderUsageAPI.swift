import Foundation

/// Imports usage metadata through provider GET endpoints. The caller owns the credential and the cache.
struct ProviderUsageAPI {
    typealias Record = ProviderUsage.Record
    typealias Metrics = ProviderUsage.Metrics
    typealias Key = ProviderUsage.Key
    typealias Get = (String, [String: String]) throws -> JSON

    private let provider: AIProvider
    private let headers: [String: String]
    private let get: Get
    private let start: String
    private let end: String
    private let fetchedAt: Double

    init(_ provider: AIProvider, credential: String, now: Int, get: @escaping Get = Self.request) throws {
        self.provider = provider
        let key = credential.pythonStripped
        guard fullMatch("[A-Za-z0-9._~+/=:-]{1,512}", key),
              provider != .higgsfield || fullMatch("[A-Za-z0-9_-]+:[A-Za-z0-9_-]+", key) else {
            throw EngineError.invalid("Enter a valid \(provider.name) credential.")
        }
        let scheme = provider == .fal || provider == .higgsfield ? "Key" : "Bearer"
        headers = ["Authorization": "\(scheme) \(key)", "Accept": "application/json"]
        self.get = get
        let today = Day.local(now, TimeZone(secondsFromGMT: 0)!)
        start = today.adding(days: -30).iso
        end = today.iso
        fetchedAt = Double(now) / 1000
    }

    func fetch(mappedKeys: Set<String> = []) throws -> ProviderUsage.Cache {
        let result: ([Record], [Key], [String: Decimal]?)
        switch provider {
        case .openrouter:
            let keys = try openRouterKeys()
            let rows = try keys.filter { mappedKeys.contains($0.id) }.flatMap { try openRouterActivity($0.id) }
            result = (rows, keys, nil)
        case .fal:
            let rows = try falActivity()
            let names = try falKeys()
            result = (rows, mergeKeys(names, observed: rows), nil)
        case .higgsfield:
            let rows = try higgsfieldActivity()
            result = (rows, mergeKeys([], observed: rows), nil)
        case .replicate:
            result = (try replicateActivity(), [], nil)
        case .ollama:
            let (rows, first, last) = try ollamaActivity()
            return ProviderUsage.Cache(start: max(start, first), end: min(end, last), fetchedAt: fetchedAt,
                                       records: rows, keys: [], balance: try ollamaBalance())
        }
        return ProviderUsage.Cache(start: start, end: end, fetchedAt: fetchedAt,
                                   records: result.0, keys: result.1, balance: result.2)
    }

    private func mergeKeys(_ listed: [Key], observed: [Record]) -> [Key] {
        var known = Set<String>()
        let unique = listed.filter { known.insert($0.id).inserted }
        let extra = Set(observed.compactMap(\.keyID)).subtracting(known).sorted()
        return unique + extra.map { Key(id: $0, name: $0) }
    }

    private static func request(_ url: String, _ headers: [String: String]) throws -> JSON {
        let response = try HTTP.send(url, headers: headers, timeout: 10, limit: 8 * 1024 * 1024,
                                     redirects: false, useTestEndpoint: false)
        return try JSON.parse(bytes: Array(response.body), decimalFloats: true)
    }

    private func read(_ url: String, _ query: [(String, String)] = []) throws -> JSON {
        do {
            return try get(query.isEmpty ? url : url + "?" + HTTP.query(query), headers)
        } catch HTTP.Failure.status(let status, _) {
            if status == 401 || status == 403 {
                throw EngineError.invalid("\(provider.name) denied access. Check the key and its usage permissions (HTTP \(status)).")
            }
            throw EngineError.invalid("\(provider.name) usage request failed (HTTP \(status)).")
        } catch HTTP.Failure.transport {
            throw EngineError.invalid("Could not reach \(provider.name) to refresh usage.")
        } catch HTTP.Failure.tooLarge {
            throw EngineError.invalid("\(provider.name) returned too much data in one page.")
        } catch {
            throw invalid
        }
    }

    private var invalid: EngineError { .invalid("\(provider.name) returned an unreadable usage response.") }
    private var incomplete: EngineError { .invalid("\(provider.name) usage pagination did not complete. The last successful sync is still available.") }

    private func rows(_ value: JSON) throws -> [JSON] {
        guard let items = value.arrayValue else { throw invalid }
        return items
    }

    private func name(_ value: JSON) throws -> String {
        guard let text = value.stringValue.nonEmpty, text.count <= 512 else { throw invalid }
        return text
    }

    private func day(_ value: JSON) throws -> String {
        let date = String(try name(value).prefix(10))
        guard (try? Day.parse(date)) != nil else { throw invalid }
        return date
    }

    private func amount(_ value: JSON) throws -> Decimal {
        let raw = value.decimalText ?? value.stringValue ?? value.intValue.map(String.init)
        guard let raw, fullMatch("[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?", raw),
              let number = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              !number.isNaN, number <= 1_000_000_000_000_000 else { throw invalid }
        return number
    }

    private func cursorPages<T>(_ url: String, query: [(String, String)] = [],
                                decode: (JSON) throws -> [T]) throws -> [T] {
        var result: [T] = [], cursors: Set<String> = []
        var paging: [(String, String)] = []
        for _ in 0..<100 {
            let page = try read(url, query + paging)
            result += try decode(page)
            let cursor = page["next_cursor"]
            if cursor.isNull && page["has_more"] == .bool(false) { return result }
            guard let next = cursor.stringValue.nonEmpty, cursors.insert(next).inserted else { throw incomplete }
            paging = [("cursor", next)]
        }
        throw incomplete
    }

    private var daily: [(String, String)] {
        [("start", start + "T00:00:00Z"), ("end", end + "T00:00:00Z"),
         ("timeframe", "day"), ("bound_to_timeframe", "false"), ("expand", "time_series")]
    }

    private func mediaRows(_ page: JSON, decode: (String, JSON) throws -> Record) throws -> [Record] {
        try rows(page["time_series"]).flatMap { bucket -> [Record] in
            let date = try day(bucket["bucket"])
            guard start <= date && date < end else { return [] }
            return try rows(bucket["results"]).map { try decode(date, $0) }
        }
    }

    private func falKeys() throws -> [Key] {
        try cursorPages("https://api.fal.ai/v1/keys", query: [("limit", "100")]) { page in
            try rows(page["keys"]).map { row in
                let id = try name(row["key_id"])
                return Key(id: id, name: row["alias"].stringValue.nonEmpty ?? id)
            }
        }
    }

    private func falActivity() throws -> [Record] {
        try cursorPages("https://api.fal.ai/v1/models/usage",
                        query: daily + [("timezone", "UTC"), ("expand", "auth_method_structured")]) { page in
            try mediaRows(page) { date, row in
                let keyID = row["auth_method_structured"]["api_key_id"].stringValue.nonEmpty
                return try mediaRecord(date, row, keyID: keyID, model: "endpoint_id", cost: "cost_total")
            }
        }
    }

    private func higgsfieldActivity() throws -> [Record] {
        let url = "https://api.higgsfield.ai/models/usage"
        var result: [Record] = []
        let limit = 100
        for index in 1...100 {
            let page = try read(url, daily + [("expand", "auth_method"), ("limit", String(limit)), ("page", String(index))])
            result += try mediaRows(page) { date, row in
                let id = row["auth_method"].stringValue.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
                return try mediaRecord(date, row, keyID: id, model: "model", cost: "cost")
            }
            guard let total = page["total"].intValue, total >= 0,
                  let size = page["limit"].intValue, (1...limit).contains(size),
                  page["page"].intValue == index else { throw invalid }
            if index * size >= total { return result }
        }
        throw incomplete
    }

    private func mediaRecord(_ date: String, _ row: JSON, keyID: String?, model: String, cost: String) throws -> Record {
        let currency = try name(row["currency"])
        guard fullMatch("[A-Z]{3}", currency) else { throw invalid }
        let metrics = try Metrics(spend: [currency: amount(row[cost])],
                                  quantities: [name(row["unit"]): amount(row["quantity"])])
        return try Record(day: date, keyID: keyID, model: name(row[model]), metrics: metrics)
    }

    private func openRouterKeys() throws -> [Key] {
        var result: [Key] = []
        var seen: Set<String> = []
        for _ in 0..<100 {
            let page = try read("https://openrouter.ai/api/v1/keys", [
                ("include_disabled", "true"), ("include_expired", "true"), ("offset", String(result.count)),
            ])
            let items = try rows(page["data"])
            if items.isEmpty { return result }
            for row in items {
                let id = try name(row["hash"])
                guard fullMatch("[a-fA-F0-9]{64}", id), seen.insert(id).inserted else { throw incomplete }
                result.append(Key(id: id, name: row["name"].stringValue.nonEmpty ?? row["label"].stringValue ?? id))
            }
        }
        throw incomplete
    }

    private func openRouterActivity(_ keyID: String) throws -> [Record] {
        let page = try read(OpenRouterActivity.url, [("api_key_hash", keyID)])
        return try OpenRouterActivity.decodeRows(rows(page["data"]), start: start, end: end).map { row in
            guard let spend = Decimal(string: row.spend.description, locale: Locale(identifier: "en_US_POSIX")),
                  !spend.isNaN else { throw invalid }
            let metrics = Metrics(spend: ["USD": spend],
                                  quantities: ["Requests": Decimal(row.requests), "Tokens": Decimal(row.tokens)])
            return Record(day: row.day, keyID: keyID, model: row.model, metrics: metrics)
        }
    }

    private func replicateActivity() throws -> [Record] {
        let url = "https://api.replicate.com/v1/predictions"
        var next = url, seen: Set<String> = [], requests: Set<String> = []
        var result: [Record] = []
        for _ in 0..<100 {
            guard seen.insert(next).inserted else { throw incomplete }
            let page = try read(next)
            for row in try rows(page["results"]) {
                let date = try day(row["created_at"])
                if date < start { return result }
                guard date < end, requests.insert(try name(row["id"])).inserted else { continue }
                var quantity: [String: Decimal] = ["Predictions": 1]
                if !row["metrics"]["predict_time"].isNull {
                    quantity["Processing seconds"] = try amount(row["metrics"]["predict_time"])
                }
                let model = row["model"].stringValue.nonEmpty ?? "Unknown model"
                result.append(Record(day: date, keyID: nil, model: model, metrics: Metrics(quantities: quantity)))
            }
            if page["next"].isNull { return result }
            let link = try name(page["next"])
            guard let parsed = URLComponents(string: link), parsed.scheme == "https",
                  parsed.host == "api.replicate.com", parsed.port == nil, parsed.user == nil,
                  parsed.password == nil, parsed.fragment == nil, parsed.percentEncodedPath == "/v1/predictions" else {
                throw invalid
            }
            next = link
        }
        throw incomplete
    }

    private func ollamaActivity() throws -> ([Record], String, String) {
        let page = try read("https://ollama.com/api/usage", [("range", "30d"), ("group_by", "model")])
        guard page["granularity"] == .string("day"), page["scope"] == .string("self") else { throw invalid }
        let records = try rows(page["buckets"]).flatMap { bucket -> [Record] in
            let date = try day(bucket["from"])
            guard start <= date, date < end, bucket["partial"] != .bool(true) else { return [] }
            let groups = try rows(bucket["groups"].isNull ? .array([]) : bucket["groups"])
            if groups.isEmpty && bucket["remainder"].isNull {
                return [try ollamaRecord(date, bucket, model: "Other usage")]
            }
            var result = try groups.map { try ollamaRecord(date, $0, model: name($0["model"])) }
            if !bucket["remainder"].isNull {
                result.append(try ollamaRecord(date, bucket["remainder"], model: "Other usage"))
            }
            return result
        }
        return try (records, day(page["from"]), day(page["until"]))
    }

    private func ollamaRecord(_ date: String, _ row: JSON, model: String) throws -> Record {
        let count = try amount(row["request_count"])
        let spend: [String: Decimal] = try row["usage_usd"].isNull ? [:] : ["USD": amount(row["usage_usd"])]
        var quantities = ["Requests": count]
        if !row["input_tokens"].isNull && !row["output_tokens"].isNull {
            quantities["Tokens"] = try amount(row["input_tokens"]) + amount(row["output_tokens"])
        }
        return Record(day: date, keyID: nil, model: model,
                      metrics: Metrics(spend: spend, quantities: quantities, hasUnpricedUsage: spend.isEmpty && count > 0))
    }

    private func ollamaBalance() throws -> [String: Decimal] {
        let page = try read("https://ollama.com/api/balance")
        var balances = try ["Purchased credits": amount(page["purchased"]["balance_usd"])]
        if !page["included"]["balance_usd"].isNull {
            balances["Included credits"] = try amount(page["included"]["balance_usd"])
        }
        return balances
    }
}
