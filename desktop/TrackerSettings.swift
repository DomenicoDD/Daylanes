import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    #if TRACKER_PAYMENTS
    case account = "Account"
    #endif
    case integrations = "Integrations"
    case ai = "Pricing"
    case privacy = "Privacy"

    var id: Self { self }

    var icon: String {
        switch self {
        case .general: "gearshape"
        #if TRACKER_PAYMENTS
        case .account: "person.crop.circle"
        #endif
        case .integrations: "link"
        case .ai: "creditcard"
        case .privacy: "lock.shield"
        }
    }

    /// The short line under the section's card and in the header.
    var detail: String {
        switch self {
        case .general: "Tracking and startup"
        #if TRACKER_PAYMENTS
        case .account: "Licence and purchase"
        #endif
        case .integrations: "Services and agents"
        case .ai: "Rates and AI costs"
        case .privacy: "Your data"
        }
    }

    var summary: String {
        switch self {
        case .general: "How Daylanes tracks your time, and the permissions it needs."
        #if TRACKER_PAYMENTS
        case .account: "Your licence, trial and purchase."
        #endif
        case .integrations: "Connect the services and agents Daylanes reads from. Keys stay in macOS Keychain."
        case .ai: "What you bill clients, and what your AI tools cost."
        case .privacy: "Where your ledger lives and what leaves this Mac."
        }
    }
}

private enum SettingsSheet: Identifiable {
    case price(ModelPrice)
    case subscription(Subscription?)
    case openRouter, togglKey, togglImport, agentSetup
    case providerCredential(AIProvider)
    case providerKey(AIProvider, ProviderUsage.Line)
    case repository(Project)
    case billing(BillingEditor.Scope, String)

    var id: String {
        switch self {
        case .price: "price"
        case .subscription: "subscription"
        case .openRouter: "openrouter"
        case let .providerCredential(provider): "credential-" + provider.rawValue
        case let .providerKey(provider, key): "key-" + provider.rawValue + "-" + key.id
        case .togglKey: "toggl-key"
        case .togglImport: "toggl-import"
        case .agentSetup: "agent-setup"
        case .repository: "github-repository"
        case .billing: "billing"
        }
    }
}

/// The standard macOS Settings window (⌘,), with one tab per section.
struct SettingsWindow: View {
    @EnvironmentObject private var recorder: FocusRecorder
    @EnvironmentObject private var model: LedgerModel
    @AppStorage("settingsTab") private var tab: SettingsSection = .general
    @State private var sheet: SettingsSheet?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Settings", subtitle: tab.summary, topInset: 18)
            SheetModePicker(selection: $tab, options: SettingsSection.allCases.map {
                SheetModeOption(value: $0, title: $0.rawValue, detail: $0.detail, icon: $0.icon)
            })
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)
            page(tab)
                .id(tab)
        }
        .background(SheetTheme.body)
        .foregroundStyle(Theme.text)
        .tint(SheetTheme.accent)
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowChrome())
        .navigationTitle("Settings")
        .frame(width: 680, height: 640)
        // The Settings scene draws its own opaque title bar over the content; hide it and its title
        // so the dark header runs up behind the traffic lights.
        .hidingWindowTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(item: $sheet) { editor($0) }
        .onReceive(AppRoute.shared.$showAgentSetup) { show in
            guard show else { return }
            DispatchQueue.main.async { AppRoute.shared.showAgentSetup = false }
            tab = .integrations
            sheet = .agentSetup
        }
        .alert("Daylanes", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder
    private func page(_ section: SettingsSection) -> some View {
        if let snapshot = model.snapshot {
            ScrollView {
                TrackerSettings(snapshot: snapshot, model: model, section: section,
                                editPlan: { sheet = .subscription($0) },
                                editPrice: { sheet = .price($0) },
                                editBilling: { sheet = .billing($0, $1) },
                                manageOpenRouter: { sheet = .openRouter },
                                manageProvider: { sheet = .providerCredential($0) },
                                assignProviderKey: { sheet = .providerKey($0, $1) },
                                manageToggl: { sheet = .togglKey },
                                importToggl: { sheet = .togglImport },
                                showAgentSetup: { sheet = .agentSetup })
                    .buttonStyle(SheetButtonStyle(kind: .secondary))
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .bottom) {
                if let busy = model.busy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                }
            }
        } else {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func editor(_ item: SettingsSheet) -> some View {
        switch item {
        case let .price(price):
            PriceEditor(price: price, currency: model.snapshot?.currency ?? "EUR") { values in
                sheet = nil
                Task {
                    await model.perform("Saving token prices…") {
                        var args = ["model-rate", price.provider, price.model]
                        for (flag, value) in zip(["--input", "--cached", "--cache-write", "--output"], values) {
                            args += [flag, value]
                        }
                        _ = try await Ledger.run(args)
                        try await model.update()
                        model.notice = "Token prices saved"
                    }
                }
            }
        case let .subscription(plan):
            SubscriptionEditor(plan: plan, currency: model.snapshot?.currency ?? "EUR") { name, amount, provider in
                sheet = nil
                Task {
                    await model.perform("Saving subscription…") {
                        var args = ["subscription", "remove", "--", name]
                        if let amount {
                            args = ["subscription", "set", "--monthly", amount, "--provider=\(provider)"]
                            if plan == nil { args += ["--new-only"] }
                            args += ["--", name]
                        }
                        _ = try await Ledger.run(args)
                        try await model.update()
                        model.notice = amount == nil ? "Subscription removed" : "Subscription saved"
                    }
                }
            }
        case .openRouter:
            OpenRouterEditor(connected: model.openRouterConnected || model.snapshot?.openrouterAccount != nil) { key in
                sheet = nil
                Task { await model.setOpenRouterKey(key) }
            }
        case let .providerCredential(provider):
            let connected = model.snapshot?.providerUsage?.contains { $0.provider == provider } == true
            ProviderCredentialEditor(provider: provider, connected: connected) { credential in
                sheet = nil
                Task { await model.setProviderCredential(provider, credential: credential) }
            }
        case let .providerKey(provider, key):
            ProviderKeyEditor(provider: provider, key: key, projects: model.snapshot?.projects ?? []) { project, alias in
                sheet = nil
                Task { await model.assignProviderKey(provider, keyID: key.id, project: project, alias: alias) }
            }
        case .togglKey:
            TogglTokenEditor(connected: model.togglConnected) { key in
                sheet = nil
                Task { await model.setTogglKey(key) }
            }
        case .togglImport:
            if let snapshot = model.snapshot, let projects = model.togglProjects {
                let workspace = snapshot.togglAccount?.workspaceId
                TogglImportEditor(sources: projects.filter { workspace == nil || $0.workspaceId == nil || $0.workspaceId == workspace },
                                  snapshot: snapshot) { source, destination, start, end in
                    sheet = nil
                    Task { await model.importToggl(source, into: destination, start: start, end: end) }
                }
            }
        case .agentSetup:
            if let snapshot = model.snapshot { AgentMCPSetup(database: snapshot.database) }
        case let .repository(project):
            RepoEditor(project: project) { repo in
                sheet = nil
                Task { await model.updateRepository(project, repo: repo, recorder: recorder) }
            }
        case let .billing(scope, name):
            let listing = model.snapshot?.billingTerms
            let client = scope == .project ? model.snapshot?.projects.first { $0.name == name }?.client : nil
            BillingEditor(scope: scope, name: name, client: client,
                          existing: (scope == .client ? listing?.client(name) : listing?.project(name)) ?? .empty,
                          inherited: client.flatMap { listing?.client($0) } ?? .empty,
                          currency: model.snapshot?.currency ?? "EUR") { arguments in
                sheet = nil
                Task {
                    await model.perform("Saving billing rates…") {
                        _ = try await Ledger.run(arguments)
                        try await model.update()
                        model.notice = "Billing rates saved"
                    }
                }
            }
        }
    }
}

struct TrackerSettings: View {
    let snapshot: Snapshot
    @ObservedObject var model: LedgerModel
    let section: SettingsSection
    let editPlan: (Subscription?) -> Void
    let editPrice: (ModelPrice) -> Void
    let editBilling: (BillingEditor.Scope, String) -> Void
    let manageOpenRouter: () -> Void
    let manageProvider: (AIProvider) -> Void
    let assignProviderKey: (AIProvider, ProviderUsage.Line) -> Void
    let manageToggl: () -> Void
    let importToggl: () -> Void
    let showAgentSetup: () -> Void
    @EnvironmentObject private var recorder: FocusRecorder
    @State private var modelFilter = ""
    @State private var showWelcome = false
    @State private var usdRate: String?
    @State private var chromeHelperRunning = false

    private var busy: Bool { model.busy != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch section {
            case .general: general
            #if TRACKER_PAYMENTS
            case .account: AccountSettings()
            #endif
            case .integrations: integrations
            case .ai:
                billingRates
                exchangeRate
                subscriptions
                tokenPrices
            case .privacy: privacy
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 19) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    heading("Automatic time tracking")
                    Spacer()
                    Menu(recorder.enabled ? "Snooze" : "Resume") {
                        SnoozeMenuItems(recorder: recorder)
                    }
                    .fixedSize()
                    .disabled(!recorder.ready)
                }
                TrackingStatusText(recorder: recorder).font(.caption).foregroundStyle(.secondary)
                Text("Tracking is always on: Daylanes records the app in the foreground and skips time after two minutes without input. Snooze it for a while when you need to; it resumes by itself. To leave an app or site out for good, add a don’t-track rule.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                heading("Permissions and startup")
                Text("These apply to all tracking. Rules that route time to a project are set on each project’s page, and every project is also matched by its own name and its client’s name.")
                    .foregroundStyle(.secondary)
                TrackingPermissions()
            }
            Divider()
            Button("Show Welcome…") { showWelcome = true }
                .sheet(isPresented: $showWelcome) { WelcomeScreen() }
        }
    }

    /// One card per integration: what it is, whether it is connected and as whom, and the steps to connect.
    private var integrations: some View {
        VStack(alignment: .leading, spacing: 16) {
            agentCard
            togglCard
            gitHubCard
            chromeCard
            #if TRACKER_GOOGLE_CALENDAR
            GoogleCalendarSettings()
            #endif
            heading("AI provider usage")
            openRouterCard
            ForEach(AIProvider.allCases.filter { $0 != .openrouter }) { provider in
                providerCard(provider)
            }
        }
        .task { await model.checkGitHub() }
        .task { chromeHelperRunning = TrackerChromeClient.helperRunning() }
    }

    private var agentCard: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsIcon(name: "terminal")
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent access (MCP)").font(.system(size: 13, weight: .semibold))
                Text("Let Codex, Claude Code or another agent on this Mac read your ledger.")
                    .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Connect an agent…", action: showAgentSetup)
                .buttonStyle(SheetButtonStyle(kind: .primary))
        }
        .padding(14)
        .modifier(SettingsCard())
    }

    private var togglCard: some View {
        let account = snapshot.togglAccount
        let connected = model.togglConnected
        let names: [String] = [account?.name ?? "", account?.email ?? ""].filter { !$0.isEmpty }
        let who: String? = connected ? (names.isEmpty ? "Connected" : names.joined(separator: " · ")) : nil
        return IntegrationCard(
            title: "Toggl Track", icon: "timer", connected: connected,
            problem: model.togglKeychainMessage, account: who,
            purpose: "Imports your Toggl time into Daylanes projects. Read-only: Daylanes never changes your Toggl data."
        ) {
            if connected {
                if let account, account.workspaces.count > 1 {
                    Picker("Workspace", selection: Binding(
                        get: { account.workspaceId ?? account.workspaces[0].id },
                        set: { id in Task { await model.chooseTogglWorkspace(id) } })) {
                        ForEach(account.workspaces) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 320)
                } else if let name = account?.workspaceName {
                    LabeledContent("Workspace", value: name)
                }
                HStack {
                    Button("Import time…") {
                        Task {
                            if model.togglProjects == nil { await model.loadTogglProjects() }
                            if model.togglProjects?.isEmpty == false && !snapshot.projects.isEmpty { importToggl() }
                        }
                    }
                    Spacer()
                    Button("Disconnect…", action: manageToggl)
                }
                if let message = model.togglKeychainMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                IntegrationStep(number: 1, text: "Copy your API token from your Toggl Track profile.") {
                    Link("Open profile", destination: URL(string: "https://track.toggl.com/profile")!)
                }
                IntegrationStep(number: 2, text: "Paste it here. Daylanes checks it with Toggl before saving it to Keychain.") {
                    Button("Connect…", action: manageToggl).buttonStyle(SheetButtonStyle(kind: .primary))
                }
                IntegrationStep(number: 3, text: "Pick the workspace to import from, if you have more than one.") { EmptyView() }
            }
        }
        .disabled(busy)
    }

    private var chromeCard: some View {
        let setup = recorder.chromeSetup
        let answered = recorder.chromeExtensionReply
        let connected = chromeHelperRunning || answered != nil
        let problem: String? = switch setup {
        case let .failed(message): "Daylanes couldn’t install its Chrome helper: \(message)"
        case .notBundled: "This build has no Chrome helper. Rebuild with bin/build-desktop."
        default: nil
        }
        let account: String? = if let answered {
            "Last tab received \(answered.formatted(date: .omitted, time: .shortened))"
        } else if chromeHelperRunning {
            "Extension connected. Tabs arrive while tracking and Chrome is in front"
        } else {
            nil
        }
        return IntegrationCard(
            title: "Browser extension", icon: "globe", connected: connected, problem: problem, account: account,
            purpose: "Sends the active tab’s site and path, and an optional label per browser profile, to Daylanes on this Mac. Works in Chrome, Edge, Brave, Arc, Vivaldi and Chromium. Nothing leaves your computer."
        ) {
            if setup == .noBrowser {
                Text("No Chromium browser such as Chrome, Edge, Brave or Arc is installed for this user.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if !connected {
                    IntegrationStep(number: 1, text: installedText(setup), done: installed(setup)) {
                        if setup == nil { ProgressView().controlSize(.small) }
                    }
                    IntegrationStep(number: 2, text: "In your browser, open this page and turn on Developer mode. Edge, Brave and Arc redirect it to their own page.") {
                        CommandButton(command: "chrome://extensions")
                    }
                    IntegrationStep(number: 3, text: "Drag the extension folder onto that page, or choose Load unpacked and select it. Remove any older Tracker for Chrome first.") {
                        Button("Show folder") { revealChromeExtension() }.buttonStyle(SheetButtonStyle(kind: .primary))
                    }
                    IntegrationStep(number: 4, text: "Switch to a Chrome tab for a few seconds while tracking is on, then check again.") {
                        Button("Check again") { chromeHelperRunning = TrackerChromeClient.helperRunning() }
                    }
                } else {
                    Text("Choose a Google Chrome profile in a domain or URL rule. You can also set labels such as Work or Personal in the extension’s toolbar popup.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Show extension folder") { revealChromeExtension() }
                        Spacer()
                        Button("Check again") { chromeHelperRunning = TrackerChromeClient.helperRunning() }
                    }
                }
            }
            Divider()
            ChromeProfileClientSettings(clients: snapshot.clients)
        }
    }

    private func installed(_ setup: ChromeBridge.Setup?) -> Bool {
        if case .installed = setup { true } else { false }
    }

    private func installedText(_ setup: ChromeBridge.Setup?) -> String {
        if case let .installed(names) = setup {
            "Daylanes installed its helper for \(names.formatted(.list(type: .and)))."
        } else {
            "Daylanes installs the helper your browser talks to."
        }
    }

    private func revealChromeExtension() {
        let folder = ChromeBridge.extensionFolder
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private var gitHubCard: some View {
        let status = model.gitHubStatus
        let linked = snapshot.projects.filter { $0.githubRepo != nil }.count
        return IntegrationCard(
            title: "GitHub", icon: "chevron.left.forwardslash.chevron.right", connected: status == .connected,
            account: status == .connected ? (model.gitHubLogin.map { "Signed in as @\($0)" } ?? "Signed in with GitHub CLI") : nil,
            purpose: "Matches your time and agent work to pull requests. Uses GitHub CLI, which keeps its own sign-in."
        ) {
            switch status {
            case .connected:
                Text(linked == 0 ? "No project has a repository yet. Link one from a project's page: Add menu → Link GitHub repository…"
                     : "\(linked) \(linked == 1 ? "project has" : "projects have") a linked repository. Manage links from each project's page.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Check again") { Task { await model.checkGitHub() } }
                }
            case nil:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking GitHub CLI…").foregroundStyle(.secondary) }
            default:
                IntegrationStep(number: 1, text: status == .missing ? "Install GitHub CLI in Terminal." : "GitHub CLI is installed.",
                                done: status != .missing) {
                    if status == .missing { CommandButton(command: "brew install gh") }
                }
                IntegrationStep(number: 2, text: "Sign in from Terminal and follow the prompts in your browser.") {
                    CommandButton(command: "gh auth login --web")
                }
                IntegrationStep(number: 3, text: "Come back and check the sign-in.") {
                    Button("Check again") { Task { await model.checkGitHub() } }.buttonStyle(SheetButtonStyle(kind: .primary))
                }
                if status == .unavailable {
                    Text("GitHub CLI did not respond. Check your connection and try again.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var openRouterCard: some View {
        let account = snapshot.openrouterAccount
        let connected = model.openRouterConnected || account != nil
        let detail = account.map { item in
            ["Last synced \(Date(timeIntervalSince1970: item.fetchedAt).formatted(date: .abbreviated, time: .shortened))",
             item.start != nil ? "\(costText(item.totals.spendUsd, currency: "USD")) spent this period" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return IntegrationCard(
            title: "OpenRouter", icon: "point.3.connected.trianglepath.dotted", connected: connected,
            problem: model.openRouterMessage, account: connected ? (detail ?? "Connected") : nil,
            purpose: "Reads your OpenRouter spend, requests and tokens by model, so Overview shows real API spend next to estimates."
        ) {
            if connected {
                if let message = model.openRouterMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Manage…", action: manageOpenRouter)
                }
                if let problem = model.providerUsageMessages[.openrouter] {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                if let usage = snapshot.providerUsage?.first(where: { $0.provider == .openrouter }) {
                    ProviderKeyRoutes(account: usage) { assignProviderKey(.openrouter, $0) }
                }
                Text("Project assignment uses keys from the management key’s workspace. For an organization key, this is the default workspace.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                IntegrationStep(number: 1, text: "Create a management key with activity and API-key listing access.") {
                    Link("Open OpenRouter", destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
                }
                IntegrationStep(number: 2, text: "Paste it here. Daylanes checks it by syncing your last 30 days before saving it to Keychain.") {
                    Button("Connect…", action: manageOpenRouter).buttonStyle(SheetButtonStyle(kind: .primary))
                }
            }
        }
        .disabled(busy)
    }

    private func providerCard(_ provider: AIProvider) -> some View {
        let account = snapshot.providerUsage?.first { $0.provider == provider }
        let problem = model.providerUsageMessages[provider]
        let detail = account.map { "Last synced \(Date(timeIntervalSince1970: $0.fetchedAt).formatted(date: .abbreviated, time: .shortened))" }
        return IntegrationCard(title: provider.name, icon: "chart.bar", connected: account != nil,
                               problem: problem, account: detail, purpose: provider.usageDescription) {
            if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            if let account {
                if provider.supportsProjects {
                    ProviderKeyRoutes(account: account) { assignProviderKey(provider, $0) }
                }
                HStack {
                    Spacer()
                    Button("Refresh") { Task { await model.refreshProviderUsage(provider) } }
                    Button("Manage…") { manageProvider(provider) }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(provider.connectionInstructions).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Connect…") { manageProvider(provider) }.buttonStyle(SheetButtonStyle(kind: .primary))
                }
            }
        }
        .disabled(busy)
    }

    /// Every client's rates in one list, with the projects that override them.
    private var billingRates: some View {
        let clients = snapshot.clients.filter { $0 != snapshot.selfClient }
        let terms = snapshot.billingTerms
        return VStack(alignment: .leading, spacing: 8) {
            heading("Billing rates")
            Text("What you charge each client for your time and your agents. A project can override its client's rates.")
                .foregroundStyle(.secondary)
            if clients.isEmpty {
                Text("Create a client to set rates. Your own work (\(snapshot.selfClient ?? "Me")) is never billed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(clients, id: \.self) { client in
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client).fontWeight(.medium)
                        Text(termsSummary(terms?.client(client))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editBilling(.client, client) }.disabled(busy)
                }
                let overrides = snapshot.projects.filter { $0.client == client && $0.kind == "billable" }
                ForEach(overrides) { project in
                    HStack {
                        Circle().fill(ProjectColor.color(for: project.name)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name).font(.callout)
                            Text(terms?.project(project.name).map { termsSummary($0) } ?? "Uses the client's rates")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Override…") { editBilling(.project, project.name) }.controlSize(.small).disabled(busy)
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    private func termsSummary(_ terms: BillingTerms?) -> String {
        guard let terms else { return "No rates set" }
        var parts: [String] = []
        if let rate = terms.humanRate { parts.append("You \(costText(rate, currency: snapshot.currency))/h") }
        switch terms.agentMode {
        case "time": parts.append("Agents by time" + (terms.agentRate.map { " \(costText($0, currency: snapshot.currency))/h" } ?? ""))
        case "usage": parts.append("Agents by usage ×\(terms.usageMarkup ?? "1")")
        case "hybrid": parts.append("Agents by time + usage")
        case "none": parts.append("Agents not billed")
        default: break
        }
        if let cap = terms.monthlyCap { parts.append("cap \(costText(cap, currency: snapshot.currency))/month") }
        return parts.isEmpty ? "No rates set" : parts.joined(separator: " · ")
    }

    private var subscriptions: some View {
        let plans = snapshot.subscriptions.plans
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                heading("Subscriptions")
                Spacer()
                Button("Add subscription…") { editPlan(nil) }.disabled(busy)
            }
            if plans.isEmpty {
                Text("Record the monthly fees you pay for plans such as ChatGPT Pro or Claude Pro.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(costText(snapshot.subscriptions.monthlyTotal, currency: snapshot.currency)) / month")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                ForEach(plans) { plan in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.name).fontWeight(.medium)
                            if let provider = plan.provider {
                                Text(provider).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(costText(plan.monthly, currency: snapshot.currency)).monospacedDigit()
                        Button("Edit…") { editPlan(plan) }
                            .accessibilityLabel("Edit \(plan.name)").disabled(busy)
                    }
                }
            }
        }
    }

    /// Converts API-credit value (USD) into the ledger currency for agent usage on invoices.
    @ViewBuilder
    private var exchangeRate: some View {
        if snapshot.currency != "USD" {
            let saved = snapshot.billingTerms?.usdExchangeRate ?? ""
            let text = Binding(get: { usdRate ?? saved }, set: { usdRate = $0 })
            let value = (usdRate ?? saved).trimmed.replacingOccurrences(of: ",", with: ".")
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                heading("Exchange rate for billing")
                HStack {
                    Text("1 USD =")
                    TextField("0.92", text: text).textFieldStyle(.roundedBorder).frame(width: 90)
                    Text(snapshot.currency)
                    Spacer()
                    Button("Save") {
                        Task {
                            await model.perform("Saving exchange rate…") {
                                _ = try await Ledger.run(["billing", "exchange-rate", "--", value])
                                try await model.update()
                                usdRate = nil
                                model.notice = "Exchange rate saved"
                            }
                        }
                    }
                    .disabled(busy || value == saved || !(value.isEmpty || (Double(value).map { $0 > 0 } ?? false)))
                }
                Text("Usage billing charges the API-credit value of agent tokens, which OpenRouter prices in USD. Daylanes converts it with this rate.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tokenPrices: some View {
        let prices = snapshot.models.filter {
            modelFilter.isEmpty || $0.model.localizedCaseInsensitiveContains(modelFilter)
                || providerName($0.provider).localizedCaseInsensitiveContains(modelFilter)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                heading("Token prices")
                Spacer()
                Button("Refresh catalog") { Task { await model.refreshPrices() } }.disabled(busy)
            }
            Text("API equivalent uses OpenRouter’s public USD catalog. Daylanes downloads it without sending your model usage. Manual rates are in \(snapshot.currency) per million tokens.")
                .foregroundStyle(.secondary)
            if let checked = snapshot.apiPricesFetchedAt {
                Text("Catalog updated \(Date(timeIntervalSince1970: checked).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.models.isEmpty {
                Text("Models appear after Daylanes imports agent usage.").font(.callout).foregroundStyle(.secondary)
            } else {
                TextField("Search tracked models", text: $modelFilter).textFieldStyle(.roundedBorder)
                if prices.isEmpty {
                    Text("No matching models.").font(.callout).foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(prices) { price in
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(price.model).fontWeight(.medium)
                                Text("\(providerName(price.provider)) · \(price.openrouterModel ?? "No catalog match")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(price.prices == nil ? "Set manual rate…" : "Edit manual rate…") { editPrice(price) }
                                .accessibilityLabel("Edit manual token rate for \(price.model)")
                                .disabled(busy).fixedSize()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 7) {
                heading("Local storage")
                Text("Daylanes stores projects, clients, activity and settings in a SQLite ledger on this Mac. Daylanes has no hosted workspace or cross-device sync.")
                    .foregroundStyle(.secondary)
                Text(snapshot.database).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Show ledger in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: snapshot.database)])
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                heading("Credentials & external requests")
                Text("Daylanes stores Toggl Track and AI provider credentials in macOS Keychain. You can replace or remove them in Integrations. Daylanes never displays saved keys or includes them in the ledger or CSV exports.")
                    .foregroundStyle(.secondary)
                Text("Integrations describes what each provider receives and what Daylanes reads. Daylanes also downloads the public OpenRouter pricing catalog. Exports and connected MCP agents can receive ledger data when you use them.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }
}

private struct ChromeProfileClientSettings: View {
    @EnvironmentObject private var recorder: FocusRecorder
    let clients: [String]
    @State private var authorized = WindowTitles.authorized
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chrome profile clients").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Use a profile’s client for future Chrome time that has no matching project.")
                .font(.callout).foregroundStyle(.secondary)
            if recorder.chromeProfiles.isEmpty {
                Text("No Chrome profiles found.").font(.callout).foregroundStyle(.secondary)
            } else if clients.isEmpty {
                Text("Create a client to map a profile.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(recorder.chromeProfiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                        if recorder.chromeProfiles.contains(where: { $0.id != profile.id && $0.name == profile.name }) {
                            Text(profile.id).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Picker("Client for \(profile.name)", selection: Binding<String?>(
                        get: { recorder.chromeProfileClients[profile.id] },
                        set: { save($0, for: profile.id) }
                    )) {
                        Text("No client").tag(nil as String?)
                        ForEach(clients, id: \.self) { client in
                            Text(client).tag(Optional(client))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(saving || !recorder.ready || clients.isEmpty)
                }
            }
            if recorder.chromeProfileCatalog.requiresImport {
                Button(recorder.chromeProfiles.isEmpty ? "Import Chrome profiles…" : "Refresh imported profiles…") {
                    Task {
                        error = nil
                        do { try await recorder.chooseChromeProfiles() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.link)
            }
            if !authorized && !recorder.chromeProfiles.isEmpty {
                Button("Allow Accessibility to recognize the active profile…", action: WindowTitles.openAccessibilitySettings)
                    .buttonStyle(.link)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
        }
        .task { await recorder.refreshChromeProfiles() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            authorized = WindowTitles.authorized
        }
    }

    private func save(_ client: String?, for profileID: String) {
        guard client != recorder.chromeProfileClients[profileID], !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await recorder.setChromeProfileClient(client, for: profileID) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// A bordered card for one integration, with its status, the connected account and its controls.
struct IntegrationCard<Content: View>: View {
    let title: String
    let icon: String
    let connected: Bool
    /// Set when the saved connection failed its last check, so the badge stops saying it works.
    var problem: String? = nil
    let account: String?
    let purpose: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsIcon(name: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(account ?? "Not connected").font(.system(size: 12)).foregroundStyle(SheetTheme.muted).lineLimit(1)
                }
                Spacer()
                badge
            }
            Text(purpose).font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(14)
        .modifier(SettingsCard())
    }

    /// Green when the connection is set up and its last check worked, orange when it needs attention.
    private var badge: some View {
        let (text, icon, tint): (String, String, Color) =
            !connected ? ("Not connected", "circle.dashed", .secondary)
            : problem != nil ? ("Needs attention", "exclamationmark.triangle.fill", .orange)
            : ("Active", "checkmark.circle.fill", .green)
        return Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(connected ? Color.white : SheetTheme.label)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(connected ? tint : SheetTheme.soft, in: Capsule())
            .help(problem ?? (connected ? "Connected and working" : "Not connected yet"))
            .accessibilityLabel("\(title): \(text)")
    }
}

/// One numbered step of a connect sequence, with its action on the right. Numbers sit in the same small
/// squares as the steps in the app's sheets.
private struct IntegrationStep<Action: View>: View {
    let number: Int
    let text: String
    var done = false
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(SheetTheme.label)
                }
            }
            .frame(width: 22, height: 22)
            .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SheetTheme.border))
            .accessibilityHidden(true)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
    }
}

/// A section's icon in a small rounded square, like the icons on the sheets' mode cards.
struct SettingsIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(SheetTheme.label)
            .frame(width: 32, height: 32)
            .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SheetTheme.border))
            .accessibilityHidden(true)
    }
}

/// The white card with a hairline border that holds one integration.
struct SettingsCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SheetTheme.body, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SheetTheme.border))
    }
}

/// Shows a Terminal command with a button that copies it.
struct CommandButton: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1)
            CommandCopyButton(command: command)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SheetTheme.border))
    }
}

struct CommandCopyButton: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(command, forType: .string)
        }
        .buttonStyle(CopyButtonStyle())
        .onChange(of: command) { _, _ in copied = false }
    }
}

private extension View {
    /// Keeps the window's name for the Window menu and VoiceOver without drawing it in the title bar.
    @ViewBuilder func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) { toolbar(removing: .title) } else { self }
    }
}

/// Lets the Settings window's dark header run under a transparent title bar, like the app's sheets, with the
/// traffic lights sitting on the header.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(view.window) }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        // The title bar strip shows the window's background, so give it the header's colour.
        window.backgroundColor = NSColor(hex: 0x111113)
    }
}

/// The small Copy button inside a command row.
private struct CopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(SheetTheme.soft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SheetTheme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
