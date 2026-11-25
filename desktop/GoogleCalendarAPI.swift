import CryptoKit
import Foundation

struct GoogleCalendarClient: Codable, Sendable {
    let clientID: String
    let clientSecret: String?

    static func read(from url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 64 * 1024
        guard let data = try file.read(upToCount: limit + 1), data.count <= limit,
              let config = try? JSONDecoder().decode(Download.self, from: data),
              config.installed.clientID.hasSuffix(".apps.googleusercontent.com"),
              !config.installed.clientID.contains(where: \.isWhitespace) else {
            throw GoogleCalendarError.invalidClient
        }
        return config.installed
    }

    private struct Download: Decodable {
        let installed: GoogleCalendarClient
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

enum GoogleCalendarError: LocalizedError, Equatable {
    case invalidClient, browserUnavailable, callbackUnavailable, consentTimedOut, consentDenied
    case missingScopes, missingRefreshToken, missingPrimaryCalendar, accountMismatch(String)
    case reconnect, denied, unavailable, invalidResponse, incomplete

    var errorDescription: String? {
        switch self {
        case .invalidClient: "Choose the JSON downloaded for a Google OAuth Desktop app client."
        case .browserUnavailable: "Daylanes couldn’t open your browser. Try connecting again."
        case .callbackUnavailable: "Daylanes couldn’t receive Google’s sign-in response. Try connecting again."
        case .consentTimedOut: "Google sign-in timed out. Close the previous browser tab and choose Connect again in Daylanes."
        case .consentDenied: "Google Calendar access was declined."
        case .missingScopes: "Allow both read-only Calendar permissions when you connect."
        case .missingRefreshToken: "Google didn’t grant offline access. Reconnect and approve Calendar access."
        case .missingPrimaryCalendar: "Google didn’t return a primary calendar for this account. Check Calendar access and try again."
        case .accountMismatch(let account): "Choose \(account) in Google to reconnect this account. To connect a different address, use Add Google account."
        case .reconnect: "Google Calendar access has expired. Reconnect to continue."
        case .denied: "Google denied Calendar access. Check calendar sharing and your Workspace settings."
        case .unavailable: "Google Calendar is temporarily unavailable. Try again."
        case .invalidResponse: "Daylanes couldn’t read Google Calendar’s response."
        case .incomplete: "Google Calendar returned an incomplete list. Try refreshing again."
        }
    }
}

struct GoogleCalendarAuthorization {
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
    ]
    let state = Self.randomValue()
    let verifier = Self.randomValue()

    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    func url(client: GoogleCalendarClient, redirect: URL, loginHint: String? = nil) -> URL {
        var address = URLComponents()
        address.scheme = "https"
        address.host = "accounts.google.com"
        address.path = "/o/oauth2/v2/auth"
        address.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        if let loginHint { address.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        return address.url!
    }

    private static func randomValue() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { base64URL(Data($0)) }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct GoogleCalendarAPI: Sendable {
    struct Calendar: Decodable, Identifiable, Sendable {
        let id: String
        let summary: String
        let summaryOverride: String?
        let primary: Bool?
        var name: String { summaryOverride ?? summary }
    }

    struct Meeting: Identifiable, Sendable {
        struct ID: Hashable, Sendable {
            let calendarID: String
            let eventID: String
        }
        enum Occurrence: Hashable {
            case calendarEvent(ID)
            case invitation(String, Date, Date)
        }
        let id: ID
        let iCalUID: String?
        let title: String
        let start: Date
        let end: Date

        var occurrence: Occurrence {
            guard let iCalUID, !iCalUID.isEmpty else { return .calendarEvent(id) }
            return .invitation(iCalUID, start, end)
        }

        static func schedule(_ meetings: [Self], from start: Date, to end: Date) -> [Self] {
            var seen = Set<Occurrence>()
            return meetings.filter { $0.start < end && $0.end > start && seen.insert($0.occurrence).inserted }
                .sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
        }
    }

    struct Tokens: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", scope
        }

        func checkScopes(required: Bool) throws {
            if scope == nil && !required { return }
            let granted = Set((scope ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            guard Set(GoogleCalendarAuthorization.scopes).isSubset(of: granted) else {
                throw GoogleCalendarError.missingScopes
            }
        }
    }

    typealias Request = @Sendable (String, String, [String: String], Data?) throws -> Data
    private let request: Request

    init(request: @escaping Request = { try Self.send(url: $0, method: $1, headers: $2, body: $3) }) {
        self.request = request
    }

    func redeem(_ code: String, client: GoogleCalendarClient, redirect: URL, verifier: String) async throws -> Tokens {
        let tokens = try await token(client, parameters: [
            ("grant_type", "authorization_code"), ("code", code),
            ("redirect_uri", redirect.absoluteString), ("code_verifier", verifier),
        ], refreshing: false)
        try tokens.checkScopes(required: true)
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw GoogleCalendarError.missingRefreshToken
        }
        return tokens
    }

    func refresh(_ refreshToken: String, client: GoogleCalendarClient) async throws -> Tokens {
        let tokens = try await token(client, parameters: [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
        ], refreshing: true)
        try tokens.checkScopes(required: false)
        return tokens
    }

    func calendars(accessToken: String) async throws -> [Calendar] {
        try await pages(path: "/users/me/calendarList", query: [
            ("minAccessRole", "reader"), ("maxResults", "250"), ("showHidden", "true"),
            ("fields", "nextPageToken,items(id,summary,summaryOverride,primary)"),
        ], accessToken: accessToken)
    }

    func meetings(calendarID: String, primaryCalendarID: String?, start: Date, end: Date,
                  accessToken: String) async throws -> [Meeting] {
        let formatter = ISO8601DateFormatter()
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let calendarPath = calendarID.addingPercentEncoding(withAllowedCharacters: unreserved),
              !calendarPath.isEmpty, calendarPath != ".", calendarPath != ".." else {
            throw GoogleCalendarError.invalidResponse
        }
        let events: [Event] = try await pages(path: "/calendars/\(calendarPath)/events", query: [
            ("singleEvents", "true"), ("showDeleted", "false"), ("eventTypes", "default"),
            ("timeMin", formatter.string(from: start)), ("timeMax", formatter.string(from: end)),
            ("maxResults", "250"),
            ("fields", "nextPageToken,items(id,iCalUID,summary,status,transparency,eventType,start(dateTime),end(dateTime),organizer(self,email),attendees(self,email,responseStatus))"),
        ], accessToken: accessToken)
        return events.compactMap { $0.meeting(calendarID: calendarID, primaryCalendarID: primaryCalendarID, formatter: formatter) }
    }

    private func token(_ client: GoogleCalendarClient, parameters: [(String, String)], refreshing: Bool) async throws -> Tokens {
        var form = parameters + [("client_id", client.clientID)]
        if let secret = client.clientSecret { form.append(("client_secret", secret)) }
        let body = Data(HTTP.query(form).utf8)
        let tokens: Tokens = try await Task.detached {
            do {
                let data = try request("https://oauth2.googleapis.com/token", "POST",
                                       ["Content-Type": "application/x-www-form-urlencoded"], body)
                return try Self.decode(Tokens.self, data)
            } catch HTTP.Failure.status(let status, let body)
                where refreshing && (status == 401 || (status == 400 && (try? Self.decode(TokenError.self, body).error) == "invalid_grant")) {
                throw GoogleCalendarError.reconnect
            } catch is HTTP.Failure {
                throw GoogleCalendarError.unavailable
            }
        }.value
        guard !tokens.accessToken.isEmpty else { throw GoogleCalendarError.invalidResponse }
        return tokens
    }

    private func pages<Item: Decodable & Sendable>(path: String, query: [(String, String)], accessToken: String) async throws -> [Item] {
        try await Task.detached {
            var items: [Item] = []
            var tokens = Set<String>()
            var params = query
            while true {
                let page: Page<Item>
                do {
                    let data = try request("https://www.googleapis.com/calendar/v3" + path + "?" + HTTP.query(params),
                                           "GET", ["Authorization": "Bearer \(accessToken)"], nil)
                    page = try Self.decode(Page<Item>.self, data)
                } catch HTTP.Failure.status(401, _) {
                    throw GoogleCalendarError.reconnect
                } catch HTTP.Failure.status(403, let body) {
                    let denial = try? Self.decode(CalendarErrorResponse.self, body)
                    if denial?.error.errors?.contains(where: { $0.reason == "insufficientPermissions" }) == true {
                        throw GoogleCalendarError.missingScopes
                    }
                    throw GoogleCalendarError.denied
                } catch is HTTP.Failure {
                    throw GoogleCalendarError.unavailable
                }
                items.append(contentsOf: page.items ?? [])
                guard let next = page.nextPageToken, !next.isEmpty else { return items }
                guard tokens.count < 100, tokens.insert(next).inserted else { throw GoogleCalendarError.incomplete }
                params = query + [("pageToken", next)]
            }
        }.value
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw GoogleCalendarError.invalidResponse }
        return value
    }

    static func send(url: String, method: String, headers: [String: String], body: Data?) throws -> Data {
        try HTTP.send(url, method: method, headers: headers, body: body, timeout: 15,
                      limit: 4 * 1024 * 1024, redirects: false, useTestEndpoint: false).body
    }

    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]?
        let nextPageToken: String?
    }

    private struct TokenError: Decodable { let error: String }

    private struct CalendarErrorResponse: Decodable {
        struct Detail: Decodable {
            struct Reason: Decodable { let reason: String }
            let errors: [Reason]?
        }
        let error: Detail
    }

    private struct Event: Decodable {
        struct EventTime: Decodable { let dateTime: String? }
        struct Person: Decodable {
            let isSelf: Bool?
            let email: String?
            let responseStatus: String?
            enum CodingKeys: String, CodingKey { case isSelf = "self", email, responseStatus }
        }
        let id: String
        let iCalUID: String?
        let summary: String?
        let status: String?
        let transparency: String?
        let eventType: String?
        let start: EventTime?
        let end: EventTime?
        let attendees: [Person]?
        let organizer: Person?

        func meeting(calendarID: String, primaryCalendarID: String?, formatter: ISO8601DateFormatter) -> Meeting? {
            guard status != "cancelled", eventType == nil || eventType == "default",
                  let startTime = start?.dateTime, let endTime = end?.dateTime,
                  let lower = Self.date(startTime, formatter: formatter),
                  let upper = Self.date(endTime, formatter: formatter), lower < upper else { return nil }
            // Google’s self flag identifies the calendar holding this copy, which may belong to someone else.
            func connectedUser(_ person: Person) -> Bool {
                guard let primaryCalendarID else { return false }
                return person.email?.caseInsensitiveCompare(primaryCalendarID) == .orderedSame ||
                    (calendarID == primaryCalendarID && person.isSelf == true)
            }
            if let attendee = attendees?.first(where: connectedUser) {
                guard attendee.responseStatus == "accepted" else { return nil }
            } else {
                guard let organizer, connectedUser(organizer), status == "confirmed", transparency != "transparent" else { return nil }
            }
            return Meeting(id: Meeting.ID(calendarID: calendarID, eventID: id), iCalUID: iCalUID,
                           title: summary ?? "Meeting", start: lower, end: upper)
        }

        private static func date(_ time: String, formatter: ISO8601DateFormatter) -> Date? {
            formatter.formatOptions = [.withInternetDateTime]
            if let value = formatter.date(from: time) { return value }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: time)
        }
    }
}
