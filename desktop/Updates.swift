import AppKit
import SwiftUI

/// Looks for a newer Daylanes on daylanes.app: shortly after launch, then every six hours while the
/// app runs, and whenever someone chooses Check for Updates… in the app menu. The request carries no
/// install ID or licence key. A newer version shows a small notice at the bottom of the sidebar.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// The newer version, when there is one.
    @Published private(set) var available: UpdateFeed?
    @Published private(set) var checking = false

    private var started = false
    /// The request under way, shared so a manual check during a background one still gets an answer.
    private var inFlight: Task<UpdateFeed?, Error>?
    private let interval: TimeInterval = 6 * 3600

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(10))
            while true {
                _ = try? await fetch()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Check for Updates…: always answers, even when nothing is new or the check fails.
    func checkNow() {
        Task {
            let alert = NSAlert()
            do {
                if let feed = try await fetch() {
                    show(feed)
                    return
                }
                alert.messageText = "Daylanes is up to date"
                alert.informativeText = "You have the newest version, \(installedVersion)."
            } catch {
                alert.alertStyle = .warning
                alert.messageText = "Daylanes couldn't check for updates"
                alert.informativeText = "\(error.localizedDescription) Check your internet connection and try again."
            }
            NSApp.activate()
            alert.runModal()
        }
    }

    /// The sidebar notice: explains what's new and offers the download.
    func show(_ feed: UpdateFeed) {
        let alert = NSAlert()
        alert.messageText = "Daylanes \(feed.version) is available"
        var text = "You have \(installedVersion)."
        if let notes = feed.notes, !notes.isEmpty { text += "\n\n" + notes }
        text += "\n\nDownload it, open the installer and drag Daylanes into Applications to replace this copy. Your data and licence stay as they are."
        alert.informativeText = text
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { download(feed) }
    }

    func download(_ feed: UpdateFeed) {
        #if TRACKER_PAYMENTS
        let link = feed.download(for: UpdateFeed.currentArchitecture)
        #else
        // A build from source updates from source; the official installer would ask for a licence.
        let link = URL(string: "https://github.com/DomenicoDD/Daylanes")
        #endif
        if let link { NSWorkspace.shared.open(link) }
    }

    /// Downloads the feed and returns it when it names a newer version than this one. A call made
    /// while a request is under way waits for that request instead of starting another.
    @discardableResult
    private func fetch() async throws -> UpdateFeed? {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await loadFeed() }
        inFlight = task
        checking = true
        defer {
            inFlight = nil
            checking = false
        }
        return try await task.value
    }

    private func loadFeed() async throws -> UpdateFeed? {
        var request = URLRequest(url: UpdateFeed.address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Daylanes/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
        available = UpdateFeed.isNewer(feed.version, than: installedVersion) ? feed : nil
        return available
    }
}

/// Check for Updates… under About Daylanes in the app menu.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
        }
    }
}

/// A small pill for the bottom of the sidebar, shown only when a newer version exists.
struct UpdateAvailableNotice: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        if let feed = updates.available {
            Button {
                updates.show(feed)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text("Update available")
                        .foregroundStyle(Color.white.opacity(0.9))
                    Spacer(minLength: 4)
                    Text(feed.version)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.sidebarSelected, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Daylanes \(feed.version) is available. Click to see what's new and download it.")
            .accessibilityLabel("Update available: Daylanes \(feed.version)")
        }
    }
}
