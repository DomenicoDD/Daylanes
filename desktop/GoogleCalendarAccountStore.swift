import Foundation

struct GoogleCalendarAccountStore: Codable, Sendable {
    struct Grant: Codable, Identifiable, Sendable {
        let id: UUID
        var clientID: String?
        var primaryCalendarID: String?
        var refreshToken: String
        var selected: Set<String>

        var address: String { primaryCalendarID ?? "Google account" }

        func matches(_ primary: String) -> Bool {
            primaryCalendarID?.caseInsensitiveCompare(primary) == .orderedSame
        }
    }

    private struct LegacyGrant: Decodable {
        let refreshToken: String
        let primaryCalendarID: String?
    }

    var grants: [Grant] = []

    static func decode(_ value: String, legacyClientID: String?, legacySelection: Set<String>) throws
        -> (store: Self, migrated: Bool) {
        let data = Data(value.utf8)
        let decoder = JSONDecoder()
        if let store = try? decoder.decode(Self.self, from: data) { return (store, false) }
        let previous = try decoder.decode(LegacyGrant.self, from: data)
        let grant = Grant(id: UUID(), clientID: legacyClientID, primaryCalendarID: previous.primaryCalendarID,
                          refreshToken: previous.refreshToken, selected: legacySelection)
        return (Self(grants: [grant]), true)
    }

    /// Reauthorizing an address updates its grant in place and keeps its calendar selection.
    mutating func authorize(primary: String, clientID: String, refreshToken: String, reconnecting: UUID?) throws -> Grant {
        let matching = grants.firstIndex { $0.matches(primary) }
        let index: Int?
        if let reconnecting {
            guard let expected = grants.firstIndex(where: { $0.id == reconnecting }) else {
                throw GoogleCalendarError.reconnect
            }
            guard (grants[expected].primaryCalendarID == nil || matching == expected),
                  matching == nil || matching == expected else {
                throw GoogleCalendarError.accountMismatch(grants[expected].address)
            }
            index = expected
        } else {
            index = matching
        }
        let previous = index.map { grants[$0] }
        let grant = Grant(id: previous?.id ?? UUID(), clientID: clientID, primaryCalendarID: primary,
                          refreshToken: refreshToken, selected: previous?.selected ?? [])
        if let index { grants[index] = grant } else { grants.append(grant) }
        return grant
    }
}
