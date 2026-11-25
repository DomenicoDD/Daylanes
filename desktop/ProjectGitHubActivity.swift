import SwiftUI

struct ProjectGitHubActivity: View {
    let repo: String
    let start: String
    let end: String
    let timezone: String
    let refreshedAt: Double?

    private struct Query: Hashable {
        let repo: String
        let range: LedgerRange
        let refreshedAt: Double?
    }

    @ObservedObject private var cache = GitHubContributionCache.shared

    var body: some View {
        let range = LedgerRange(start: start, endExclusive: end, timezone: timezone)
        let query = Query(repo: repo, range: range, refreshedAt: refreshedAt)
        let counts = cache.counts(repo: repo, range: range)
        HStack(spacing: 16) {
            if let commits = counts.commits {
                Label(commits == 1 ? "1 commit" : "\(commits.formatted()) commits", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .help("Commits you authored on the default branch of \(repo)")
            }
            if let pulls = counts.pullRequests {
                Label(pulls == 1 ? "1 pull request" : "\(pulls.formatted()) pull requests", systemImage: "arrow.triangle.branch")
                    .help("Pull requests you opened in \(repo)")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .task(id: query) {
            while !Task.isCancelled {
                await cache.prepare(repo: query.repo, range: query.range, refreshedAt: query.refreshedAt)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}
