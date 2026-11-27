import SwiftUI

struct AgentMCPCommand {
    let executable: String
    let database: String
    var allowSetup = false

    var diaryRoutine: UUID?

    var arguments: [String] {
        var arguments = ["mcp", allowSetup || diaryRoutine != nil ? "--access=write" : "--access=read", "--db=\(database)"]
        if let diaryRoutine { arguments.append("--diary-project=\(diaryRoutine.uuidString)") }
        return arguments
    }

    func registration(using prefix: String) -> String {
        let invocation = ([executable] + arguments).map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return ([prefix + " --"] + invocation.map { "  \($0)" }).joined(separator: " \\\n")
    }
}

/// Connects a local agent to the ledger through MCP, laid out like the Diary setup: pick the agent on a card,
/// then follow its numbered steps.
struct AgentMCPSetup: View {
    let database: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agentSetupClient") private var client: Client = .codex
    @State private var allowSetup = false

    enum Client: String, CaseIterable, Identifiable {
        case codex, claude, chatgpt, other

        var id: Self { self }

        var title: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .chatgpt: "ChatGPT app"
            case .other: "Other"
            }
        }

        var detail: String {
            switch self {
            case .codex: "Codex CLI"
            case .claude: "Terminal or desktop"
            case .chatgpt: "Settings on your Mac"
            case .other: "Any MCP client"
            }
        }

        var icon: String {
            switch self {
            case .codex: "terminal"
            case .claude: "sparkle"
            case .chatgpt: "macwindow"
            case .other: "point.3.connected.trianglepath.dotted"
            }
        }

        var registration: String? {
            switch self {
            case .codex: "codex mcp add tracker"
            case .claude: "claude mcp add --scope user --transport stdio tracker"
            case .chatgpt, .other: nil
            }
        }

        var documentation: URL {
            switch self {
            case .codex, .chatgpt: URL(string: "https://learn.chatgpt.com/docs/extend/mcp?surface=desktop")!
            case .claude: URL(string: "https://code.claude.com/docs/en/mcp")!
            case .other: URL(string: "https://modelcontextprotocol.io")!
            }
        }
    }

    private static let samplePrompt = "Using Daylanes, list my projects."

    private var command: AgentMCPCommand? {
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "TrackerCLI"),
              FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return AgentMCPCommand(executable: binary.path, database: database, allowSetup: allowSetup)
    }

    var body: some View {
        SheetFrame(title: "Connect an agent",
                   subtitle: "Lets a local agent read your Daylanes projects, activity and reports through MCP.",
                   primary: "Done", width: 580, submit: { dismiss() }) {
            SheetModePicker(selection: $client, options: Client.allCases.map {
                SheetModeOption(value: $0, title: $0.title, detail: $0.detail, icon: $0.icon)
            })
            if let command {
                Divider().overlay(SheetTheme.footerLine)
                Text("Follow these steps").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    steps(command)
                }
            } else {
                Text("The command-line tool is missing from this Daylanes build.").foregroundStyle(SheetTheme.muted)
            }
        } leading: {
            Link("\(client.title) documentation", destination: client.documentation)
                .buttonStyle(SheetButtonStyle(kind: .link))
        }
    }

    private var accessStep: some View {
        SheetStep(number: 1, title: "Choose what it can do",
                  detail: allowSetup ? "The agent can also set up clients, projects, folder mappings and tracking rules."
                      : "The agent can read your ledger but can’t change it.") {
            SheetSegments(selection: $allowSetup, options: [(false, "Read only"), (true, "Read and set up")])
        }
    }

    @ViewBuilder
    private func steps(_ command: AgentMCPCommand) -> some View {
        accessStep
        switch client {
        case .codex, .claude:
            SheetStep(number: 2, title: "Run this once in Terminal",
                      detail: "You need the \(client.title) command-line tool installed.") {
                SheetCopyRow(value: command.registration(using: client.registration ?? ""))
                    .id(client.rawValue + String(allowSetup))
            }
            SheetStep(number: 3, title: "Restart \(client.title) and check",
                      detail: client == .claude
                          ? "Open a local session and use /mcp to look for tracker. In Claude Desktop, use the local Code tab."
                          : "Open a local session and use /mcp to look for tracker.")
            tryStep(4)
        case .chatgpt:
            SheetStep(number: 2, title: "Add a server in the ChatGPT app",
                      detail: "Open Settings → MCP servers → Add server. Name it tracker and choose STDIO.")
            SheetStep(number: 3, title: "Enter this as the command") {
                SheetCopyRow(value: command.executable)
            }
            SheetStep(number: 4, title: "Add each argument", detail: "One per line, in this order. Then save and restart the app.") {
                ForEach(command.arguments, id: \.self) { SheetCopyRow(value: $0) }
            }
            tryStep(5)
        case .other:
            SheetStep(number: 2, title: "Add Daylanes to the client’s MCP settings",
                      detail: "For clients that read an mcpServers JSON file, such as Cursor or Claude Desktop. Merge it with any servers you already have.") {
                SetupCodeBlock(title: "JSON", values: [Self.configuration(command)])
                    .id(allowSetup)
            }
            tryStep(3)
        }
    }

    private func tryStep(_ number: Int) -> some View {
        SheetStep(number: number, title: "Try it", detail: "Ask the agent something about your time.", last: true) {
            SheetCopyRow(value: Self.samplePrompt)
        }
    }

    /// The standard mcpServers entry that most MCP clients read.
    static func configuration(_ command: AgentMCPCommand) -> String {
        let server: [String: Any] = ["command": command.executable, "args": command.arguments]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["tracker": server]], options: options),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

struct SetupCodeBlock: View {
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
