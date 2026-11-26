import AppKit
import SwiftUI

/// Public pages on the Daylanes website. The app links to the website only, never straight to a
/// store: daylanes.app/chrome decides where to send people (the Chrome Web Store once the listing
/// is live, an install note until then), so the app never needs an update when that changes.
enum SiteLinks {
    static let website = URL(string: "https://daylanes.app")!
    static let chromeExtension = URL(string: "https://daylanes.app/chrome")!
    static let agentGuide = URL(string: "https://daylanes.app/guides/track-time-for-ai-coding-agents")!
    static let privacy = URL(string: "https://daylanes.app/privacy")!
    static let extensionPrivacy = URL(string: "https://daylanes.app/privacy/extension")!
    static let terms = URL(string: "https://daylanes.app/terms")!
    static let source = URL(string: "https://github.com/DomenicoDD/Daylanes")!
    static let issues = URL(string: "https://github.com/DomenicoDD/Daylanes/issues/new")!
    static let support = URL(string: "mailto:support@daylanes.app")!
}

/// Requests from menus (mainly Help) for the main window or the Settings window. Each window reads the
/// request that concerns it and clears it, so a window that opens because of the request still sees it.
@MainActor
final class AppRoute: ObservableObject {
    static let shared = AppRoute()

    enum Request: Equatable {
        case page(Page)
        case newProject, newClient, diarySetup, exportCSV, welcome
    }

    /// Handled by the main window.
    @Published var request: Request?
    /// Handled by the Diary page once the main window shows it.
    @Published var diarySetup = false
    /// Handled by the Settings window.
    @Published var showAgentSetup = false
}

/// Replaces the default Help menu, which only says help isn't available. Every page, settings section,
/// integration and main action is listed here, so typing in the Help menu's search field finds it and
/// choosing the result opens it.
struct HelpMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Menu("Pages") {
                page("Overview", .overview, key: "1")
                page("Timeline", .timeline, key: "2")
                page("Diary", .diary, key: "3")
                page("Review", .review, key: "4")
                page("Reports", .reports, key: "5")
                page("Clients", .clients, key: "6")
                page("Projects", .projects, key: "7")
            }
            Menu("Settings") {
                ForEach(SettingsSection.allCases) { section in
                    Button(section.rawValue) { settings(section) }
                }
                Divider()
                Button("Automatic Time Tracking and Snooze") { settings(.general) }
                Button("Permissions and Startup") { settings(.general) }
                Button("Billing Rates") { settings(.ai) }
                Button("Exchange Rate for Billing") { settings(.ai) }
                Button("Subscriptions") { settings(.ai) }
                Button("Token Prices") { settings(.ai) }
                Button("Ledger Location") { settings(.privacy) }
                Button("Credentials and External Requests") { settings(.privacy) }
            }
            Menu("Integrations") {
                Button("Agent Access (MCP)…") { connectAgent() }
                Button("Toggl Track") { settings(.integrations) }
                Button("GitHub") { settings(.integrations) }
                Button("Browser Extension") { settings(.integrations) }
                Button("Chrome Profile Clients") { settings(.integrations) }
                #if TRACKER_GOOGLE_CALENDAR
                Button("Google Calendar") { settings(.integrations) }
                #endif
                Divider()
                ForEach(AIProvider.allCases) { provider in
                    Button("\(provider.name) Usage") { settings(.integrations) }
                }
            }
            Divider()
            Button("New Project…") { main(.newProject) }
            Button("New Client…") { main(.newClient) }
            Button("Set Up a Diary…") { main(.diarySetup) }
            Button("Connect an Agent…") { connectAgent() }
            Button("Export CSV…") { main(.exportCSV) }
            Button("Show Welcome…") { main(.welcome) }
            Divider()
            link("Daylanes Website", SiteLinks.website)
            link("Guide: Tracking Time for AI Coding Agents", SiteLinks.agentGuide)
            link("Get the Chrome Extension", SiteLinks.chromeExtension)
            link("Privacy Policy", SiteLinks.privacy)
            link("Browser Extension Privacy", SiteLinks.extensionPrivacy)
            link("Terms", SiteLinks.terms)
            Divider()
            link("Source Code on GitHub", SiteLinks.source)
            link("Report a Problem…", SiteLinks.issues)
            link("Contact Support…", SiteLinks.support)
        }
    }

    private func page(_ title: String, _ page: Page, key: KeyEquivalent) -> some View {
        Button(title) { main(.page(page)) }
            .keyboardShortcut(key, modifiers: .command)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.open(url) }
    }

    private func main(_ request: AppRoute.Request) {
        openWindow(id: "main")
        AppRoute.shared.request = request
    }

    private func settings(_ section: SettingsSection) {
        UserDefaults.standard.set(section.rawValue, forKey: "settingsTab")
        openSettings()
    }

    private func connectAgent() {
        AppRoute.shared.showAgentSetup = true
        settings(.integrations)
    }
}
