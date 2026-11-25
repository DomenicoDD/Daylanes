import Foundation

extension PyDecimal {
    /// `Decimal(value)` for a value read from JSON: strings and integers as written, floats exactly.
    init?(json: JSON) {
        switch json {
        case let .string(text): self.init(text)
        case let .int(value): self.init(Int(value))
        case let .double(value): self.init(exactly: value)
        default: return nil
        }
    }

    /// `Decimal(float)`: the binary value written out exactly.
    init?(exactly value: Double) {
        guard value.isFinite else { return nil }
        if value == 0 {
            self.init(negative: value.sign == .minus, coefficient: BigUInt(), exponent: 0)
            return
        }
        var significand = UInt64(value.significandBitPattern) | (value.isNormal ? (1 << 52) : 0)
        var exponent = Int(value.isNormal ? value.exponentBitPattern : 1) - 1075
        while significand & 1 == 0 { significand >>= 1; exponent += 1 }
        if exponent >= 0 {
            var coefficient = BigUInt(significand)
            for _ in 0..<exponent { coefficient = coefficient * BigUInt(2) }
            self.init(negative: value < 0, coefficient: coefficient, exponent: 0)
        } else {
            var coefficient = BigUInt(significand)
            for _ in 0..<(-exponent) { coefficient = coefficient * BigUInt(5) }
            self.init(negative: value < 0, coefficient: coefficient, exponent: exponent)
        }
    }
}

/// Reference rates from the cached OpenRouter catalog (Python's `pricing.Catalog`), in USD per token.
struct Catalog {
    typealias Rates = [String: PyDecimal]

    static let cacheDefaults: [String: [String]] = [
        "anthropic": ["1.25", "2", "0.1"], "openai": ["1", "1", "0.1"], "google": ["1", "1", "0.1"],
        "deepseek": ["1", "1", "0.02"], "x-ai": ["1", "1", "0.25"], "moonshotai": ["1", "2", "0.1"],
        "z-ai": ["1", "1", "0.2"], "qwen": ["1", "1", "0.2"], "minimax": ["1", "1", "0.2"],
        "mistralai": ["1", "1", "0.1"],
    ]
    static let modelNamespaces: [(NSRegularExpression, String)] = [
        (#"^(claude|opus|sonnet|haiku|fable)"#, "anthropic"),
        (#"^(gpt-|o\d(-|$)|codex|chatgpt)"#, "openai"),
        (#"^(gemini|gemma)"#, "google"),
        (#"^grok"#, "x-ai"),
        (#"^deepseek"#, "deepseek"),
        (#"^kimi"#, "moonshotai"),
        (#"^glm"#, "z-ai"),
        (#"^(qwen|qwq)"#, "qwen"),
        (#"^minimax"#, "minimax"),
        (#"^(mistral|devstral|codestral)"#, "mistralai"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    static let tierMultipliers: [String: (exact: [String: String], prefix: [(String, String)])] = {
        var flex: [String: String] = [:]
        for model in ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-terra",
                      "gpt-5.6-luna", "gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4-pro",
                      "gpt-5.2", "gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano", "o3", "o4-mini"] { flex[model] = "0.5" }
        return [
            "fast": (exact: ["gpt-5.6-sol": "2", "gpt-5.6-terra": "2", "gpt-5.6-luna": "2", "gpt-5.5": "2.5",
                             "gpt-5.4": "2", "gpt-5.3-codex": "2", "gpt-6-astra": "2", "gpt-6-sol": "2",
                             "gpt-6.1-sol": "2", "gpt-6.1-terra": "2", "gpt-6-luna": "2"],
                     prefix: [("claude-opus-4-6", "6"), ("claude-opus-4-7", "6"), ("claude-opus-4-8", "2")]),
            "ultrafast": (exact: ["gpt-6-astra": "6", "gpt-6.1-sol": "6"], prefix: []),
            "flex": (exact: flex, prefix: []),
        ]
    }()
    static let autoReview = "codex-auto-review"
    static let autoReviewSwitch = 1_785_369_600_000
    static let kimiK26Switch = 1_776_698_890_072
    static let namespaces = ["codex": "openai", "claude": "anthropic"]
    static let providerNamespaces = ["xai": "x-ai", "grok": "x-ai", "gemini": "google", "vertex_ai": "google",
                                     "moonshot": "moonshotai", "zai": "z-ai", "alibaba": "qwen", "claude": "anthropic",
                                     "mistral": "mistralai"]
    static let modelID = try! NSRegularExpression(pattern: #"^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._:-]*$"#)
    private static let anthropicPatterns = [
        #"^anthropic/claude-(haiku|sonnet|opus|fable)-(\d+(?:[.-]\d{1,2})?)(-\d{8})?$"#,
        #"^anthropic/claude-(\d+(?:[.-]\d{1,2})?)-(haiku|sonnet|opus|fable)(-\d{8})?$"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let dateSuffix = try! NSRegularExpression(pattern: #"-\d{8}$"#)

    let fetchedAt: JSON
    let rates: [String: Rates]
    let tiers: [String: [(Int, Rates)]]
    let aliases: [String: String]

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func decimals(_ rates: JSON) -> Rates {
        var result: Rates = [:]
        for (key, value) in rates.pairs ?? [] where !value.isNull {
            if let decimal = PyDecimal(json: value) { result[key] = decimal }
        }
        return result
    }

    static func anthropicID(_ model: String) -> String {
        let range = NSRange(model.startIndex..., in: model)
        for (index, pattern) in anthropicPatterns.enumerated() {
            guard let match = pattern.firstMatch(in: model, range: range) else { continue }
            func group(_ number: Int) -> String {
                Range(match.range(at: number), in: model).map { String(model[$0]) } ?? ""
            }
            let family = index == 0 ? group(1) : group(2)
            let version = (index == 0 ? group(2) : group(1)).replacingOccurrences(of: "-", with: ".")
            return "anthropic/claude-\(family)-\(version)\(group(3))"
        }
        return model
    }

    init(_ db: Database) throws {
        let text = try Store.setting(db, "openrouter_catalog", #"{"models": {}}"#)
        let data = try JSON.parse(text)
        fetchedAt = data["fetched_at"]
        var rates: [String: Rates] = [:]
        var tiers: [String: [(Int, Rates)]] = [:]
        var found: [(String, [String])] = []
        func add(_ alias: String, _ model: String) {
            if let index = found.firstIndex(where: { $0.0 == alias }) {
                if !found[index].1.contains(model) { found[index].1.append(model) }
            } else {
                found.append((alias, [model]))
            }
        }
        for (model, row) in data["models"].pairs ?? [] {
            rates[model] = Catalog.decimals(row["rates"])
            if let list = row["tiers"].arrayValue, !list.isEmpty {
                tiers[model] = list.map { ($0["min_prompt_tokens"].intValue ?? 0, Catalog.decimals($0["rates"])) }
            }
        }
        for (model, row) in data["models"].pairs ?? [] {
            if model.contains(":") { continue }
            var candidates = [Catalog.anthropicID(model)]
            if let canonical = row["canonical"].stringValue, !canonical.isEmpty, Catalog.matches(Catalog.modelID, canonical),
               canonical.split(separator: "/", omittingEmptySubsequences: false)[0]
               == model.split(separator: "/", omittingEmptySubsequences: false)[0] {
                candidates += [canonical, Catalog.anthropicID(canonical)]
            }
            for alias in candidates { add(alias, model) }
        }
        var aliases: [String: String] = [:]
        for (alias, models) in found where models.count == 1 { aliases[alias] = models[0] }
        self.rates = rates
        self.tiers = tiers
        self.aliases = aliases
    }

    func model(_ harness: String?, _ raw: String?) -> String? {
        guard var model = raw, !model.isEmpty else { return nil }
        if model.hasPrefix("openrouter/") { model = String(model.dropFirst("openrouter/".count)) }
        if !model.contains("/") {
            let namespace = harness.flatMap { Catalog.namespaces[$0] }
                ?? Catalog.modelNamespaces.first { Catalog.matches($0.0, model.lowercased()) }?.1
            if let namespace { model = "\(namespace)/\(model)" }
        } else if let slash = model.firstIndex(of: "/"), let mapped = Catalog.providerNamespaces[String(model[..<slash])] {
            model = mapped + model[slash...]
        }
        if rates[model] != nil { return model }
        return aliases[model] ?? aliases[Catalog.anthropicID(model)]
    }

    /// API value of an entry: the cost the agent recorded when it has one, else the estimate.
    func quote(_ entry: Entry) -> PyDecimal? {
        if let recorded = entry.recordedUSD, !recorded.isEmpty, let value = PyDecimal(recorded) { return value }
        return estimate(entry)
    }

    func estimate(_ entry: Entry) -> PyDecimal? {
        guard let model = model(entry.provider, Catalog.servedModel(entry.model, at: entry.at)) else { return nil }
        let rates = ratesFor(model, promptTokens: entry.promptTokens)
        let oneHour = min(entry.cacheWrite1h ?? 0, entry.cacheWrite ?? 0)
        var counts: [(String, Int)] = [("input", entry.input ?? 0), ("cached", entry.cached ?? 0), ("output", entry.output ?? 0),
                                       ("cache_write", (entry.cacheWrite ?? 0) - oneHour), ("cache_write_1h", oneHour)]
        if oneHour != 0, rates["cache_write_1h"] == nil {
            counts[3].1 = entry.cacheWrite ?? 0
            counts[4].1 = 0
        }
        if counts.contains(where: { $0.1 != 0 && rates[$0.0] == nil }) { return nil }
        var total = PyDecimal.zero
        for (field, count) in counts where count != 0 { total = total + PyDecimal(count) * rates[field]! }
        total = total * Catalog.tierMultiplier(entry.tier, model)
        let searches = entry.webSearches ?? 0
        if searches != 0, let rate = rates["web_search"] { total = total + PyDecimal(searches) * rate }
        return total
    }

    func ratesFor(_ model: String, promptTokens: Int?) -> Rates {
        var rates = self.rates[model] ?? [:]
        for (threshold, tier) in tiers[model] ?? [] {
            if let promptTokens, promptTokens != 0, promptTokens >= threshold { rates = tier }
        }
        let head = String(model.split(separator: "/", omittingEmptySubsequences: false)[0])
        if let defaults = Catalog.cacheDefaults[head], let input = rates["input"] {
            var filled = rates
            for (field, factor) in zip(["cache_write", "cache_write_1h", "cached"], defaults) where filled[field] == nil {
                filled[field] = input * PyDecimal(factor)!
            }
            rates = filled
        }
        return rates
    }

    static func servedModel(_ model: String?, at: Int?) -> String? {
        if model == autoReview, let at, at != 0 { return at >= autoReviewSwitch ? "gpt-5.6-luna" : "gpt-5.4" }
        if model == "kimi-for-coding", let at, at != 0 {
            return at >= kimiK26Switch ? "moonshotai/kimi-k2.6" : "moonshotai/kimi-k2.5"
        }
        return model
    }

    static func tierMultiplier(_ tier: String?, _ model: String) -> PyDecimal {
        guard let table = tierMultipliers[tier == "priority" ? "fast" : (tier ?? "")] else { return .one }
        let name = String(model.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        let base = dateSuffix.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        for candidate in [name, base] {
            if let value = table.exact[candidate] { return PyDecimal(value)! }
        }
        let dashed = base.replacingOccurrences(of: ".", with: "-")
        for (prefix, value) in table.prefix where dashed.hasPrefix(prefix) { return PyDecimal(value)! }
        return .one
    }
}
