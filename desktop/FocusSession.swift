import Foundation

struct ForegroundApp: Equatable {
    let id: String
    let name: String

    var displayName: String { Self.displayName(name, bundleID: id) }

    static func displayName(_ name: String, bundleID: String?) -> String {
        bundleID == "com.openai.codex" ? "Codex" : name
    }
}

struct FocusObservation {
    let at: Date
    let uptime: TimeInterval
    var app: ForegroundApp?
    let idle: TimeInterval
    var match: FocusRule? = nil
    var github: GitHubPage? = nil
    var client: String? = nil
}

struct FocusBlock: Encodable, Identifiable {
    let id = UUID()
    let app: ForegroundApp
    let start: Date
    let match: FocusRule?
    let github: GitHubPage?
    let client: String?
    var end: Date
    var closed = false

    enum CodingKeys: String, CodingKey {
        case id, appID = "app_id", appName = "app_name"
        case start = "started_at", end = "ended_at", closed, match, github, client, ignored
    }

    func encode(to encoder: Encoder) throws {
        var output = encoder.container(keyedBy: CodingKeys.self)
        try output.encode(id.uuidString.lowercased(), forKey: .id)
        try output.encode(app.id, forKey: .appID)
        try output.encode(app.name, forKey: .appName)
        try output.encode(Int64(start.timeIntervalSince1970 * 1000), forKey: .start)
        try output.encode(Int64(end.timeIntervalSince1970 * 1000), forKey: .end)
        try output.encode(closed, forKey: .closed)
        if match?.isIgnored == true {
            try output.encode(true, forKey: .ignored)
        } else {
            try output.encodeIfPresent(match, forKey: .match)
            try output.encodeIfPresent(github, forKey: .github)
            try output.encodeIfPresent(client, forKey: .client)
        }
    }
}

struct FocusSession {
    static let idleLimit: TimeInterval = 120
    private let maxSampleGap: TimeInterval = 6
    private var previous: FocusObservation?
    private(set) var activeBlock: FocusBlock?

    mutating func observe(_ next: FocusObservation) -> [FocusBlock] {
        defer { previous = next }
        guard let last = previous else { return [] }
        let elapsed = next.uptime - last.uptime
        let wallElapsed = next.at.timeIntervalSince(last.at)
        guard elapsed >= 0, elapsed <= maxSampleGap, wallElapsed >= 0,
              abs(elapsed - wallElapsed) < 2 else {
            return finish()
        }

        var completed: [FocusBlock] = []
        let idleAt = last.at.addingTimeInterval(Self.idleLimit - last.idle)
        let latestInput = next.at.addingTimeInterval(-next.idle)
        let inputContinued = next.idle < Self.idleLimit && latestInput > last.at && latestInput <= idleAt
        if let app = last.app, last.idle < Self.idleLimit {
            accrue(app: app, observation: last, from: last.at, to: inputContinued ? next.at : min(next.at, idleAt))
        }

        if next.app != last.app || next.match != last.match || next.github != last.github || next.client != last.client
            || next.at >= idleAt && !inputContinued {
            completed += finish()
        }
        if let app = next.app, next.app == last.app, next.idle < Self.idleLimit,
           latestInput > max(last.at, idleAt), latestInput < next.at {
            // Input after an idle gap begins a new interval. The gap stays uncovered.
            accrue(app: app, observation: next, from: latestInput, to: next.at)
        }
        return completed
    }

    mutating func stop() -> [FocusBlock] {
        previous = nil
        return finish()
    }

    private mutating func accrue(app: ForegroundApp, observation: FocusObservation, from start: Date, to end: Date) {
        guard end.timeIntervalSince(start) >= 0.001 else { return }
        if activeBlock == nil {
            activeBlock = FocusBlock(app: app, start: start, match: observation.match, github: observation.github,
                                     client: observation.client, end: end)
        } else {
            activeBlock?.end = end
        }
    }

    private mutating func finish() -> [FocusBlock] {
        guard var block = activeBlock else { return [] }
        activeBlock = nil
        block.closed = true
        return [block]
    }
}
