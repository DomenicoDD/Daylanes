import AppKit
import CryptoKit
import SwiftUI

@MainActor
final class GoogleCalendarConnection: ObservableObject {
    struct Account: Identifiable {
        let id: UUID
        var address: String
        var selected: Set<String>
        var calendars: [GoogleCalendarAPI.Calendar] = []
        var meetings: [GoogleCalendarAPI.Meeting] = []
        var lastMeetingCheck: Date?
        var problem: String?
        var needsReconnect = false
    }

    @Published private(set) var clientConfigured = false
    @Published private(set) var bundledClientAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var awaitingConsent = false
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false

    private let ledger: String
    private let legacySelectionKey: String
    private let api = GoogleCalendarAPI()
    private var bundledClient: GoogleCalendarClient?
    private var importedClient: GoogleCalendarClient?
    private var saved = GoogleCalendarAccountStore()
    private var authorizationTask: Task<Void, Never>?

    private var defaultClient: GoogleCalendarClient? { bundledClient ?? importedClient }

    init(ledger: String) {
        self.ledger = ledger
        let hash = SHA256.hash(data: Data(ledger.utf8)).map { String(format: "%02x", $0) }.joined()
        legacySelectionKey = "google-calendar-selection-" + hash
    }

    func load() async {
        guard !loaded else { return }
        await perform {
            if let url = Bundle.main.url(forResource: "GoogleCalendarDesktopClient", withExtension: "json") {
                bundledClient = try GoogleCalendarClient.read(from: url)
                bundledClientAvailable = true
            }
            if let stored = try await loadValue(.googleCalendarClient) {
                importedClient = try JSONDecoder().decode(GoogleCalendarClient.self, from: Data(stored.utf8))
            }
            clientConfigured = defaultClient != nil
            if let stored = try await loadValue(.googleCalendar) {
                let selection = Set(UserDefaults.standard.stringArray(forKey: legacySelectionKey) ?? [])
                let decoded = try GoogleCalendarAccountStore.decode(stored, legacyClientID: importedClient?.clientID,
                                                                    legacySelection: selection)
                if decoded.migrated {
                    try await persist(decoded.store)
                    UserDefaults.standard.removeObject(forKey: legacySelectionKey)
                } else {
                    updateAccounts(decoded.store)
                }
            }
            loaded = true
            for grant in saved.grants {
                guard !Task.isCancelled else { return }
                await refreshAccount(grant.id)
            }
        }
    }

    func importClient(_ result: Result<[URL], Error>) async {
        await perform {
            guard loaded, bundledClient == nil, importedClient == nil || saved.grants.isEmpty,
                  let url = try result.get().first else { return }
            let authorized = url.startAccessingSecurityScopedResource()
            defer { if authorized { url.stopAccessingSecurityScopedResource() } }
            let imported = try GoogleCalendarClient.read(from: url)
            try await saveValue(imported, in: .googleCalendarClient)
            importedClient = imported
            clientConfigured = true
            for grant in saved.grants { await refreshAccount(grant.id) }
        }
    }

    func connect(reconnecting id: UUID? = nil) {
        guard loaded, !busy, authorizationTask == nil, let client = defaultClient else { return }
        let hint = saved.grants.first { $0.id == id }?.primaryCalendarID
        awaitingConsent = true
        authorizationTask = Task {
            defer {
                awaitingConsent = false
                authorizationTask = nil
            }
            await perform {
                let authorization = GoogleCalendarAuthorization()
                let callback = try GoogleCalendarCallback(state: authorization.state)
                let response = try await callback.receive {
                    NSWorkspace.shared.open(authorization.url(client: client, redirect: $0, loginHint: hint))
                }
                awaitingConsent = false
                let tokens = try await api.redeem(response.code, client: client, redirect: response.redirect,
                                                  verifier: authorization.verifier)
                guard let token = tokens.refreshToken else { throw GoogleCalendarError.missingRefreshToken }
                let listed = try await api.calendars(accessToken: tokens.accessToken)
                guard let primary = listed.first(where: { $0.primary == true })?.id else {
                    throw GoogleCalendarError.missingPrimaryCalendar
                }
                try Task.checkCancellation()
                var updated = saved
                let grant = try updated.authorize(primary: primary, clientID: client.clientID, refreshToken: token,
                                                  reconnecting: id)
                try await persist(updated)
                await check(grant, calendars: listed, accessToken: tokens.accessToken)
            }
        }
    }

    func cancelConnect() { authorizationTask?.cancel() }

    func chooseCalendar(_ calendarID: String, accountID: UUID, selected enabled: Bool) async {
        await perform {
            var updated = saved
            guard let index = updated.grants.firstIndex(where: { $0.id == accountID }) else { return }
            if enabled {
                updated.grants[index].selected.insert(calendarID)
            } else {
                updated.grants[index].selected.remove(calendarID)
            }
            try await persist(updated)
        }
    }

    func sync(_ id: UUID) async {
        await perform { await refreshAccount(id) }
    }

    func refreshForTimeline() async {
        if !loaded {
            await load()
            return
        }
        let stale = Date().addingTimeInterval(-300)
        let pending = accounts.filter { !$0.selected.isEmpty && !$0.needsReconnect && ($0.lastMeetingCheck ?? .distantPast) < stale }
        guard !pending.isEmpty else { return }
        await perform {
            for account in pending {
                guard !Task.isCancelled else { return }
                await refreshAccount(account.id)
            }
        }
    }

    func disconnect(_ id: UUID) async {
        await perform {
            var updated = saved
            updated.grants.removeAll { $0.id == id }
            try await persist(updated)
        }
    }

    private func refreshAccount(_ id: UUID) async {
        guard let position = saved.grants.firstIndex(where: { $0.id == id }) else { return }
        var grant = saved.grants[position]
        do {
            guard let client = [bundledClient, importedClient].compactMap({ $0 }).first(where: {
                $0.clientID == grant.clientID
            }) else { throw GoogleCalendarError.reconnect }
            let tokens = try await api.refresh(grant.refreshToken, client: client)
            if let token = tokens.refreshToken, token != grant.refreshToken {
                grant.refreshToken = token
                var updated = saved
                updated.grants[position] = grant
                try await persist(updated)
            }
            let listed = try await api.calendars(accessToken: tokens.accessToken)
            if let primary = listed.first(where: { $0.primary == true })?.id, grant.primaryCalendarID != primary {
                guard !saved.grants.contains(where: { $0.id != id && $0.matches(primary) }) else {
                    throw GoogleCalendarError.reconnect
                }
                grant.primaryCalendarID = primary
                var updated = saved
                updated.grants[position] = grant
                try await persist(updated)
            }
            try Task.checkCancellation()
            await check(grant, calendars: listed, accessToken: tokens.accessToken)
        } catch {
            showProblem(error, for: id)
        }
    }

    private func check(_ grant: GoogleCalendarAccountStore.Grant, calendars: [GoogleCalendarAPI.Calendar],
                       accessToken: String) async {
        guard let index = accounts.firstIndex(where: { $0.id == grant.id }) else { return }
        accounts[index].calendars = calendars
        accounts[index].problem = nil
        accounts[index].needsReconnect = false
        let available = Set(calendars.map(\.id))
        let calendarIDs = grant.selected.intersection(available)
        accounts[index].meetings.removeAll { !calendarIDs.contains($0.id.calendarID) }
        if calendarIDs.isEmpty { accounts[index].lastMeetingCheck = nil }
        do {
            let now = Date()
            let window: TimeInterval = 30 * 24 * 3600
            var meetings: [GoogleCalendarAPI.Meeting] = []
            for calendarID in calendarIDs.sorted() {
                try Task.checkCancellation()
                meetings += try await api.meetings(calendarID: calendarID, primaryCalendarID: grant.primaryCalendarID,
                                                   start: now.addingTimeInterval(-window), end: now.addingTimeInterval(window),
                                                   accessToken: accessToken)
            }
            try Task.checkCancellation()
            accounts[index].meetings = meetings
            if calendarIDs != grant.selected {
                accounts[index].problem = "A selected calendar is no longer available. Review the calendars for this account."
            } else if !calendarIDs.isEmpty {
                accounts[index].lastMeetingCheck = Date()
            }
        } catch {
            showProblem(error, for: grant.id)
        }
    }

    private func showProblem(_ error: Error, for id: UUID) {
        guard !(error is CancellationError), let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].problem = error.localizedDescription
        switch error as? GoogleCalendarError {
        case .reconnect, .missingScopes:
            accounts[index].needsReconnect = true
            accounts[index].meetings = []
        case .denied:
            accounts[index].needsReconnect = false
            accounts[index].meetings = []
        default: accounts[index].needsReconnect = false
        }
    }

    private func persist(_ updated: GoogleCalendarAccountStore) async throws {
        if updated.grants.isEmpty {
            let path = ledger
            try await Task.detached { try IntegrationKeychain.googleCalendar.remove(ledger: path) }.value
        } else {
            try await saveValue(updated, in: .googleCalendar)
        }
        updateAccounts(updated)
    }

    private func updateAccounts(_ updated: GoogleCalendarAccountStore) {
        saved = updated
        let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        accounts = updated.grants.map { grant in
            var account = previous[grant.id] ?? Account(id: grant.id, address: grant.address, selected: grant.selected)
            if account.selected != grant.selected {
                account.lastMeetingCheck = nil
                account.problem = nil
                account.meetings.removeAll { !grant.selected.contains($0.id.calendarID) }
            }
            account.address = grant.address
            account.selected = grant.selected
            return account
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await action()
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
    }

    private func loadValue(_ key: IntegrationKeychain) async throws -> String? {
        let path = ledger
        return try await Task.detached { try key.load(ledger: path) }.value
    }

    private func saveValue<Value: Encodable & Sendable>(_ value: Value, in key: IntegrationKeychain) async throws {
        let path = ledger
        try await Task.detached {
            let data = try JSONEncoder().encode(value)
            try key.save(String(decoding: data, as: UTF8.self), ledger: path)
        }.value
    }
}
