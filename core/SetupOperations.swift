import Foundation

/// Settings, clients, projects, plans, prices and manual entries (port PR A).
enum SetupOperations {
    static let all: [EngineOperation] = [
        EngineOperation(name: "init_ledger", summary: "Set the ledger's time zone and currency.", effect: .config, handler: initLedger),
        EngineOperation(name: "list_projects", summary: "Projects with their folders and GitHub link.", effect: .read) { _, db, _ in
            try Store.projectList(db)
        },
        EngineOperation(name: "save_project", summary: "Create or update a project.", effect: .config, handler: saveProject),
        EngineOperation(name: "map_folder", summary: "Send a folder's work to a project.", effect: .config) { params, db, _ in
            let p = Params(params)
            try Store.mapFolder(db, project: try p.required("project"), folder: try p.required("folder"))
            return .null
        },
        EngineOperation(name: "unmap_folder", summary: "Stop sending a folder's work to a project.", effect: .config) { params, db, _ in
            let p = Params(params)
            try Store.unmapFolder(db, project: try p.required("project"), folder: try p.required("folder"))
            return .null
        },
        EngineOperation(name: "list_clients", summary: "Client names.", effect: .read) { _, db, _ in
            .strings(try Store.clientList(db))
        },
        EngineOperation(name: "save_client", summary: "Create or rename a client.", effect: .config) { params, db, _ in
            let p = Params(params)
            try Store.saveClient(db, name: try p.required("name"), previous: try p.string("previous"))
            return .strings(try Store.clientList(db))
        },
        EngineOperation(name: "set_appearance", summary: "Set a client's icon or a project's colour.", effect: .config, handler: setAppearance),
        EngineOperation(name: "list_subscriptions", summary: "Monthly plan fees.", effect: .read) { _, db, _ in
            try subscriptionListing(db)
        },
        EngineOperation(name: "set_subscription", summary: "Add or change a monthly plan fee.", effect: .config) { params, db, _ in
            let p = Params(params)
            try Store.setSubscription(db, name: try p.required("name"), monthly: try p.required("monthly"),
                                      provider: try p.string("provider"), newOnly: try p.bool("new_only"))
            return try subscriptionListing(db)
        },
        EngineOperation(name: "remove_subscription", summary: "Remove a monthly plan fee.", effect: .guarded) { params, db, _ in
            try Store.setSubscription(db, name: try Params(params).required("name"), monthly: nil, provider: nil, newOnly: false)
            return try subscriptionListing(db)
        },
        EngineOperation(name: "set_model_rate", summary: "Set prices per million tokens for a model.", effect: .config) { params, db, _ in
            let p = Params(params)
            let provider = try Store.harnessID(try p.required("provider"))
            let rates = try ["input", "cached", "cache_write", "output"].map { try p.required($0) }
            try Store.setModelRate(db, provider: provider, model: try p.required("model"), rates: rates)
            return .null
        },
        EngineOperation(name: "log_time", summary: "Log time you spent on a project.", effect: .config) { params, db, _ in
            let p = Params(params)
            let activity = try p.string("activity") ?? "other"
            guard ["prompting", "reviewing", "other"].contains(activity) else {
                throw EngineError.invalid("Activity must be prompting, reviewing or other")
            }
            return try addManual(db, command: "time", project: try p.required("project"), task: try p.string("task"),
                                 at: try p.string("at"), fields: [
                                     "kind": .text("human"),
                                     "millis": .integer(Int64(try Values.durationMillis(try p.required("minutes")))),
                                     "label": .text(activity),
                                 ])
        },
        EngineOperation(name: "add_expense", summary: "Record a provider charge or other expense.", effect: .config) { params, db, _ in
            let p = Params(params)
            return try addManual(db, command: "expense", project: try p.required("project"), task: try p.string("task"),
                                 at: try p.string("at"), fields: [
                                     "kind": .text("expense"),
                                     "label": .text(try Values.required(try p.string("description"), "Description")),
                                     "cents": .integer(Int64(try Values.cents(try p.required("amount")))),
                                     "reimbursable": .integer(try p.bool("reimburse") ? 1 : 0),
                                 ])
        },
        EngineOperation(name: "delete_entry", summary: "Delete a manually logged time or expense entry.", effect: .guarded) { params, db, _ in
            try Store.removeManual(db, entryID: try Params(params).required("id"))
            return .null
        },
        EngineOperation(name: "assign_entry", summary: "Override the project of an imported entry; null uses folder mapping.",
                  effect: .reversible) { params, db, _ in
            let p = Params(params)
            try Store.assign(db, entryID: try p.required("id"), project: try p.string("project"))
            return .null
        },
    ]

    static func initLedger(_ params: JSON, _ db: Database, _ context: OperationContext) throws -> JSON {
        let p = Params(params)
        var name = try p.string("timezone")
        if let fallback = try p.string("default_timezone"), !fallback.isEmpty, try Store.setting(db, "timezone") == nil {
            name = fallback
        }
        if let name, !name.isEmpty {
            _ = try Values.zone(name)
            try Store.setSetting(db, "timezone", name)
        }
        if let requested = try p.string("currency"), !requested.isEmpty {
            let code = requested.uppercased()
            guard code.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else {
                throw EngineError.invalid("Use a three-letter currency code")
            }
            let current = try Store.currency(db)
            let hasMoney = try db.first("SELECT 1 FROM entries WHERE kind = 'expense' "
                                        + "UNION ALL SELECT 1 FROM rates UNION ALL SELECT 1 FROM model_rates "
                                        + "UNION ALL SELECT 1 FROM subscriptions "
                                        + "UNION ALL SELECT 1 FROM billing_terms LIMIT 1") != nil
            if code != current, hasMoney {
                throw EngineError.conflict("Currency is fixed once expenses, rates, or subscriptions exist in this ledger")
            }
            try Store.setSetting(db, "currency", code)
        }
        return .object([("database", .string(context.databasePath)), ("currency", .string(try Store.currency(db))),
                        ("timezone", .string(try Store.timezoneName(db)))])
    }

    static func saveProject(_ params: JSON, _ db: Database, _ context: OperationContext) throws -> JSON {
        let p = Params(params)
        let name = try p.required("name")
        let kind = try p.required("kind")
        let humanRate = try p.string("human_rate")
        if try p.bool("new_only") || humanRate != nil {
            try db.beginImmediate()
            if try db.first("SELECT 1 FROM projects WHERE name = ?", [name.pythonStripped]) != nil {
                throw EngineError.conflict("A project with this name already exists")
            }
        }
        try Store.createProject(db, name: name, client: try p.string("client"), kind: kind, folder: try p.string("folder"))
        if let repo = try p.string("github") {
            try Store.setRepo(db, project: name.pythonStripped, repo: repo)
        }
        if let humanRate {
            try Billing.saveTerms(db, scope: "project", name: name.pythonStripped, humanRate: humanRate,
                                  agentMode: nil, agentRate: nil, markup: nil, cap: nil)
        }
        return .null
    }

    static func setAppearance(_ params: JSON, _ db: Database, _ context: OperationContext) throws -> JSON {
        let p = Params(params)
        let scope: String, name: String
        if let client = try p.string("client") {
            (scope, name) = ("client", client)
        } else if let project = try p.string("project") {
            (scope, name) = ("project", project)
        } else {
            throw EngineError.invalid("Choose a client or a project")
        }
        try Store.setAppearance(db, scope: scope, name: name, iconsFolder: context.iconsFolder,
                                color: try p.string("color"), icon: try p.string("icon"))
        return try Store.appearanceList(db)
    }

    static func subscriptionListing(_ db: Database) throws -> JSON {
        var listing = try Store.subscriptions(db)
        guard case let .object(pairs) = listing else { return listing }
        listing = .object([("currency", .string(try Store.currency(db)))] + pairs)
        return listing
    }

    /// Adds a manual time or expense entry; the id is "time:<hex>" or "expense:<hex>" like the Python engine.
    static func addManual(_ db: Database, command: String, project: String, task: String?, at: String?,
                          fields: [String: SQLValue]) throws -> JSON {
        try Store.project(db, project)
        let stamp: Int
        if let at {
            guard let parsed = Values.parseAt(at, zone: try Store.timezone(db)) else {
                throw EngineError.invalid("Use an ISO date or timestamp for --at")
            }
            stamp = parsed
        } else {
            stamp = Values.nowMillis()
        }
        let id = "\(command):" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var entry = fields
        entry["id"] = .text(id)
        entry["at"] = .integer(Int64(stamp))
        entry["task"] = task.map(SQLValue.text) ?? .null
        entry["project"] = .text(project)
        try Store.addEntry(db, entry)
        return .object([("id", .string(id))])
    }
}
