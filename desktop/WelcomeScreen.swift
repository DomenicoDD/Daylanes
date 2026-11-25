import AppKit
import SwiftUI

struct WelcomeScreen: View {
    private enum Step: Int { case welcome, permissions, project }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LedgerModel
    @EnvironmentObject private var recorder: FocusRecorder
    @State private var step = Step.welcome
    @State private var windowTitlesAuthorized = WindowTitles.authorized
    @State private var installedAgents: [String] = []
    @State private var name = ""
    @State private var client = ""
    @State private var rate = ""
    @State private var saving = false
    @State private var saveError: String?

    var onProjectCreated: (String) -> Void = { _ in }

    private var selfClient: String { model.snapshot?.selfClient ?? "Me" }
    private var chosenClient: String { client.trimmed.isEmpty ? selfClient : client.trimmed }
    private var isBillable: Bool { chosenClient != selfClient }
    private var invalidRate: Bool { isBillable && !rate.trimmed.isEmpty && normalizedAmount(rate) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .project: project
                }
            }
            .frame(maxWidth: .infinity, minHeight: 356, alignment: .topLeading)
            .padding(28)
            Divider()
            footer.padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 560)
        .background(Theme.card)
        .interactiveDismissDisabled(saving)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().aspectRatio(contentMode: .fit).frame(width: 56, height: 56)
                .accessibilityHidden(true)
            heading("Welcome to Daylanes", detail: "Your time and your agents’ time, on one calendar.")
            VStack(alignment: .leading, spacing: 12) {
                row("Day calendar", detail: "See your app time and agent sessions side by side.", icon: "calendar.day.timeline.left")
                row("Agent history", detail: "Import local sessions from Codex, Claude Code, and OpenCode.", icon: "sparkles")
                row("Ready to bill", detail: "Set rates by client or project and export invoice reports.", icon: "banknote")
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Tracking and permissions", detail: "Daylanes can start tracking apps right away. Set up the sources you want to use.")
            VStack(spacing: 0) {
                row("Window titles", detail: "Use window titles to match time to projects.", icon: "macwindow") {
                    if windowTitlesAuthorized {
                        status("Granted")
                    } else {
                        Button("Set up") { WindowTitles.requestAccess() }
                            .accessibilityLabel("Set up window title access")
                    }
                }.padding(.vertical, 10)
                Divider()
                row("Websites", detail: "The browser extension matches tab addresses to projects.", icon: "globe") {
                    if recorder.chromeExtensionReply != nil {
                        status("Connected")
                    } else if case .installed = recorder.chromeSetup {
                        Button("Show extension") {
                            NSWorkspace.shared.activateFileViewerSelecting([ChromeBridge.extensionFolder])
                        }
                        .help("Open chrome://extensions, enable Developer mode, and load this folder.")
                    } else {
                        Text("Optional").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10)
                Divider()
                row("Agent history", detail: installedAgents.isEmpty ? "Local agent history appears as you use your coding tools." : installedAgents.formatted(.list(type: .and)), icon: "folder") {
                    if !installedAgents.isEmpty { status("Found") }
                }.padding(.vertical, 10)
                Divider()
                row("GitHub", detail: model.gitHubStatus?.description ?? "Check GitHub CLI to connect pull requests.", icon: "arrow.triangle.pull") {
                    if model.gitHubStatus == .connected {
                        status("Connected")
                    } else {
                        Button("Check") { Task { await model.checkGitHub() } }
                            .accessibilityLabel("Check GitHub sign-in")
                    }
                }.padding(.vertical, 10)
            }
        }
        .task {
            let roots = AgentLogs.roots(codex: nil, claude: nil)
            let sources = [("Codex", roots["codex"] ?? []), ("Claude Code", roots["claude"] ?? []),
                           ("OpenCode", AgentLogs.openCodeDatabases(nil))]
            installedAgents = sources.compactMap { name, paths in
                paths.contains { FileManager.default.fileExists(atPath: $0) } ? name : nil
            }
            while !Task.isCancelled {
                windowTitlesAuthorized = WindowTitles.authorized
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var project: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Your first project", detail: "Give your time somewhere to land. You can also create a project later.")
            VStack(alignment: .leading, spacing: 13) {
                field("Project name", prompt: "e.g. Website redesign", value: $name)
                field("Client", prompt: selfClient, value: $client)
                if isBillable {
                    let currency = model.snapshot?.currency ?? "EUR"
                    field("Hourly rate (optional)", prompt: "\(currency) per hour", value: $rate)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                } else if invalidRate {
                    Text("Enter a rate with up to two decimal places, or leave it blank.")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(saving)
            Spacer(minLength: 0)
            #if TRACKER_PAYMENTS
            Text("\(Licensing.trialDays)-day free trial, then a licence is required. Buy before it ends for \(Licensing.trialPrice) USD.")
                .font(.callout).foregroundStyle(.secondary)
            #endif
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip") { dismiss() }.keyboardShortcut(.cancelAction)
            Text("\(step.rawValue + 1) of 3").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Step \(step.rawValue + 1) of 3")
            Spacer()
            if let previous = Step(rawValue: step.rawValue - 1) {
                Button("Back") { step = previous }
            }
            if let next = Step(rawValue: step.rawValue + 1) {
                Button("Continue") { step = next }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                if saving { ProgressView().controlSize(.small) }
                Button("Start tracking", action: startTracking)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(invalidRate || (!name.trimmed.isEmpty && model.snapshot == nil))
            }
        }
        .disabled(saving)
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 30, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ title: String, detail: String, icon: String) -> some View {
        row(title, detail: detail, icon: icon) { EmptyView() }
    }

    private func row<Trailing: View>(_ title: String, detail: String, icon: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 29)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            trailing().fixedSize()
        }
    }

    private func status(_ title: String) -> some View {
        Label(title, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.Tint.green.ink)
    }

    private func field(_ title: String, prompt: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            TextField(title, text: value, prompt: Text(prompt)).labelsHidden()
        }
    }

    private func startTracking() {
        let project = name.trimmed
        guard !project.isEmpty else { dismiss(); return }
        guard !invalidRate, !saving else { return }
        var args = ["project", "add", "--new-only", "--kind", isBillable ? "billable" : "internal",
                    "--client=\(chosenClient)"]
        if isBillable, let amount = normalizedAmount(rate) { args += ["--human-rate=\(amount)"] }
        args += ["--", project]
        saveError = nil
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await Ledger.run(args)
            } catch {
                saveError = error.localizedDescription
                return
            }
            await model.reload()
            if model.snapshot?.projects.contains(where: { $0.name == project }) == true {
                onProjectCreated(project)
            }
            dismiss()
        }
    }
}
