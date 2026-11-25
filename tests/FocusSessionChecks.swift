import Foundation

@main
struct FocusSessionChecks {
    static let origin = Date(timeIntervalSince1970: 1_790_000_000)
    static let editor = ForegroundApp(id: "editor", name: "Editor")
    static let browser = ForegroundApp(id: "browser", name: "Browser")

    static func observation(_ elapsed: Double, app: ForegroundApp? = editor,
                            idle: Double = 0, clockJump: Double = 0) -> FocusObservation {
        FocusObservation(at: origin.addingTimeInterval(elapsed + clockJump), uptime: elapsed, app: app, idle: idle)
    }

    static func main() {
        var focus = FocusSession()
        assert(focus.observe(observation(0, idle: 118)).isEmpty)
        assert(focus.observe(observation(1, idle: 119)).isEmpty)
        let cut = focus.observe(observation(3, idle: 121))
        assert(cut.count == 1 && cut[0].closed && cut[0].end == origin.addingTimeInterval(2))
        assert(focus.observe(observation(4, idle: 122)).isEmpty)
        assert(focus.observe(observation(5, idle: 0.4)).isEmpty)
        assert(focus.activeBlock?.start == origin.addingTimeInterval(4.6))

        let switched = focus.observe(observation(6, app: browser))
        assert(switched.first?.app == editor && switched.first?.end == origin.addingTimeInterval(6))
        assert(focus.observe(observation(7, app: browser)).isEmpty)
        let skipped = focus.observe(observation(60, app: browser))
        assert(skipped.first?.end == origin.addingTimeInterval(7))

        assert(focus.observe(observation(61, app: browser)).isEmpty)
        let clockChanged = focus.observe(observation(62, app: browser, clockJump: -3600))
        assert(clockChanged.first?.end == origin.addingTimeInterval(61))

        focus = FocusSession()
        _ = focus.observe(observation(0))
        _ = focus.observe(observation(1))
        let ignored = focus.observe(observation(2, app: nil))
        assert(ignored.first?.end == origin.addingTimeInterval(2))
        assert(focus.observe(observation(3, app: nil)).isEmpty)
        assert(focus.stop().isEmpty)

        focus = FocusSession()
        _ = focus.observe(observation(0, idle: 119))
        let earlyInput = focus.observe(observation(2, idle: 1.5))
        assert(earlyInput.isEmpty && focus.activeBlock?.end == origin.addingTimeInterval(2))

        focus = FocusSession()
        _ = focus.observe(observation(0, idle: 119))
        let lateInput = focus.observe(observation(2, idle: 0.5))
        assert(lateInput.first?.end == origin.addingTimeInterval(1))
        assert(focus.activeBlock?.start == origin.addingTimeInterval(1.5))

        focus = FocusSession()
        var workBrowser = observation(0, app: browser)
        workBrowser.client = "Work"
        _ = focus.observe(workBrowser)
        var otherBrowser = observation(1, app: browser)
        otherBrowser.client = "Other"
        let profileSwitch = focus.observe(otherBrowser)
        assert(profileSwitch.count == 1 && profileSwitch[0].client == "Work")
        let unmapped = focus.observe(observation(2, app: browser))
        assert(unmapped.count == 1 && unmapped[0].client == "Other" && focus.activeBlock == nil)

        let appRule = FocusRule(id: "app", field: "app", keyword: "browser", appScope: nil,
                                tag: nil, project: "General")
        let client = FocusRule(id: "client", field: "window", keyword: "café client", appScope: "browser",
                               tag: "Review", project: "Client")
        let other = FocusRule(id: "other", field: "window", keyword: "cafe client", appScope: "browser",
                              tag: nil, project: "Other")
        assert(FocusRule.match(rules: [appRule, client], app: "Browser", title: "CAFE CLIENT / Report") == client)
        assert(FocusRule.match(rules: [appRule, client], app: "Browser", title: nil) == appRule)
        assert(FocusRule.match(rules: [appRule, client, other], app: "Browser", title: "Café Client") == nil)
        assert(FocusRule.match(rules: [client], app: "Editor", title: "Café Client") == nil)

        let installed = FocusRule(id: "installed", field: "app", keyword: "Browser", appScope: nil,
                                  tag: nil, project: "Installed", appID: "com.example.browser")
        let rules = [appRule, installed, client]
        assert(FocusRule.match(rules: rules, app: "Browser", appID: "com.example.other", title: nil) == appRule)
        assert(FocusRule.match(rules: rules, app: "Browser", appID: "com.example.browser", title: nil) == installed)
        assert(FocusRule.match(rules: rules, app: "Renamed", appID: "com.example.browser", title: nil) == installed)
        assert(FocusRule.match(rules: rules, app: "Browser", appID: "com.example.browser", title: "Café Client") == client)
        let conflict = FocusRule(id: "conflict", field: "app", keyword: "Browser Renamed", appScope: nil,
                                 tag: nil, project: "Other", appID: "com.example.browser")
        assert(FocusRule.match(rules: rules + [conflict], app: "Browser", appID: "com.example.browser", title: nil) == nil)
        let exactWindow = FocusRule(id: "exact-window", field: "window", keyword: "café client", appScope: "Browser",
                                    tag: nil, project: "Exact", appID: "com.example.browser")
        assert(FocusRule.match(rules: [client, exactWindow], app: "Renamed", appID: "com.example.browser",
                               title: "Café Client") == exactWindow)
        assert(FocusRule.match(rules: [client, exactWindow], app: "Browser", appID: "com.example.other",
                               title: "Café Client") == client)

        let unified = ForegroundApp(id: "com.openai.codex", name: "ChatGPT")
        let classic = ForegroundApp(id: "com.openai.chat", name: "ChatGPT")
        let codexRule = FocusRule(id: "codex", field: "app", keyword: "Codex", appScope: nil, tag: nil, project: "Code")
        let chatRule = FocusRule(id: "chat", field: "app", keyword: "ChatGPT", appScope: nil, tag: nil, project: "Chat")
        assert(unified.displayName == "Codex" && classic.displayName == "ChatGPT")
        assert(FocusRule.match(rules: [codexRule], app: unified.name, appID: unified.id, title: nil) == codexRule)
        assert(FocusRule.match(rules: [chatRule], app: unified.name, appID: unified.id, title: nil) == chatRule)
        assert(FocusRule.match(rules: [codexRule], app: classic.name, appID: classic.id, title: nil) == nil)

        focus = FocusSession()
        var first = observation(0, app: browser)
        first.match = client
        _ = focus.observe(first)
        var second = observation(2, app: browser)
        second.match = appRule
        let ruleChange = focus.observe(second)
        assert(ruleChange.first?.match == client && ruleChange.first?.end == origin.addingTimeInterval(2))
        var third = observation(3, app: browser)
        third.match = appRule
        _ = focus.observe(third)
        assert(focus.stop().first?.match == appRule)

        let domain = FocusRule(id: "domain", field: "domain", keyword: "example.com", appScope: nil,
                               tag: nil, project: "Client")
        let url = FocusRule(id: "url", field: "url", keyword: "https://app.example.com/portal", appScope: nil,
                            tag: "Review", project: "Portal")
        let address = TabAddress("https://APP.EXAMPLE.COM:443/portal/doc?access_token=secret#fragment")
        let ignoredApp = FocusRule(id: "ignored-app", field: "app", keyword: "Browser", appScope: nil,
                                   tag: nil, project: nil, appID: "com.example.browser")
        assert(FocusRule.match(rules: [ignoredApp, domain, url], app: "Browser", appID: "com.example.browser",
                               title: nil, tab: address) == ignoredApp)
        let ignoredPage = GitHubPage(tab: TabAddress("https://github.com/test/project/pull/1")!,
                                    routes: ["test/project": GitHubRoute(project: "Portal", pullRequests: [:])])!
        let ignoredBlock = FocusBlock(app: browser, start: origin, match: ignoredApp,
                                      github: ignoredPage, client: "Work", end: origin.addingTimeInterval(3))
        let encoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(ignoredBlock)) as! [String: Any]
        assert(encoded["ignored"] as? Bool == true && encoded["match"] == nil && encoded["github"] == nil && encoded["client"] == nil)
        assert(address?.path == "/portal/doc")
        assert(FocusRule.match(rules: [appRule, domain, url], app: "Browser", title: nil, tab: address) == url)
        assert(FocusRule.match(rules: [domain, url], app: "Browser", title: nil,
                               tab: TabAddress("https://app.example.com/portal-extra")) == domain)
        assert(TabAddress("https://example.com.other.test/")?.matches(domain: "example.com") == false)
        assert(TabAddress("http://app.example.com/portal")?.matches(prefix: url.keyword) == false)
        assert(TabAddress("https://app.example.com:8443/portal")?.matches(prefix: url.keyword) == false)
        let workProfile = FocusRule(id: "work", field: "domain", keyword: "mail.google.com", appScope: nil,
                                    tag: nil, project: "Work", chromeProfile: "Work")
        let personalProfile = FocusRule(id: "personal", field: "domain", keyword: "mail.google.com", appScope: nil,
                                        tag: nil, project: "Personal", chromeProfile: "Personal")
        let legacyMailWindow = FocusRule(id: "legacy", field: "domain", keyword: "mail.google.com", appScope: "Work",
                                         tag: nil, project: "Legacy Window")
        let profileInbox = TabAddress("https://mail.google.com/mail/u/0/")
        let mailRules = [workProfile, personalProfile, legacyMailWindow]
        assert(FocusRule.match(rules: mailRules, app: "Google Chrome", title: nil, tab: profileInbox,
                               chromeProfile: "work") == workProfile)
        assert(FocusRule.match(rules: mailRules, app: "Google Chrome", title: nil, tab: profileInbox,
                               chromeProfile: "Personal") == personalProfile)
        assert(FocusRule.match(rules: mailRules, app: "Google Chrome", title: nil, tab: profileInbox,
                               chromeWindow: "Work") == legacyMailWindow)
        assert(FocusRule.match(rules: mailRules, app: "Google Chrome", title: nil, tab: profileInbox) == nil)
        assert(TabAddress("chrome://settings") == nil)

        // Only tabs that need intervention appear on the day timeline.
        var savedTab = ChromeObservation(address: profileInbox!, windowName: "Work", profile: "Work",
                                         app: browser, title: nil)
        assert(savedTab.rulePrompt == .create)
        savedTab.rematch(rules: [workProfile], automatic: [], routes: [:])
        assert(savedTab.resolution.rule == workProfile && savedTab.rulePrompt == nil)
        savedTab.rematch(rules: [workProfile, legacyMailWindow], automatic: [], routes: [:])
        assert(savedTab.rulePrompt == .reviewConflict && savedTab.resolution.rule == nil)
        savedTab.rematch(rules: [personalProfile], automatic: [], routes: [:])
        assert(savedTab.rulePrompt == .create)
        savedTab.rematch(rules: [appRule], automatic: [], routes: [:])
        assert(savedTab.resolution.rule == appRule && savedTab.rulePrompt == nil)

        let chromeProfileRule = FocusRule(id: "chrome", field: "domain", keyword: "mail.google.com", appScope: nil,
                                          tag: nil, project: "Client", chromeProfileID: "Profile 12")
        savedTab.rematch(rules: [chromeProfileRule], automatic: [], routes: [:])
        assert(savedTab.rulePrompt == .create)
        savedTab.profileID = "Profile 12"
        savedTab.rematch(rules: [chromeProfileRule], automatic: [], routes: [:])
        assert(savedTab.resolution.rule == chromeProfileRule && savedTab.rulePrompt == nil)
        savedTab.profileID = "Profile 13"
        savedTab.rematch(rules: [chromeProfileRule], automatic: [], routes: [:])
        assert(savedTab.rulePrompt == .create)

        let privateWindow = ChromeTabs.readWindow(frontID: { "1" }, properties: { property, _ in
            if property == .url { fatalError("Tried to read an Incognito URL") }
            return "incognito"
        })
        assert(privateWindow == .privateWindow)
        let normalWindow = ChromeTabs.readWindow(frontID: { "1" }, properties: { property, id in
            assert(id == "1")
            switch property {
            case .mode: return "normal"
            case .url: return "https://app.example.com/portal/doc"
            case .windowName: return "Work"
            }
        })
        assert(normalWindow == .tab(TabAddress("https://app.example.com/portal/doc")!, windowName: "Work"))
        let newTab = ChromeTabs.readWindow(frontID: { "1" }, properties: { property, _ in
            property == .mode ? "normal" : "chrome://newtab/"
        })
        assert(newTab == .normalWindow)
        assert(address?.originAndPath == "https://app.example.com/portal/doc")
        let workMail = FocusRule(id: "work", field: "domain", keyword: "mail.google.com", appScope: "Client Mail",
                                 tag: "Email", project: "Client")
        let personalMail = FocusRule(id: "personal", field: "domain", keyword: "mail.google.com", appScope: "Personal",
                                     tag: nil, project: "Personal")
        let inbox = TabAddress("https://mail.google.com/mail/u/0/#inbox")
        assert(FocusRule.match(rules: [workMail, personalMail], app: "Chrome", title: nil,
                               tab: inbox, chromeWindow: "client mail") == workMail)
        assert(FocusRule.match(rules: [workMail, personalMail], app: "Chrome", title: nil,
                               tab: inbox, chromeWindow: "Personal") == personalMail)
        assert(FocusRule.match(rules: [workMail, personalMail], app: "Chrome", title: nil, tab: inbox) == nil)

        let routes = ["owner/repo": GitHubRoute(project: "Repo project", pullRequests: ["42": "PR project"])]
        let githubPR = GitHubPage(tab: TabAddress("https://github.com/Owner/Repo/pull/42/files?secret=1")!, routes: routes)
        let githubRepo = GitHubPage(tab: TabAddress("https://github.com/owner/repo/issues/42")!, routes: routes)
        assert(githubPR?.match(in: routes)?.project == "PR project")
        assert(githubRepo?.match(in: routes)?.project == "Repo project")
        assert(GitHubPage(tab: TabAddress("https://github.com.evil.test/owner/repo/pull/42")!, routes: routes) == nil)
        assert(GitHubPage(tab: TabAddress("https://github.com/other/repo/pull/42")!, routes: routes) == nil)
        assert(FocusRule.match(rules: [appRule], app: "Browser", title: nil,
                               githubMatch: githubPR?.match(in: routes)) == appRule)
        let githubAddress = TabAddress("https://github.com/owner/repo/pull/42")!
        let profileRoute = FocusRule(id: "github-work", field: "domain", keyword: "github.com",
                                     appScope: nil, tag: nil, project: "UK work", chromeProfile: "Work")
        let fallback = githubPR?.match(in: routes)
        assert(FocusRule.match(rules: [profileRoute], app: "Chrome", title: nil, tab: githubAddress,
                               chromeProfile: "Work", githubMatch: fallback) == profileRoute)
        assert(FocusRule.match(rules: [profileRoute], app: "Chrome", title: nil, tab: githubAddress,
                               chromeProfile: "Personal", githubMatch: fallback) == fallback)
        var repoSession = FocusSession()
        var prObservation = observation(0, app: browser)
        prObservation.github = githubPR
        prObservation.match = githubPR?.match(in: routes)
        assert(repoSession.observe(prObservation).isEmpty)
        var repoObservation = observation(3, app: browser)
        repoObservation.github = githubRepo
        repoObservation.match = githubRepo?.match(in: routes)
        let prBlock = repoSession.observe(repoObservation).first
        assert(prBlock?.github?.number == 42 && prBlock?.match?.project == "PR project")

        var window = 0
        let switchedWindow = ChromeTabs.readWindow(frontID: {
            window += 1
            return String(window)
        }, properties: { property, _ in property == .mode ? "normal" : "https://app.example.com/portal" })
        assert(switchedWindow == .unavailable)
        print("Focus session checks passed")
    }
}
