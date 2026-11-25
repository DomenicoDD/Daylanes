import Foundation

extension LedgerModel {
    private nonisolated static var providerLedger: String { Values.resolvedPath(Values.databasePath()) }

    nonisolated static func readProviderUsage(_ provider: AIProvider, credential: String? = nil,
                                             saveCredential: Bool = false, requireCredential: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) {
            let path = Self.providerLedger
            let keychain = IntegrationKeychain(provider: provider)
            let scope = provider == .openrouter ? nil : path
            let key = try credential ?? keychain.load(ledger: scope)
            guard let key else {
                if requireCredential { throw Ledger.CommandError(message: "Reconnect \(provider.name) in Integrations.") }
                return
            }
            let api = try ProviderUsageAPI(provider, credential: key, now: ReportOperations.now())
            let db = try Schema.open(path)
            let mapped = provider == .openrouter ? Set(try ProviderUsage.routes(db, provider).keys) : []
            let usage = try api.fetch(mappedKeys: mapped)
            try db.transaction {
                try ProviderUsage.replace(db, provider: provider, cache: usage)
                if saveCredential { try keychain.save(key, ledger: scope) }
            }
        }.value
    }

    nonisolated static func clearProviderUsage(_ provider: AIProvider) async throws {
        try await Task.detached(priority: .userInitiated) {
            let path = Self.providerLedger
            let db = try Schema.open(path)
            try db.transaction {
                try ProviderUsage.clear(db, provider: provider)
                if provider != .openrouter { try IntegrationKeychain(provider: provider).remove(ledger: path) }
            }
        }.value
    }

    func setProviderCredential(_ provider: AIProvider, credential: String?) async {
        await perform(credential == nil ? "Disconnecting \(provider.name)…" : "Connecting \(provider.name)…") {
            if let credential {
                try await Self.readProviderUsage(provider, credential: credential, saveCredential: true)
            } else {
                try await Self.clearProviderUsage(provider)
            }
            providerUsageMessages[provider] = nil
            try await update()
            notice = credential == nil ? "\(provider.name) disconnected" : "\(provider.name) connected"
        }
    }

    func importProviderUsage(_ provider: AIProvider, credential: String? = nil) async {
        do {
            try await Self.readProviderUsage(provider, credential: credential)
            providerUsageMessages[provider] = nil
        } catch {
            providerUsageMessages[provider] = error.localizedDescription
        }
    }

    func refreshProviderUsage(_ provider: AIProvider) async {
        await perform("Refreshing \(provider.name) usage…") {
            try await Self.readProviderUsage(provider, requireCredential: true)
            providerUsageMessages[provider] = nil
            try await update()
            notice = "\(provider.name) usage refreshed"
        }
    }

    func assignProviderKey(_ provider: AIProvider, keyID: String, project: String?, alias: String?) async {
        await perform("Saving API key assignment…") {
            try await Task.detached(priority: .userInitiated) {
                let db = try Schema.open(Self.providerLedger)
                try ProviderUsage.assign(db, provider: provider, keyID: keyID, project: project, alias: alias)
            }.value
            if provider == .openrouter, project != nil { await importProviderUsage(provider) }
            try await update()
            notice = project.map { "API key assigned to \($0)" } ?? "API key unassigned"
        }
    }
}
