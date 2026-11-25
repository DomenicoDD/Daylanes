import SwiftUI
import UniformTypeIdentifiers

struct ScheduledMeetings: View {
    @EnvironmentObject private var connection: GoogleCalendarConnection
    let start: Date
    let end: Date

    var body: some View {
        let meetings = GoogleCalendarAPI.Meeting.schedule(connection.accounts.flatMap(\.meetings), from: start, to: end)
        Group {
            if !meetings.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(meetings, id: \.occurrence) { meeting in
                            HStack {
                                Text(meeting.title).lineLimit(2).privacySensitive()
                                Spacer()
                                Text(meeting.start...meeting.end).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Scheduled meetings (\(meetings.count))", systemImage: "calendar")
                        .font(.headline)
                }
                .padding(12)
                .background(Theme.block, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { await connection.refreshForTimeline() }
    }
}

struct GoogleCalendarSettings: View {
    @EnvironmentObject private var connection: GoogleCalendarConnection
    @State private var chooseClient = false

    var body: some View {
        IntegrationCard(
            title: "Google Calendar", icon: "calendar", connected: !connection.accounts.isEmpty,
            problem: connection.problem ?? connection.accounts.compactMap(\.problem).first,
            account: accountSummary,
            purpose: "Show accepted invitations and meetings you organize in Timeline. Calendar access is read-only and event details stay on this Mac."
        ) {
            Link("Google Calendar privacy", destination: URL(string: "https://daylanes.app/privacy#google-calendar")!)
                .font(.callout)
            ForEach(connection.accounts) { account in
                Divider()
                GoogleCalendarAccountSettings(account: account, connection: connection)
                    .disabled(connection.busy || connection.awaitingConsent)
            }
            if let problem = connection.problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            controls
        }
        .task { await connection.load() }
        .fileImporter(isPresented: $chooseClient, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            Task { await connection.importClient(result) }
        }
    }

    private var accountSummary: String? {
        let count = connection.accounts.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 account connected" : "\(count) accounts connected"
    }

    private var controls: some View {
        HStack {
            if connection.awaitingConsent {
                ProgressView().controlSize(.small)
                Text("Waiting for Google sign-in…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { connection.cancelConnect() }
            } else if connection.busy {
                ProgressView().controlSize(.small)
            } else if !connection.loaded {
                Button("Try again") { Task { await connection.load() } }
            } else if connection.clientConfigured {
                Button(connection.accounts.isEmpty ? "Connect…" : "Add Google account…") { connection.connect() }
                    .buttonStyle(.borderedProminent)
                if !connection.bundledClientAvailable && connection.accounts.isEmpty {
                    Spacer()
                    Button("Change OAuth client…") { chooseClient = true }
                }
            } else {
                Button("Import Desktop OAuth client…") { chooseClient = true }
            }
        }
    }
}

private struct GoogleCalendarAccountSettings: View {
    let account: GoogleCalendarConnection.Account
    @ObservedObject var connection: GoogleCalendarConnection
    @State private var calendarsExpanded: Bool

    init(account: GoogleCalendarConnection.Account, connection: GoogleCalendarConnection) {
        self.account = account
        self.connection = connection
        _calendarsExpanded = State(initialValue: account.selected.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.address).font(.subheadline.weight(.semibold))

            if let problem = account.problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            } else if let checkedAt = account.lastMeetingCheck {
                Label("Meeting access verified · \(checkedAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !account.calendars.isEmpty || !account.selected.isEmpty {
                DisclosureGroup("Calendars (\(account.selected.count) selected)", isExpanded: $calendarsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(account.calendars) { calendar in
                            Toggle(calendar.name, isOn: calendarSelection(calendar.id))
                        }
                        ForEach(unavailableCalendars, id: \.self) { id in
                            Toggle(isOn: calendarSelection(id)) {
                                Text(id)
                                Text("Unavailable")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                if account.needsReconnect {
                    Button("Reconnect…") { connection.connect(reconnecting: account.id) }
                        .accessibilityLabel("Reconnect \(account.address)")
                        .disabled(!connection.clientConfigured)
                } else {
                    Button("Check access") { Task { await connection.sync(account.id) } }
                        .accessibilityLabel("Check Calendar access for \(account.address)")
                }
                Spacer()
                Button("Disconnect") { Task { await connection.disconnect(account.id) } }
                    .accessibilityLabel("Disconnect \(account.address)")
            }
        }
    }

    private var unavailableCalendars: [String] {
        account.selected.subtracting(account.calendars.map(\.id)).sorted()
    }

    private func calendarSelection(_ calendarID: String) -> Binding<Bool> {
        Binding(
            get: { account.selected.contains(calendarID) },
            set: { enabled in
                Task { await connection.chooseCalendar(calendarID, accountID: account.id, selected: enabled) }
            }
        )
    }
}
