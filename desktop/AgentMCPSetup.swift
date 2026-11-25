import SwiftUI

struct AgentMCPCommand {
    let executable: String
    let database: String
    var allowSetup = false

    var arguments: [String] { ["mcp", allowSetup ? "--access=write" : "--access=read", "--db=\(database)"] }

    func registration(using prefix: String) -> String {
        let invocation = ([executable] + arguments).map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return ([prefix + " --"] + invocation.map { "  \($0)" }).joined(separator: " \\\n")
    }
}

struct AgentMCPSetup: View {
    let database: String
    @Environment(\.dismiss) private var dismiss
    @State private var client: Client = .codex
    @State private var allowSetup = false
    @State private var showsCodexSettings = false

    private enum Client: String, CaseIterable, Identifiable {
        case codex = "Codex"
        case claude = "Claude Code"

        var id: Self { self }

        var registration: String {
            switch self {
            case .codex: "codex mcp add tracker"
            case .claude: "claude mcp add --scope user --transport stdio tracker"
            }
        }

        var documentation: URL {
            switch self {
            case .codex: URL(string: "https://learn.chatgpt.com/docs/extend/mcp?surface=desktop")!
            case .claude: URL(string: "https://code.claude.com/docs/en/mcp")!
            }
        }
    }

    private var command: AgentMCPCommand? {
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "TrackerCLI"),
              FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return AgentMCPCommand(executable: binary.path, database: database, allowSetup: allowSetup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an agent").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .vertical) {
                instructions.fixedSize(horizontal: false, vertical: true)
                ScrollView { instructions }
            }
            HStack {
                Link("Client documentation", destination: client.documentation)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 565)
        .frame(maxHeight: 680)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect a local agent to your Daylanes projects, activity, and reports through MCP. The agent can use returned ledger data in its conversation.")
                .foregroundStyle(.secondary)
            if let command {
                Picker("Agent", selection: $client) {
                    ForEach(Client.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Toggle("Allow project and rule setup", isOn: $allowSetup)
                Text(allowSetup ? "This command lets the agent set up clients, projects, folder mappings, and tracking rules."
                     : "This command gives the agent read-only access.")
                    .font(.callout).foregroundStyle(.secondary)

                let registration = command.registration(using: client.registration)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run this command in Terminal with the \(client.rawValue) CLI installed.")
                    SetupCodeBlock(title: "Terminal", values: [registration])
                        .id(registration)
                }
                if client == .codex {
                    DisclosureGroup("Set up in Codex settings", isExpanded: $showsCodexSettings) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("In the ChatGPT desktop app, go to Settings → MCP servers → Add server. Name it tracker and choose STDIO. Enter this executable as the command.")
                            SetupCodeBlock(title: "Command", values: [command.executable])
                            Text("Add each of these arguments, then save and restart the client.")
                            SetupCodeBlock(title: "Arguments", values: command.arguments)
                        }
                        .padding(.top, 6)
                    }
                }
                Text("Restart the client, open a local session, and use /mcp to check for tracker.")
                if client == .claude {
                    Text("In Claude Desktop, use the local Code tab.").foregroundStyle(.secondary)
                }
                Text("Try asking “Using Daylanes, list my projects.”").foregroundStyle(.secondary)
            } else {
                Text("The command-line tool is missing from this Daylanes build.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SetupCodeBlock: View {
    let title: String
    let values: [String]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.blockRadius)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let value = values.first, values.count == 1 {
                    CommandCopyButton(command: value)
                        .accessibilityHint("Copies the full text in this block")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(values.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 10) {
                        Text(verbatim: values[index])
                            .font(.callout.monospaced())
                            .foregroundStyle(Theme.text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if values.count > 1 {
                            CommandCopyButton(command: values[index])
                                .accessibilityHint("Copies argument \(index + 1)")
                        }
                    }
                }
            }
            .padding(12)
            .background(Theme.card)
        }
        .background(Theme.block)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.hairline) }
    }
}
