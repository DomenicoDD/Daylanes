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

/// The menu bar: New Project and Export in File, the pages in View, snoozing and setup in Tracking, and Help
/// for help and links only. Help search still finds every item, since it searches all menus.
struct AppMenuCommands: Commands {
    @ObservedObject var recorder: FocusRecorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { main(.newProject) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Client…") { main(.newClient) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .importExport) {
            Button("Export CSV…") { main(.exportCSV) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            page("Overview", .overview, key: "1")
            page("Timeline", .timeline, key: "2")
            page("Diary", .diary, key: "3")
            page("Review", .review, key: "4")
            page("Reports", .reports, key: "5")
            page("Clients", .clients, key: "6")
            page("Projects", .projects, key: "7")
            Divider()
        }
        CommandMenu("Tracking") {
            SnoozeMenuItems(recorder: recorder)
                .disabled(!recorder.ready)
            Divider()
            Button("Set Up a Diary…") { main(.diarySetup) }
            Button("Connect an Agent…") { connectAgent() }
            Button("Integrations…") { settings(.integrations) }
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started…") { main(.welcome) }
            link("Guide: Tracking Time for AI Coding Agents", SiteLinks.agentGuide)
            Divider()
            link("Daylanes Website", SiteLinks.website)
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
