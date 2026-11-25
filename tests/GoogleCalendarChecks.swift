import CryptoKit
import Foundation

@main
struct GoogleCalendarChecks {
    @MainActor
    static func main() async throws {
        try checkCallback()
        try checkAccountStore()
        try await checkTokens()
        try await checkCalendars()
        try await checkMeetings()
        checkTimelineSchedule()
        print("Google Calendar checks passed")
    }

    private static func checkTimelineSchedule() {
        let dayStart = Date(timeIntervalSince1970: 1_790_000_000)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        func meeting(_ id: String, calendar: String = "work", start: Double, end: Double,
                     uid: String? = nil) -> GoogleCalendarAPI.Meeting {
            GoogleCalendarAPI.Meeting(id: .init(calendarID: calendar, eventID: id), iCalUID: uid, title: id,
                                      start: dayStart.addingTimeInterval(start), end: dayStart.addingTimeInterval(end))
        }
        let meetings = [
            meeting("recurrence", start: 200, end: 300, uid: "recurring"),
            meeting("after", start: 86_400, end: 100_000),
            meeting("copy", calendar: "personal", start: 200, end: 300, uid: "recurring"),
            meeting("overnight", start: -100, end: 100),
            meeting("earlier recurrence", start: 100, end: 199, uid: "recurring"),
            meeting("before", start: -200, end: 0),
        ]
        let result = GoogleCalendarAPI.Meeting.schedule(meetings, from: dayStart, to: dayEnd)
        precondition(result.map(\.title) == ["overnight", "earlier recurrence", "recurrence"])
    }

    @MainActor
    private static func checkCallback() throws {
        let authorization = GoogleCalendarAuthorization()
        precondition(authorization.state.count == 43 && authorization.verifier.count == 43)
        precondition(authorization.state != authorization.verifier)
        let redirect = URL(string: "http://127.0.0.1:12345/oauth2/callback")!
        let client = GoogleCalendarClient(clientID: "dev.apps.googleusercontent.com", clientSecret: nil)
        let url = authorization.url(client: client, redirect: redirect)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        precondition(url.host == "accounts.google.com")
        precondition(query?.contains(URLQueryItem(name: "code_challenge_method", value: "S256")) == true)
        precondition(query?.contains(URLQueryItem(name: "redirect_uri", value: redirect.absoluteString)) == true)
        precondition(query?.contains(URLQueryItem(name: "code_challenge", value: authorization.challenge)) == true)
        precondition(!url.absoluteString.contains(authorization.verifier))
        let reconnectURL = authorization.url(client: client, redirect: redirect, loginHint: "work@example.com")
        let reconnectQuery = URLComponents(url: reconnectURL, resolvingAgainstBaseURL: false)?.queryItems
        precondition(reconnectQuery?.contains(URLQueryItem(name: "login_hint", value: "work@example.com")) == true)

        func parse(_ target: String) -> Result<String, Error>? {
            GoogleCalendarCallback.result(Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1".utf8), state: "test")
        }
        precondition(parse("/favicon.ico") == nil)
        precondition(parse("/oauth2/callback?state=wrong&code=abc") == nil)
        precondition(parse("/oauth2/callback?state=test&state=test&code=abc") == nil)
        precondition(parse("/oauth2/callback?state=test&code=a&code=b") == nil)
        let code = try parse("/oauth2/callback?state=test&code=abc%2B123")?.get()
        precondition(code == "abc+123")
        if case .failure(let error) = parse("/oauth2/callback?state=test&error=access_denied") {
            precondition(error as? GoogleCalendarError == .consentDenied)
        } else { preconditionFailure("Expected a denial") }
    }

    private static func checkAccountStore() throws {
        let legacy = #"{"primaryCalendarID":"work@example.com","refreshToken":"original"}"#
        let migration = try GoogleCalendarAccountStore.decode(legacy, legacyClientID: "dev", legacySelection: ["shared"])
        precondition(migration.migrated)
        var store = migration.store
        let work = store.grants[0]
        precondition(work.clientID == "dev" && work.selected == ["shared"])

        let personal = try store.authorize(primary: "personal@example.com", clientID: "dev",
                                           refreshToken: "personal", reconnecting: nil)
        precondition(personal.id != work.id && personal.selected.isEmpty && store.grants.count == 2)
        store.grants[1].selected.insert("home")

        do {
            _ = try store.authorize(primary: "personal@example.com", clientID: "prod",
                                    refreshToken: "wrong", reconnecting: work.id)
            preconditionFailure("Expected reconnect to reject a different account")
        } catch GoogleCalendarError.accountMismatch(let address) {
            precondition(address == work.address)
        }
        precondition(store.grants[0].refreshToken == "original" && store.grants[1].refreshToken == "personal")

        let renewed = try store.authorize(primary: "WORK@example.com", clientID: "prod",
                                          refreshToken: "renewed", reconnecting: nil)
        precondition(renewed.id == work.id && renewed.selected == ["shared"] && renewed.clientID == "prod")
        precondition(store.grants.count == 2 && store.grants[1].selected == ["home"])

        let encoded = try JSONEncoder().encode(store)
        let readBack = try GoogleCalendarAccountStore.decode(String(decoding: encoded, as: UTF8.self),
                                                            legacyClientID: nil, legacySelection: [])
        precondition(!readBack.migrated && readBack.store.grants.map(\.id) == [work.id, personal.id])
        precondition(readBack.store.grants.map(\.refreshToken) == ["renewed", "personal"])
        precondition(readBack.store.grants.map(\.selected) == [["shared"], ["home"]])
    }

    private static func checkTokens() async throws {
        let client = GoogleCalendarClient(clientID: "dev.apps.googleusercontent.com", clientSecret: "test-secret")
        let redirect = URL(string: "http://127.0.0.1:12345/oauth2/callback")!
        let api = GoogleCalendarAPI { url, method, headers, body in
            precondition(url == "https://oauth2.googleapis.com/token" && method == "POST")
            precondition(headers["Content-Type"] == "application/x-www-form-urlencoded")
            let form = String(decoding: body ?? Data(), as: UTF8.self)
            if form.contains("grant_type=refresh_token") {
                throw HTTP.Failure.status(400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            precondition(form.contains("code_verifier=verifier") && form.contains("code=abc%2B123"))
            precondition(form.contains("client_secret=test-secret"))
            let scope = GoogleCalendarAuthorization.scopes.joined(separator: " ")
            return Data("""
            {"access_token":"access","refresh_token":"refresh","scope":"\(scope)"}
            """.utf8)
        }
        let grant = try await api.redeem("abc+123", client: client, redirect: redirect, verifier: "verifier")
        precondition(grant.refreshToken == "refresh")
        do {
            _ = try await api.refresh("refresh", client: client)
            preconditionFailure("Expected to reconnect after token expiry")
        } catch GoogleCalendarError.reconnect {}

        let inadequate = GoogleCalendarAPI { _, _, _, _ in
            Data(#"{"access_token":"access","refresh_token":"refresh","scope":"ignored"}"#.utf8)
        }
        do {
            _ = try await inadequate.redeem("code", client: client, redirect: redirect, verifier: "verifier")
            preconditionFailure("Expected a partial grant to be rejected")
        } catch GoogleCalendarError.missingScopes {}
    }

    private static func checkCalendars() async throws {
        let api = GoogleCalendarAPI { url, method, headers, body in
            precondition(url.hasPrefix("https://www.googleapis.com/calendar/v3/users/me/calendarList?"))
            precondition(method == "GET" && headers["Authorization"] == "Bearer access" && body == nil)
            if url.contains("pageToken=page2") {
                return Data(#"{"items":[{"id":"work","summary":"Work","summaryOverride":"Client"}]}"#.utf8)
            }
            return Data(#"{"items":[{"id":"pilot@example.com","summary":"Primary","primary":true}],"nextPageToken":"page2"}"#.utf8)
        }
        let calendars = try await api.calendars(accessToken: "access")
        precondition(calendars.map(\.name) == ["Primary", "Client"])
        precondition(calendars.first?.primary == true)

        let repeating = GoogleCalendarAPI { _, _, _, _ in Data(#"{"nextPageToken":"loop"}"#.utf8) }
        do {
            _ = try await repeating.calendars(accessToken: "access")
            preconditionFailure("Expected cycling pagination to fail")
        } catch GoogleCalendarError.incomplete {}
    }

    private static func checkMeetings() async throws {
        let api = GoogleCalendarAPI { url, _, _, _ in
            precondition(url.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/shared%40example.com/events?"))
            precondition(url.contains("singleEvents=true") && url.contains("showDeleted=false"))
            return Data(#"""
            {"items":[
              {"id":"accepted","summary":"Accepted","start":{"dateTime":"2026-11-23T13:00:00.250+01:00"},"end":{"dateTime":"2026-11-23T14:00:00+01:00"},"attendees":[{"email":"Pilot@example.com","responseStatus":"accepted"}]},
              {"id":"other","summary":"Other calendar owner","start":{"dateTime":"2026-11-23T12:00:00Z"},"end":{"dateTime":"2026-11-23T13:00:00Z"},"attendees":[{"self":true,"responseStatus":"accepted"}]},
              {"id":"declined","start":{"dateTime":"2026-11-23T12:00:00Z"},"end":{"dateTime":"2026-11-23T13:00:00Z"},"attendees":[{"email":"pilot@example.com","responseStatus":"declined"}]},
              {"id":"allDay","start":{"date":"2026-11-23"},"end":{"date":"2026-11-24"},"attendees":[{"email":"pilot@example.com","responseStatus":"accepted"}]},
              {"id":"cancelled","status":"cancelled","start":{"dateTime":"2026-11-23T12:00:00Z"},"end":{"dateTime":"2026-11-23T13:00:00Z"},"attendees":[{"email":"pilot@example.com","responseStatus":"accepted"}]},
              {"id":"organized","status":"confirmed","start":{"dateTime":"2026-11-23T12:00:00Z"},"end":{"dateTime":"2026-11-23T13:00:00Z"},"organizer":{"email":"pilot@example.com"}},
              {"id":"focus","status":"confirmed","eventType":"focusTime","start":{"dateTime":"2026-11-23T12:00:00Z"},"end":{"dateTime":"2026-11-23T13:00:00Z"},"organizer":{"email":"pilot@example.com"}}
            ]}
            """#.utf8)
        }
        let events = try await api.meetings(calendarID: "shared@example.com", primaryCalendarID: "pilot@example.com",
                                            start: Date(timeIntervalSince1970: 1_790_000_000),
                                            end: Date(timeIntervalSince1970: 1_810_000_000), accessToken: "access")
        precondition(events.map(\.id.eventID) == ["accepted", "organized"])
        precondition(events.map(\.title) == ["Accepted", "Meeting"])
        precondition(events.first?.start.timeIntervalSince(events[1].start) == 0.25)
    }
}
