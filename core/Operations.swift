import Foundation

/// What an operation does to the ledger (docs/MCP_API_PLAN.md section 6).
enum Effect: Equatable {
    case read
    /// W1: everyday changes an agent may make and undo.
    case reversible
    /// W2: setup and money (rates, clients, projects, manual entries).
    case config
    /// W3: deletions and anything hard to take back.
    case guarded
    /// Reaches the network or another app.
    case external

    var writes: Bool { self != .read }

    var name: String {
        switch self {
        case .read: "read"
        case .reversible: "write.reversible"
        case .config: "write.config"
        case .guarded: "write.guarded"
        case .external: "external"
        }
    }
}

/// Who is calling and with which ledger. The same context serves the app, the CLI and MCP.
struct OperationContext {
    enum Actor: String { case you, cli, agent }

    var databasePath: String
    var actor: Actor = .you
    /// Text piped to the command (the CLI's stdin), for operations that read a stream.
    var input: Data?

    var iconsFolder: String { (databasePath as NSString).deletingLastPathComponent + "/icons" }
}

/// One operation of the engine: declared once, called by the app UI, the CLI and the MCP server.
struct EngineOperation {
    let name: String
    let summary: String
    let effect: Effect
    let handler: (_ params: JSON, _ db: Database, _ context: OperationContext) throws -> JSON
}

/// Typed access to an operation's JSON parameters, with errors that name the parameter.
struct Params {
    let json: JSON

    init(_ json: JSON) { self.json = json }

    func string(_ key: String) throws -> String? {
        switch json[key] {
        case .null: return nil
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .double(value): return JSON.pythonFloat(value)
        default: throw EngineError.invalid("\(key) must be a string")
        }
    }

    func required(_ key: String) throws -> String {
        guard let value = try string(key) else { throw EngineError.invalid("\(key) is required") }
        return value
    }

    func int(_ key: String) throws -> Int? {
        switch json[key] {
        case .null: return nil
        case let .string(text):
            guard let value = Int(text.pythonStripped) else { throw EngineError.invalid("\(key) must be an integer") }
            return value
        default:
            guard let value = json[key].intValue else { throw EngineError.invalid("\(key) must be an integer") }
            return value
        }
    }

    func bool(_ key: String) throws -> Bool {
        switch json[key] {
        case .null: return false
        case let .bool(value): return value
        default: throw EngineError.invalid("\(key) must be true or false")
        }
    }

    func strings(_ key: String) throws -> [String]? {
        switch json[key] {
        case .null: return nil
        case let .array(values):
            return try values.map {
                guard let text = $0.stringValue else { throw EngineError.invalid("\(key) must be a list of strings") }
                return text
            }
        case let .string(value): return [value]
        default: throw EngineError.invalid("\(key) must be a list of strings")
        }
    }

    /// Whether the caller passed the key at all (an explicit null counts), for "leave as is" fields.
    func has(_ key: String) -> Bool { json.pairs?.contains { $0.0 == key } ?? false }
}

/// The engine's operation registry.
enum Engine {
    static let operations: [String: EngineOperation] = {
        var table: [String: EngineOperation] = [:]
        for operation in SetupOperations.all + FocusOperations.all + SyncOperations.all + ReportOperations.all
                            + NetworkOperations.all + AgentOperations.all + DiaryOperations.all {
            precondition(table[operation.name] == nil, "Duplicate operation \(operation.name)")
            table[operation.name] = operation
        }
        return table
    }()

    static func operation(_ name: String) -> EngineOperation? { operations[name] }

    /// Runs an operation against the ledger. Writes run in one transaction: all or nothing.
    static func call(_ name: String, _ params: JSON = .object([]), context: OperationContext) throws -> JSON {
        guard let operation = operations[name] else { throw EngineError.unsupported("Unknown operation: \(name)") }
        let db = try Schema.open(context.databasePath)
        switch operation.effect {
        case .read:
            return try operation.handler(params, db, context)
        case .external:
            // Network work runs outside a transaction so the recorder isn't blocked while it waits;
            // the handler takes the write lock itself (`beginImmediate`) once it has the data.
            do {
                let result = try operation.handler(params, db, context)
                if db.inTransaction { try db.script("COMMIT") }
                return result
            } catch {
                if db.inTransaction { try? db.script("ROLLBACK") }
                throw error
            }
        default:
            return try db.transaction { try operation.handler(params, db, context) }
        }
    }

    /// The registry as JSON, for `tracker api schema` and the MCP tool list.
    static func describe() -> JSON {
        .array(operations.values.sorted { $0.name < $1.name }.map {
            .object([("name", .string($0.name)), ("summary", .string($0.summary)), ("effect", .string($0.effect.name))])
        })
    }
}
