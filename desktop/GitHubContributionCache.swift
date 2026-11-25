import Combine
import Foundation

@MainActor
final class GitHubContributionCache: ObservableObject {
    static let shared = GitHubContributionCache()

    private struct Key: Codable, Hashable {
        let repo: String
        let author: String
        let range: LedgerRange
    }

    private struct Count: Codable {
        let value: Int
        let fetchedAt: Date
    }

    private struct Entry: Codable {
        let key: Key
        var commits: Count?
        var pullRequests: Count?

        var lastUpdated: Date { max(commits?.fetchedAt ?? .distantPast, pullRequests?.fetchedAt ?? .distantPast) }
    }

    private struct AuthSource: Equatable {
        let path: String
        let version: LedgerSnapshots.FileVersion?

        static var current: Self {
            let env = ProcessInfo.processInfo.environment
            let directory = env["GH_CONFIG_DIR"].nonEmpty
                ?? env["XDG_CONFIG_HOME"].nonEmpty.map { $0 + "/gh" } ?? NSHomeDirectory() + "/.config/gh"
            let path = directory + "/hosts.yml"
            return Self(path: path, version: LedgerSnapshots.FileVersion(path))
        }
    }

    private struct Identity {
        let source: AuthSource
        let author: String?
        let checkedAt: Date
    }

    private let file: URL?
    @Published private var entries: [Key: Entry] = [:]
    @Published private var identity: Identity?
    private var authorLookup: (source: AuthSource, task: Task<String?, Never>)?
    private var lookups: [Key: Task<Bool, Never>] = [:]
    // Each range costs two searches. Reserve slots for the visible range and other GitHub CLI activity.
    private var recentRequests: [Date] = []
    private var lastAttempts: [Key: Date] = [:]

    init(cacheRoot: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        file = cacheRoot?.appendingPathComponent("com.domenicodidonna.tracker/GitHub-contributions-v1/counts.json")
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { $0.lastUpdated > $1.lastUpdated ? $0 : $1 })
        }
    }

    func counts(repo: String, range: LedgerRange) -> (commits: Int?, pullRequests: Int?) {
        guard let identity, identity.source == .current, let author = identity.author,
              let entry = entries[Key(repo: repo.lowercased(), author: author, range: range)] else { return (nil, nil) }
        return (entry.commits?.value, entry.pullRequests?.value)
    }

    func prepare(repo: String, range: LedgerRange, refreshedAt: Double?) async {
        guard let repo = try? GitHub.repoName(repo), let identity = await resolveIdentity(),
              let author = identity.author else { return }
        let now = Date.now
        let otherRanges = Period.presets.map { $0.range(timezone: range.timezone, now: now) }.filter { $0 != range }
        for (index, candidate) in ([range] + otherRanges).enumerated() {
            guard !Task.isCancelled, identity.source == .current else { return }
            let key = Key(repo: repo, author: author, range: candidate)
            if !(await refresh(key, source: identity.source, refreshedAt: refreshedAt, prefetch: index != 0)) { return }
        }
    }

    private func resolveIdentity() async -> Identity? {
        let source = AuthSource.current
        if let identity, identity.source == source,
           Date.now.timeIntervalSince(identity.checkedAt) < (identity.author == nil ? 60 : 3600) { return identity }

        let task: Task<String?, Never>
        if let existing = authorLookup, existing.source == source {
            task = existing.task
        } else {
            task = Task { await GitHub.contributionAuthor() }
            authorLookup = (source, task)
        }
        let author = await task.value
        guard source == .current else { return nil }
        if authorLookup?.source == source { authorLookup = nil }
        let verified = Identity(source: source, author: author, checkedAt: .now)
        identity = verified
        return verified
    }

    private func refresh(_ key: Key, source: AuthSource, refreshedAt: Double?, prefetch: Bool) async -> Bool {
        if let task = lookups[key] { return await task.value }
        let now = Date.now
        let repoRefreshed = refreshedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        let freshSince = max(now.addingTimeInterval(-86_400), repoRefreshed)
        let cached = entries[key]
        if let commits = cached?.commits, let pulls = cached?.pullRequests,
           commits.fetchedAt >= freshSince, pulls.fetchedAt >= freshSince { return true }

        let minuteAgo = now.addingTimeInterval(-60)
        recentRequests.removeAll { $0 <= minuteAgo }
        lastAttempts = lastAttempts.filter { $0.value > minuteAgo }
        if let attempted = lastAttempts[key], attempted >= repoRefreshed { return false }
        guard recentRequests.count < (prefetch ? 10 : 14) else { return false }
        recentRequests.append(now)
        lastAttempts[key] = now

        let task = Task {
            let range = key.range
            let result = await GitHub.contributionCounts(repo: key.repo, author: key.author, start: range.start,
                                                         end: range.endExclusive, timezone: range.timezone)
            guard source == .current, let result, result.commits != nil || result.pullRequests != nil else { return false }
            var entry = entries[key] ?? Entry(key: key)
            if let commits = result.commits { entry.commits = Count(value: commits, fetchedAt: now) }
            if let pulls = result.pullRequests { entry.pullRequests = Count(value: pulls, fetchedAt: now) }
            entries[key] = entry
            persist()
            return true
        }
        lookups[key] = task
        let success = await task.value
        lookups[key] = nil
        return success
    }

    private func persist() {
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        let retained = entries.values.filter { $0.lastUpdated >= cutoff }
            .sorted { $0.lastUpdated > $1.lastUpdated }.prefix(512)
        if retained.count < entries.count { entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0) }) }
        guard let file, let data = try? JSONEncoder().encode(Array(retained)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
    }
}
