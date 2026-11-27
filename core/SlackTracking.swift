import Foundation

/// Slack context from the active browser tab or the foreground desktop window.
struct SlackTrackingContext: Equatable, Sendable {
    enum ChannelRule: Equatable, Sendable {
        case website(String)
        case windowTitle(String)
    }

    static let desktopAppID = "com.tinyspeck.slackmacgap"
    let workspaceID: String?
    let desktopName: String?
    let channelRule: ChannelRule?

    static func browser(_ value: String) -> Self? {
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "app.slack.com", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { return nil }
        let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "client",
              validWorkspaceID(String(parts[2])) else { return nil }
        let workspaceID = String(parts[2])
        let channel: ChannelRule? = if parts.count >= 4,
            parts[3].range(of: #"\A[CG][A-Z0-9]{2,31}\z"#, options: .regularExpression) != nil {
            .website("https://app.slack.com/client/\(workspaceID)/\(parts[3])")
        } else { nil }
        return Self(workspaceID: workspaceID, desktopName: nil, channelRule: channel)
    }

    static func desktop(_ title: String) -> Self? {
        let parts = title.components(separatedBy: " - ")
        // Slack titles observed on macOS use Conversation - Workspace - Slack.
        guard parts.count >= 3, parts.last == "Slack", let name = workspaceName(parts.dropFirst().dropLast().joined(separator: " - ")),
              !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let conversation = parts[0].replacingOccurrences(of: #"\A\([0-9]+\) +"#, with: "", options: .regularExpression)
        let isChannel = conversation.hasPrefix("#") || conversation.lowercased().hasSuffix(" (channel)")
        let channelRule: ChannelRule? = isChannel ? .windowTitle("\(conversation) - \(name) - Slack") : nil
        return Self(workspaceID: nil, desktopName: name, channelRule: channelRule)
    }

    static func workspaceID(fromInput value: String) -> String? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = input.uppercased()
        return validWorkspaceID(candidate) ? candidate : browser(input)?.workspaceID
    }

    static func workspaceName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 150,
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return name
    }

    private static func validWorkspaceID(_ id: String) -> Bool {
        id.range(of: #"\A[TE][A-Z0-9]{2,31}\z"#, options: .regularExpression) != nil
    }
}

enum SlackWorkspaceMenu {
    /// Slack puts its signed-in workspaces before the first separator. Only the first nine need shortcuts.
    static func names(beforeSeparator titles: [String]) -> [String]? {
        let entries = titles.prefix { !$0.isEmpty }
        guard !entries.isEmpty, entries.count < titles.count else { return nil }
        var names: [String] = []
        for title in entries {
            guard let name = SlackTrackingContext.workspaceName(title),
                  !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            names.append(name)
        }
        return names.isEmpty ? nil : names
    }
}

struct SlackWorkspaceClient: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let workspaceID: String?
    let desktopName: String?
    let client: String

    enum CodingKeys: String, CodingKey {
        case id, workspaceID = "workspace_id", desktopName = "desktop_name", client
    }

    static func match(_ context: SlackTrackingContext, in mappings: [Self]) -> Self? {
        if let workspaceID = context.workspaceID { return mappings.first { $0.workspaceID == workspaceID } }
        guard let name = context.desktopName else { return nil }
        let matches = mappings.filter { $0.desktopName?.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }
}
