import ServiceManagement
import SwiftUI

/// What tracking needs from macOS, set once for the whole app: window titles, Chrome tabs and Open at login.
/// Lives in Settings → General; the rules themselves belong to each project.
struct TrackingPermissions: View {
    @State private var authorized = WindowTitles.authorized
    @State private var askedForAccessibility = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var chromeAccess = ChromeTabs.Access.unavailable
    @State private var checkingChrome = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(authorized ? "Window titles: allowed" : "Window titles need Accessibility",
                detail: "Lets rules and automatic name matching read the front window’s title.",
                icon: "macwindow", ok: authorized) {
                if !authorized {
                    Button("Allow…") {
                        WindowTitles.requestAccess()
                        askedForAccessibility = true
                        authorized = WindowTitles.authorized
                    }
                }
            }
            if !authorized && askedForAccessibility {
                // macOS ties the grant to the app's signature. After an update the old entry can stay
                // switched on in the list while no longer applying to this copy, and no new prompt appears.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Already on in System Settings? Select \(WindowTitles.appName) in the Accessibility list, remove it with −, then choose Allow again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings…") { WindowTitles.openAccessibilitySettings() }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.leading, 28)
            }
            row(chromeAccess == .allowed ? "Chrome Automation: allowed" : "Chrome Automation (optional)",
                detail: "Reads the active Chrome tab when the Daylanes extension isn’t installed.",
                icon: "safari", ok: chromeAccess == .allowed) {
                if chromeAccess != .allowed {
                    Button(checkingChrome ? "Checking…" : "Allow…") {
                        Task { await updateChromeAccess(prompt: true) }
                    }
                    .disabled(checkingChrome)
                }
            }
            row(loginStatus == .enabled ? "Opens at login" : "Open at login",
                detail: "Tracking is always on, so Daylanes should start with your Mac.",
                icon: "power", ok: loginStatus == .enabled) {
                if loginStatus == .requiresApproval {
                    Button("Review Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Button(loginStatus == .enabled ? "Turn off" : "Turn on") { updateLoginItem() }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color.red).font(.callout)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            authorized = WindowTitles.authorized
            loginStatus = SMAppService.mainApp.status
            Task { await updateChromeAccess() }
        }
        .task { await updateChromeAccess() }
        .task {
            // The grant can change while Tracker stays in front (System Settings in another Space or
            // a second screen), so keep checking until it is on.
            while !Task.isCancelled && !authorized {
                try? await Task.sleep(for: .seconds(2))
                authorized = WindowTitles.authorized
            }
        }
    }

    private func row<Action: View>(_ title: String, detail: String, icon: String, ok: Bool,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                    if ok { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }

    private func updateChromeAccess(prompt: Bool = false) async {
        guard !checkingChrome else { return }
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: ChromeTabs.bundleID).first else {
            chromeAccess = .notRunning
            if prompt { error = "Open Google Chrome, then choose Allow again." }
            return
        }
        checkingChrome = true
        if prompt { error = nil }
        defer { checkingChrome = false }
        chromeAccess = await ChromeTabs.access(pid: chrome.processIdentifier, prompt: prompt)
        if prompt && chromeAccess != .allowed {
            error = "Allow Google Chrome for Daylanes in System Settings → Privacy & Security → Automation."
        }
    }

    private func updateLoginItem() {
        error = nil
        Task {
            do {
                if loginStatus == .enabled {
                    try await SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                self.error = "Couldn’t update Login Items. \(error.localizedDescription)"
            }
            loginStatus = SMAppService.mainApp.status
        }
    }
}

/// A project's tracking rules, on its page: the automatic name rules, then the rules you added.
struct ProjectRules: View {
    @EnvironmentObject private var recorder: FocusRecorder
    let project: Project
    let edit: (FocusRule?) -> Void
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        let mine = recorder.rules.filter { $0.project == project.name }
        let automatic = recorder.autoRules.filter { $0.project == project.name }
        let on = !recorder.autoRulesOff.contains(project.name)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tracking rules").fontWeight(.medium)
                Spacer()
                Button("Add rule…") { edit(nil) }.disabled(!recorder.ready)
            }
            Text("Time in apps, windows and Chrome tabs that match these rules goes to \(project.name).")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { on }, set: { setAutomatic($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match by name automatically")
                    Text(on && !automatic.isEmpty
                         ? "Windows whose title contains " + automatic.map { "“\($0.keyword)”" }.joined(separator: " or ") + "."
                         : on ? "This name is too short or shared with another project, so it isn’t matched."
                         : "Off: only the rules below route time here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(saving || !recorder.ready)
            ForEach(mine) { rule in
                RuleListRow(rule: rule, disabled: !recorder.ready) { edit(rule) }
                    .padding(.vertical, 2)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color.red).font(.callout)
            }
        }
        .padding(.top, 6)
    }

    private func setAutomatic(_ on: Bool) {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await recorder.applyRuleChange(["auto-rules", project.name, "--state", on ? "on" : "off"])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct TrackingRulesSheet: View {
    @EnvironmentObject private var recorder: FocusRecorder
    let projects: [Project]
    let didCreateProject: () -> Void
    @State private var editor: Editor?

    private struct Editor: Identifiable {
        let rule: FocusRule?
        var id: String { rule?.id ?? "new" }
    }

    var body: some View {
        SheetFrame(title: "Tracking rules", primary: "New rule…", cancelTitle: "Done",
                   canSubmit: recorder.ready, width: 540, submit: { editor = Editor(rule: nil) }) {
            if recorder.rules.isEmpty {
                Text("Add a rule to assign or ignore future app, window, or website activity.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(recorder.rules) { rule in
                            RuleListRow(rule: rule, showsProject: true, disabled: !recorder.ready) {
                                editor = Editor(rule: rule)
                            }
                            .padding(.vertical, 9)
                            if rule.id != recorder.rules.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(CGFloat(recorder.rules.count) * 53, 320))
            }
        }
        .sheet(item: $editor) { item in
            RuleSheet(rule: item.rule, projects: projects, didCreateProject: didCreateProject)
        }
    }
}

private struct RuleListRow: View {
    @EnvironmentObject private var recorder: FocusRecorder
    let rule: FocusRule
    var showsProject = false
    let disabled: Bool
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.keyword).fontWeight(.medium).lineLimit(1)
                    .help(rule.appID ?? rule.keyword)
                let profile = rule.chromeProfileID.map(recorder.chromeProfileName) ?? rule.chromeProfile
                let scope = rule.appScope ?? (rule.needsWindowTitle ? rule.appID : nil)
                Text([rule.fieldLabel, scope.map { "in \($0)" }, profile, rule.tag.map { "tag \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if showsProject {
                if let project = rule.project {
                    ProjectTag(client: nil, project: project)
                } else {
                    Text("Ignored").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Edit…", action: edit).controlSize(.small).disabled(disabled)
                .accessibilityLabel("Edit rule for \(rule.keyword)")
        }
    }

    private var symbol: String {
        switch rule.field {
        case "window": "macwindow"
        case "domain", "url": "globe"
        default: "app"
        }
    }
}

/// Adds or edits one rule, in the same sheet style as the other editors.
struct RuleSheet: View {
    @EnvironmentObject private var recorder: FocusRecorder
    @Environment(\.dismiss) private var dismiss
    let rule: FocusRule?
    let projects: [Project]
    var initialProject: String?
    var appHint: FocusRow?
    var tabHint: ChromeObservation?
    var didCreateProject: () -> Void = {}

    @State private var field = "window"
    @State private var windowTitle = ""
    @State private var website = ""
    @State private var appName = ""
    @State private var appID: String?
    @State private var manualAppName = false
    @State private var windowAppName = ""
    @State private var windowAppID: String?
    @State private var manualWindowAppName = false
    @State private var chromeWindow = ""
    @State private var profileChoice: ProfileChoice = .any
    @State private var profileLabel = ""
    @State private var profileImportError: String?
    @State private var tag = ""
    @State private var project = ""
    @State private var track = true
    @State private var saving = false
    @State private var error: String?
    @State private var quickProject = false
    @State private var newProjects: [Project] = []

    private enum ProfileChoice: Hashable {
        case any, installed(String), extensionLabel
    }

    private var profileOptions: [[(ProfileChoice, String)]] {
        let catalog = recorder.chromeProfiles
        let byName = Dictionary(grouping: catalog) { $0.name.lowercased() }
        var profiles: [(ProfileChoice, String)] = catalog.map { profile in
            let name = byName[profile.name.lowercased()]?.count == 1 ? profile.name : "\(profile.name) (\(profile.id))"
            return (.installed(profile.id), name)
        }
        if case let .installed(id) = profileChoice, !catalog.contains(where: { $0.id == id }) {
            profiles.append((.installed(id), "\(id) (unavailable)"))
        }
        return [[(.any, "Any profile")], profiles, [(.extensionLabel, "Extension label…")]].filter { !$0.isEmpty }
    }

    private var allProjects: [Project] {
        projects + newProjects.filter { item in !projects.contains { $0.id == item.id } }
    }

    private var condition: (field: String, keyword: String) {
        switch field {
        case "app": ("app", appName.trimmed)
        case "website": Focus.websiteCondition(website.trimmed)
        default: ("window", windowTitle.trimmed)
        }
    }

    private var chips: [String] {
        guard track, let item = allProjects.first(where: { $0.name == project }) else { return [] }
        return Self.path(item)
    }

    /// Client then project, shown once when the two share a name.
    private static func path(_ item: Project) -> [String] {
        guard let client = item.client, client.caseInsensitiveCompare(item.name) != .orderedSame else { return [item.name] }
        return [client, item.name]
    }

    var body: some View {
        SheetFrame(title: rule == nil ? "New tracking rule" : "Edit tracking rule",
                   dot: track && !project.isEmpty ? ProjectColor.color(for: project) : nil, chips: chips,
                   subtitle: "Rules apply to future activity.",
                   primary: rule == nil ? "Add rule" : "Save",
                   canSubmit: !condition.keyword.isEmpty && (!track || !project.isEmpty)
                       && (field != "website" || profileChoice != .extensionLabel || !profileLabel.trimmed.isEmpty),
                   busy: saving, width: 540, submit: save) {
            SheetField(label: "Match") {
                SheetSegments(selection: $field, options: [("window", "Window title"), ("app", "App"), ("website", "Website")])
            }
            if field == "app" {
                AppRuleField(name: $appName, appID: $appID, manual: $manualAppName)
            } else if field == "window" {
                SheetField(label: "Window title contains") {
                    SheetTextField(placeholder: "e.g. Client portal", text: $windowTitle, autofocus: true)
                    Text(WindowTitles.authorized ? "Matches while the front window’s title contains this text."
                         : "Window titles need Accessibility. Allow it in Settings → General.")
                        .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AppRuleField(name: $windowAppName, appID: $windowAppID, manual: $manualWindowAppName, optional: true)
            } else {
                SheetField(label: "Domain or URL") {
                    SheetTextField(placeholder: "e.g. example.com or https://example.com/work", text: $website, autofocus: true)
                    Text("A domain includes subdomains. A URL matches its path and subpaths.")
                        .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SheetField(label: "Chrome window", note: "optional") {
                    SheetTextField(placeholder: "Exact window name", text: $chromeWindow)
                }
                SheetField(label: "Chrome profile", note: "optional") {
                    SheetMenu(selection: $profileChoice, groups: profileOptions)
                        .accessibilityLabel("Chrome profile")
                    if profileChoice == .extensionLabel {
                        SheetTextField(placeholder: "The extension’s profile label", text: $profileLabel)
                    } else if case .installed = profileChoice, !WindowTitles.authorized {
                        Button("Enable Accessibility to match Chrome profiles", action: WindowTitles.openAccessibilitySettings)
                            .buttonStyle(SheetButtonStyle(kind: .link))
                    }
                    if recorder.chromeProfileCatalog.requiresImport {
                        Button(recorder.chromeProfiles.isEmpty ? "Import Chrome profiles…" : "Refresh imported profiles…",
                               action: importChromeProfiles)
                            .buttonStyle(SheetButtonStyle(kind: .link))
                    }
                    if let profileImportError {
                        Text(profileImportError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            SheetField(label: "When matched") {
                SheetSegments(selection: $track, options: [(true, "Track"), (false, "Do Not Track")])
                if !track {
                    Text("Keeps the app and duration in Ignored, outside project totals and review. Takes precedence over Track rules.")
                        .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if track { projectFields }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color.red).font(.callout)
            }
        } leading: {
            if let rule {
                Button("Remove rule") { remove(rule) }
                    .buttonStyle(SheetButtonStyle(kind: .destructive))
                    .disabled(saving)
            }
        }
        .onAppear(perform: fill)
        .task { await recorder.refreshChromeProfiles() }
        .sheet(isPresented: $quickProject) {
            QuickProjectEditor { item in
                newProjects.append(item)
                project = item.name
                didCreateProject()
            }
        }
    }

    @ViewBuilder private var projectFields: some View {
        HStack(alignment: .top, spacing: 12) {
            SheetField(label: "Project") {
                SheetMenu(selection: $project,
                          groups: [allProjects.map { ($0.name, Self.path($0).joined(separator: " / ")) }],
                          placeholder: "Choose a project", dot: { ProjectColor.color(for: $0) })
            }
            SheetField(label: "Tag", note: "optional") {
                SheetTextField(placeholder: "e.g. Review", text: $tag)
            }
            .frame(width: 170)
        }
        Button("+ New project") { quickProject = true }
            .buttonStyle(SheetButtonStyle(kind: .link))
            .padding(.top, -10)
            .padding(.leading, -6)
    }

    private func importChromeProfiles() {
        Task {
            profileImportError = nil
            do { try await recorder.chooseChromeProfiles() }
            catch { profileImportError = error.localizedDescription }
        }
    }

    private func fill() {
        if let rule {
            switch rule.field {
            case "app":
                setApp(name: rule.keyword, id: rule.appID)
            case "domain", "url":
                field = "website"
                website = rule.keyword
                chromeWindow = rule.appScope ?? ""
                fillProfile(id: rule.chromeProfileID, label: rule.chromeProfile)
            default:
                field = "window"
                windowTitle = rule.keyword
                windowAppID = rule.appID
                windowAppName = rule.appScope ?? rule.appID ?? ""
                manualWindowAppName = rule.appID == nil && rule.appScope != nil
            }
            tag = rule.tag ?? ""
            project = rule.project ?? initialProject ?? ""
            track = !rule.isIgnored
            return
        }
        project = initialProject ?? ""
        if let appHint { setApp(name: appHint.appName, id: appHint.appID) }
        if let tabHint {
            field = "website"
            website = tabHint.address.host
            chromeWindow = tabHint.profileID == nil && tabHint.profile == nil ? tabHint.windowName ?? "" : ""
            fillProfile(id: tabHint.profileID, label: tabHint.profile)
        }
    }

    private func fillProfile(id: String?, label: String?) {
        if let id {
            profileChoice = .installed(id)
        } else if let label {
            profileChoice = .extensionLabel
            profileLabel = label
        }
    }

    private func setApp(name: String, id: String?) {
        field = "app"
        appName = name
        appID = id
        manualAppName = id == nil
    }

    private func save() {
        var args = ["save-rule", "--field=\(condition.field)", "--keyword=\(condition.keyword)",
                    track ? "--project=\(project)" : "--ignore"]
        if let rule { args += ["--id", rule.id] }
        if field == "app", let appID { args += ["--app-id=\(appID)"] }
        if field == "window" {
            if let windowAppID { args.append("--app-id=\(windowAppID)") }
            if !windowAppName.trimmed.isEmpty { args.append("--app-scope=\(windowAppName.trimmed)") }
        }
        if field == "website" {
            if !chromeWindow.trimmed.isEmpty { args.append("--app-scope=\(chromeWindow.trimmed)") }
            switch profileChoice {
            case .any: break
            case let .installed(id): args.append("--chrome-profile-id=\(id)")
            case .extensionLabel: args.append("--chrome-profile=\(profileLabel.trimmed)")
            }
        }
        if track && !tag.trimmed.isEmpty { args += ["--tag=\(tag.trimmed)"] }
        change(args)
    }

    private func remove(_ rule: FocusRule) {
        change(["delete-rule", rule.id])
    }

    private func change(_ args: [String]) {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await recorder.applyRuleChange(args)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
