import Foundation

struct FocusRule: Codable, Equatable, Identifiable {
    let id: String
    let field: String
    let keyword: String
    let appScope: String?
    let tag: String?
    let project: String?
    var appID: String? = nil
    var chromeProfile: String? = nil
    var chromeProfileID: String? = nil
    /// Set on rules Tracker makes from a project's or client's name: "project" or "client".
    var automatic: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, field, keyword, appScope = "app_scope", tag, project, appID = "app_id"
        case chromeProfile = "chrome_profile", chromeProfileID = "chrome_profile_id", automatic
    }

    var needsWindowTitle: Bool { field == "window" }
    var needsBrowserTab: Bool { field == "domain" || field == "url" }
    var isIgnored: Bool { project == nil }
    var fieldLabel: String {
        switch field {
        case "github": "GitHub"
        case "window": "Window title"
        case "domain": "Domain"
        case "url": "URL prefix"
        default: appID == nil ? "App name contains" : "App"
        }
    }

    func appliesToApp(_ name: String, id: String?) -> Bool {
        if let appID { return appID == id }
        guard let appScope else { return true }
        return Self.contains(name, appScope) || Self.contains(ForegroundApp.displayName(name, bundleID: id), appScope)
    }

    enum Resolution: Equatable {
        case unmatched, conflict, matched(FocusRule)

        var rule: FocusRule? {
            if case let .matched(rule) = self { return rule }
            return nil
        }
    }

    static func match(rules: [Self], app: String, appID: String? = nil, title: String?, tab: TabAddress? = nil,
                      chromeWindow: String? = nil, chromeProfile: String? = nil, chromeProfileID: String? = nil,
                      githubMatch: Self? = nil) -> Self? {
        resolve(rules: rules, app: app, appID: appID, title: title, tab: tab,
                chromeWindow: chromeWindow, chromeProfile: chromeProfile, chromeProfileID: chromeProfileID,
                githubMatch: githubMatch).rule
    }

    static func resolve(rules: [Self], app: String, appID: String? = nil, title: String?, tab: TabAddress? = nil,
                        chromeWindow: String? = nil, chromeProfile: String? = nil, chromeProfileID: String? = nil,
                        githubMatch: Self? = nil, automatic: [Self] = []) -> Resolution {
        let matching = candidates(rules: rules, app: app, appID: appID, title: title, tab: tab,
                                  chromeWindow: chromeWindow, chromeProfile: chromeProfile, chromeProfileID: chromeProfileID)
        let ignored = matching.filter(\.isIgnored)
        let result = winner(ignored.isEmpty ? matching : ignored)
        guard result == .unmatched else { return result }
        if let githubMatch { return .matched(githubMatch) }
        return winner(candidates(rules: automatic, app: app, title: title))
    }

    private static func winner(_ candidates: [Self]) -> Resolution {
        guard let strongest = candidates.max(by: { $0.priority < $1.priority }) else { return .unmatched }
        let tied = candidates.filter { $0.priority == strongest.priority }
        guard tied.allSatisfy({ $0.project == strongest.project && $0.tag == strongest.tag }) else { return .conflict }
        return .matched(tied.min { $0.id < $1.id } ?? strongest)
    }

    /// The rules that apply to this activity, before ties between them are settled.
    static func candidates(rules: [Self], app: String, appID: String? = nil, title: String?, tab: TabAddress? = nil,
                           chromeWindow: String? = nil, chromeProfile: String? = nil,
                           chromeProfileID: String? = nil) -> [Self] {
        let displayName = ForegroundApp.displayName(app, bundleID: appID)
        return rules.filter { rule in
            if let expected = rule.chromeProfileID, expected != chromeProfileID { return false }
            if let scope = rule.chromeProfile {
                guard let chromeProfile, chromeProfile.caseInsensitiveCompare(scope) == .orderedSame else {
                    return false
                }
            }
            if rule.needsBrowserTab, let scope = rule.appScope {
                guard let chromeWindow,
                      chromeWindow.compare(scope, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                else { return false }
            }
            if rule.field == "domain" {
                return tab?.matches(domain: rule.keyword) == true
            }
            if rule.field == "url" {
                return tab?.matches(prefix: rule.keyword) == true
            }
            if rule.needsWindowTitle {
                return rule.appliesToApp(app, id: appID) && title.map { contains($0, rule.keyword) } == true
            }
            if let target = rule.appID { return target == appID }
            return contains(app, rule.keyword) || contains(displayName, rule.keyword)
        }
    }

    private var priority: Int {
        // App identifiers take precedence over app-name keywords. Their display names don't break ties.
        if field == "app", appID != nil { return 700 }
        // Each source has a separate range. The ledger limits URL rules to 512 characters.
        let rank = ["url": 3, "domain": 2, "window": 1, "app": 0][field, default: 0]
        let appSpecificity = appID != nil ? 2 : appScope == nil ? 0 : 1
        let scopeCount = appSpecificity + (chromeProfile == nil && chromeProfileID == nil ? 0 : 1)
        return rank * 2000 + scopeCount * 700 + keyword.count
    }

    private static func contains(_ value: String, _ keyword: String) -> Bool {
        value.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}

/// The last tab's matching inputs stay available when Chrome is in the background.
struct ChromeObservation: Equatable {
    enum RulePrompt { case create, reviewConflict }

    let address: TabAddress
    let windowName: String?
    let profile: String?
    var profileID: String? = nil
    let app: ForegroundApp
    let title: String?
    var resolution: FocusRule.Resolution = .unmatched

    var rulePrompt: RulePrompt? {
        switch resolution {
        case .unmatched: .create
        case .conflict: .reviewConflict
        case .matched: nil
        }
    }

    mutating func rematch(rules: [FocusRule], automatic: [FocusRule], routes: [String: GitHubRoute]) {
        let githubMatch = GitHubPage(tab: address, routes: routes)?.match(in: routes)
        resolution = FocusRule.resolve(rules: rules, app: app.name, appID: app.id, title: title, tab: address,
                                       chromeWindow: windowName, chromeProfile: profile, chromeProfileID: profileID,
                                       githubMatch: githubMatch,
                                       automatic: automatic)
    }
}

struct TabAddress: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int
    let path: String

    var originAndPath: String {
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host)\(port == defaultPort ? "" : ":\(port)")\(path)"
    }

    init?(_ value: String) {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", parts.user == nil, parts.password == nil,
              var host = parts.url?.host()?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        self.host = host
        self.scheme = scheme
        self.port = parts.port ?? (scheme == "https" ? 443 : 80)
        let path = parts.percentEncodedPath
        self.path = path.isEmpty ? "/" : path
    }

    func matches(domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    func matches(prefix value: String) -> Bool {
        guard let prefix = Self(value), prefix.scheme == scheme, prefix.host == host, prefix.port == port else {
            return false
        }
        return prefix.path == "/" || path == prefix.path || path.hasPrefix(prefix.path + "/")
    }
}

struct GitHubPage: Codable, Equatable {
    let repo: String
    let number: Int?

    init?(tab: TabAddress, routes: [String: GitHubRoute]) {
        guard tab.host == "github.com", tab.scheme == "https", tab.port == 443 else { return nil }
        let segments = tab.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        let repo = segments.prefix(2).joined(separator: "/").lowercased()
        guard routes[repo] != nil else { return nil }
        self.repo = repo
        if segments.count >= 4, segments[2] == "pull",
           let number = Int(segments[3]), number > 0, number <= Int(Int32.max), String(number) == segments[3] {
            self.number = number
        } else {
            number = nil
        }
    }

    func match(in routes: [String: GitHubRoute]) -> FocusRule? {
        guard let route = routes[repo],
              let project = number.flatMap({ route.pullRequests[String($0)] }) ?? route.project else { return nil }
        let identifier = number.map { "\(repo)#\($0)" } ?? repo
        return FocusRule(id: "github:" + identifier, field: "github", keyword: identifier,
                         appScope: nil, tag: nil, project: project)
    }
}

struct GitHubRoute: Decodable {
    let project: String?
    let pullRequests: [String: String]

    enum CodingKeys: String, CodingKey {
        case project, pullRequests = "pull_requests"
    }
}

struct FocusConfig: Decodable {
    let enabled: Bool
    let rules: [FocusRule]
    let autoRules: [FocusRule]?
    let autoRulesOff: [String]?
    let githubRoutes: [String: GitHubRoute]
    let chromeProfileClients: [String: String]?

    enum CodingKeys: String, CodingKey {
        case enabled, rules, autoRules = "auto_rules", autoRulesOff = "auto_rules_off", githubRoutes = "github_routes"
        case chromeProfileClients = "chrome_profile_clients"
    }
}
