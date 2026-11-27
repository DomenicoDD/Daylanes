import SwiftUI

struct SlackTrackingSettings: View {
    @EnvironmentObject private var recorder: FocusRecorder
    let clients: [String]
    let projects: [Project]
    let didCreateProject: () -> Void

    @State private var authorized = WindowTitles.authorized
    @State private var editor: Editor?

    private enum Editor: Identifiable {
        case mapping(SlackWorkspaceClient?, SlackTrackingContext?)
        case rule(SlackTrackingContext.ChannelRule)

        var id: String {
            switch self {
            case let .mapping(mapping, _): mapping?.id ?? "new"
            case .rule: "rule"
            }
        }
    }

    var body: some View {
        let last = recorder.lastSlackContext
        let lastMapping = last.flatMap { SlackWorkspaceClient.match($0, in: recorder.slackWorkspaceClients) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Slack", systemImage: "bubble.left.and.bubble.right").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Map workspace…") { editor = .mapping(nil, lastMapping == nil ? last : nil) }
                    .disabled(clients.isEmpty || !recorder.ready)
            }
            Text("Assign Slack time to a client by workspace. Channel rules can assign it to a project.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(recorder.slackWorkspaceClients) { mapping in
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mapping.desktopName ?? mapping.workspaceID ?? "Slack workspace").lineLimit(1)
                        Text(mapping.client).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit…") { editor = .mapping(mapping, nil) }
                        .disabled(!recorder.ready)
                        .accessibilityHint("Edit the Slack workspace assigned to \(mapping.client)")
                }
            }
            if clients.isEmpty {
                Text("Create a client to map a Slack workspace.").font(.caption).foregroundStyle(.secondary)
            }
            if let label = lastMapping?.desktopName ?? last?.desktopName ?? last?.workspaceID {
                HStack(spacing: 8) {
                    Text("Last seen · \(label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(label).privacySensitive()
                    Spacer()
                    if let rule = last?.channelRule {
                        Button("Create channel rule…") { editor = .rule(rule) }
                            .disabled(!recorder.ready)
                    }
                }
            }
            if !authorized {
                Button("Allow Accessibility for Slack desktop…", action: WindowTitles.openAccessibilitySettings)
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            authorized = WindowTitles.authorized
        }
        .sheet(item: $editor) { item in
            switch item {
            case let .mapping(mapping, context):
                SlackWorkspaceClientEditor(mapping: mapping, context: context, clients: clients)
            case let .rule(rule):
                RuleSheet(rule: nil, projects: projects, slackHint: rule, didCreateProject: didCreateProject)
            }
        }
    }
}

private struct SlackWorkspaceClientEditor: View {
    private enum WorkspaceSelection: Hashable {
        case discovered(String)
        case manual
    }

    @EnvironmentObject private var recorder: FocusRecorder
    @Environment(\.dismiss) private var dismiss
    let mapping: SlackWorkspaceClient?
    let clients: [String]
    @State private var workspace: String
    @State private var selection: WorkspaceSelection?
    @State private var manualName: String
    @State private var client: String
    @State private var discovery: SlackWorkspaceDiscovery?
    @State private var refreshing = false
    @State private var saving = false
    @State private var error: String?

    init(mapping: SlackWorkspaceClient?, context: SlackTrackingContext?, clients: [String]) {
        self.mapping = mapping
        self.clients = clients
        _workspace = State(initialValue: mapping?.workspaceID ?? context?.workspaceID ?? "")
        let suggested = mapping?.desktopName ?? context?.desktopName
        _selection = State(initialValue: suggested.map(WorkspaceSelection.discovered))
        _manualName = State(initialValue: suggested ?? "")
        _client = State(initialValue: mapping?.client ?? "")
    }

    var body: some View {
        SheetFrame(title: mapping == nil ? "Map Slack workspace" : "Edit Slack workspace",
                   primary: "Save", canSubmit: !client.isEmpty && (!workspace.trimmed.isEmpty || desktopName != nil),
                   busy: saving, submit: { change(client) }) {
            SheetField(label: "Slack desktop workspace") {
                HStack(spacing: 10) {
                    SheetMenu(selection: $selection, groups: workspaceOptions, placeholder: "Choose a workspace…")
                        .accessibilityLabel("Slack desktop workspace")
                        .accessibilityValue(selectedWorkspaceLabel)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refreshWorkspaces() } }
                        .accessibilityLabel("Refresh Slack workspaces")
                        .disabled(refreshing || saving)
                }
                workspaceDiscoveryStatus
                if selection == .manual {
                    SheetTextField(placeholder: "Exact name shown in Slack", text: $manualName)
                        .accessibilityLabel("Slack workspace name")
                }
            }
            SheetField(label: "Slack browser workspace ID or URL", note: "optional if using desktop") {
                SheetTextField(placeholder: "T0123ABCD or a Slack browser URL", text: $workspace)
            }
            SheetField(label: "Client") {
                SheetMenu(selection: $client, groups: [clients.map { ($0, $0) }], placeholder: "Choose a client…")
                    .accessibilityLabel("Client")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
        } leading: {
            if mapping != nil {
                Button("Remove mapping", role: .destructive) { change(nil) }
                    .buttonStyle(SheetButtonStyle(kind: .destructive))
                    .disabled(saving)
            }
        }
        .task { await refreshWorkspaces() }
    }

    private var desktopName: String? {
        switch selection {
        case let .discovered(name): name
        case .manual: manualName.trimmed.isEmpty ? nil : manualName.trimmed
        case nil: nil
        }
    }

    private var selectedWorkspaceLabel: String {
        switch selection {
        case let .discovered(name): name
        case .manual: "Enter name manually"
        case nil: "No desktop workspace selected"
        }
    }

    private var workspaceOptions: [[(WorkspaceSelection?, String)]] {
        var names: [String] = if case let .found(found) = discovery { found } else { [] }
        // Keep a saved or last-seen name selected even when Slack is closed or signed out of it.
        if case let .discovered(name) = selection, !names.contains(name) { names.append(name) }
        let workspaces: [(WorkspaceSelection?, String)] = names.map { (.discovered($0), $0) }
        var other: [(WorkspaceSelection?, String)] = [(.manual, "Enter name manually…")]
        if selection != nil { other.append((nil, "Clear selection")) }
        return workspaces.isEmpty ? [other] : [workspaces, other]
    }

    @ViewBuilder private var workspaceDiscoveryStatus: some View {
        if refreshing {
            Text("Finding Slack workspaces…").font(.caption).foregroundStyle(.secondary)
        } else {
            switch discovery {
            case .slackClosed:
                Text("Open Slack desktop, then refresh.").font(.caption).foregroundStyle(.secondary)
            case .needsAccessibility:
                Button("Allow Accessibility to find Slack workspaces…", action: WindowTitles.openAccessibilitySettings)
                    .buttonStyle(.link)
            case .unavailable:
                Text("Couldn’t find signed-in workspaces in Slack desktop.").font(.caption).foregroundStyle(.secondary)
            case .found, nil:
                EmptyView()
            }
        }
    }

    @MainActor private func refreshWorkspaces() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        discovery = await SlackWorkspaceDiscovery.discover()
    }

    private func change(_ destination: String?) {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await recorder.setSlackWorkspaceClient(id: mapping?.id,
                    workspace: workspace.trimmed.isEmpty ? nil : workspace.trimmed,
                    desktopName: desktopName,
                    client: destination)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
