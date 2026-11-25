import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openrouter, fal, higgsfield, replicate, ollama

    var id: Self { self }
    var name: String {
        switch self {
        case .openrouter: "OpenRouter"
        case .fal: "fal"
        case .higgsfield: "Higgsfield"
        case .replicate: "Replicate"
        case .ollama: "Ollama Cloud"
        }
    }

    var supportsProjects: Bool { self == .openrouter || self == .fal || self == .higgsfield }
}

enum ProviderUsage {
    struct Key: Codable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    struct Attribution: Codable, Sendable {
        let project: String
        let alias: String?
    }

    struct Metrics: Codable, Sendable {
        var spend: [String: Decimal] = [:]
        var quantities: [String: Decimal] = [:]
        var hasUnpricedUsage = false

        mutating func add(_ other: Self) {
            spend.merge(other.spend, uniquingKeysWith: +)
            quantities.merge(other.quantities, uniquingKeysWith: +)
            hasUnpricedUsage = hasUnpricedUsage || other.hasUnpricedUsage
        }
    }

    struct Record: Codable, Sendable {
        let day: String
        let keyID: String?
        let model: String
        let metrics: Metrics
    }

    struct Cache: Codable, Sendable {
        let start: String
        let end: String
        let fetchedAt: Double
        let records: [Record]
        let keys: [Key]
        let balance: [String: Decimal]?
    }

    struct Line: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let project: String?
        let client: String?
        let metrics: Metrics
    }

    struct Account: Codable, Identifiable, Sendable {
        let provider: AIProvider
        let from: String?
        let until: String?
        let fetchedAt: Double
        let totals: Metrics
        let models: [Line]
        let keys: [Line]
        let unassigned: Metrics
        let balance: [String: Decimal]?
        var id: AIProvider { provider }
    }

    private static func cacheKey(_ provider: AIProvider) -> String { "provider_usage_" + provider.rawValue }
    private static func routesKey(_ provider: AIProvider) -> String { "provider_key_projects_" + provider.rawValue }

    private static func setting<T: Decodable>(_ db: Database, _ key: String, as type: T.Type) throws -> T? {
        guard let value = try Store.setting(db, key) else { return nil }
        return try JSONDecoder().decode(type, from: Data(value.utf8))
    }

    private static func save<T: Encodable>(_ db: Database, _ key: String, _ value: T) throws {
        try Store.setSetting(db, key, String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    }

    static func cached(_ db: Database, _ provider: AIProvider) throws -> Cache? {
        try setting(db, cacheKey(provider), as: Cache.self)
    }

    static func routes(_ db: Database, _ provider: AIProvider) throws -> [String: Attribution] {
        try setting(db, routesKey(provider), as: [String: Attribution].self) ?? [:]
    }

    static func assign(_ db: Database, provider: AIProvider, keyID: String, project: String?, alias: String?) throws {
        guard provider.supportsProjects, let cache = try cached(db, provider),
              cache.keys.contains(where: { $0.id == keyID }) else {
            throw EngineError.invalid("Choose a key from the synced provider account.")
        }
        if let project { try Store.project(db, project) }
        try db.transaction {
            var assignments = try routes(db, provider)
            assignments[keyID] = project.map { Attribution(project: $0, alias: (alias?.pythonStripped).nonEmpty) }
            try save(db, routesKey(provider), assignments)
        }
    }

    static func replace(_ db: Database, provider: AIProvider, cache: Cache) throws {
        try save(db, cacheKey(provider), cache)
    }

    static func clear(_ db: Database, provider: AIProvider) throws {
        try db.execute("DELETE FROM settings WHERE key = ? OR key = ?", [cacheKey(provider), routesKey(provider)])
    }

    static func report(_ db: Database, start: String, end: String, project: String? = nil,
                       client: String? = nil) throws -> JSON? {
        let scoped = project != nil || client != nil
        var reports: [Account] = []
        let projects = try db.query("SELECT name, client FROM projects")
        let clients = Dictionary(uniqueKeysWithValues: projects.compactMap { row in
            row["name"].string.map { (Data($0.utf8), row["client"].string ?? "") }
        })
        func clientForProject(_ name: String) -> String? { clients[Data(name.utf8)] }
        for provider in AIProvider.allCases {
            guard !scoped || provider.supportsProjects, let cache = try cached(db, provider) else { continue }
            let assignments = try routes(db, provider).filter { clientForProject($0.value.project) != nil }
            let first = max(start, cache.start)
            let until = min(end, cache.end)
            var totals = Metrics(), unassigned = Metrics()
            var models: [String: Metrics] = [:], keys: [String: Metrics] = [:]
            for row in cache.records where first <= row.day && row.day < until {
                let target = row.keyID.flatMap { assignments[$0]?.project }
                guard project == nil || pyEqual(target, project),
                      client == nil || pyEqual(target.flatMap(clientForProject), client) else { continue }
                totals.add(row.metrics)
                models[row.model, default: Metrics()].add(row.metrics)
                if let id = row.keyID { keys[id, default: Metrics()].add(row.metrics) }
                if target == nil { unassigned.add(row.metrics) }
            }
            let lines = cache.keys.compactMap { key -> Line? in
                let target = assignments[key.id]?.project
                let owner = target.flatMap(clientForProject).flatMap { $0.nonEmpty }
                guard project == nil || pyEqual(target, project), client == nil || pyEqual(owner, client) else { return nil }
                return Line(id: key.id, name: assignments[key.id]?.alias ?? key.name, project: target, client: owner,
                            metrics: keys[key.id] ?? Metrics())
            }.sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
            guard !scoped || !lines.isEmpty else { continue }
            reports.append(Account(provider: provider, from: first < until ? first : nil, until: first < until ? until : nil,
                                   fetchedAt: cache.fetchedAt, totals: totals,
                                   models: models.map { Line(id: $0.key, name: $0.key, project: nil, client: nil, metrics: $0.value) }
                                       .sorted { lhs, rhs in
                                           let a = lhs.metrics.spend["USD"] ?? 0, b = rhs.metrics.spend["USD"] ?? 0
                                           return a == b ? lhs.name < rhs.name : a > b
                                       },
                                   keys: lines, unassigned: unassigned, balance: scoped ? nil : cache.balance))
        }
        guard !reports.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return try JSON.parse(encoder.encode(reports))
    }
}
