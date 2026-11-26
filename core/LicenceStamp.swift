import Foundation

/// What the agent tools need to know about the licence, written by the app for the MCP server.
///
/// The app keeps the trial and the licence in the Keychain (desktop/Licensing.swift). The MCP server and
/// `tracker call` are separate programs started by an agent, where a Keychain prompt would block, so the
/// app also writes this small file. They lock the same way the app does: after the trial, without a
/// key, only get_status answers (Domenico, 2026-11-25).
///
/// The file is not signed. Daylanes is open source, so any key in the code would be public, and anyone
/// who wants to skip the lock can build without it. The lock is for the shipped app, like the trial.
enum LicenceStamp {
    struct Stamp: Equatable {
        var licensed: Bool
        var trialEndsAt: Date
    }

    static let fileName = "licence-stamp.json"
    private static let version = 1

    /// ~/Library/Application Support/Daylanes/licence-stamp.json, with $HOME first like the ledger path
    /// (core/Values.swift), so a test with its own HOME never reads or writes the real stamp.
    static var defaultPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return home + "/Library/Application Support/Daylanes/" + fileName
    }

    static func write(_ stamp: Stamp, to path: String = defaultPath) throws {
        let object = JSON.object([
            ("version", .int(Int64(version))), ("licensed", .bool(stamp.licensed)),
            ("trial_ends_at", .int(Int64(stamp.trialEndsAt.timeIntervalSince1970.rounded(.down)))),
        ])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(object.pythonText(indent: nil).utf8).write(to: url, options: .atomic)
    }

    /// The stamp, or nil when the file is missing or unreadable.
    static func read(from path: String = defaultPath) -> Stamp? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSON.parse(String(decoding: data, as: UTF8.self)),
              json["version"].intValue == version,
              let licensed = json["licensed"].boolValue,
              let ends = json["trial_ends_at"].intValue else { return nil }
        return Stamp(licensed: licensed, trialEndsAt: Date(timeIntervalSince1970: TimeInterval(ends)))
    }

    /// Whether this build sells licences. A source build without payments (`TRACKER_ENABLE_PAYMENTS=0`,
    /// the default in bin/build-desktop) has no trial and never writes a stamp, so nothing is locked.
    #if TRACKER_PAYMENTS
    static let enforced = true
    #else
    static let enforced = false
    #endif

    /// Why the agent tools are locked, or nil when they may run. No stamp means the app was never opened.
    static func lockReason(path: String = defaultPath, now: Date = .now, enforced: Bool = LicenceStamp.enforced) -> String? {
        guard enforced else { return nil }
        guard let stamp = read(from: path) else {
            return "Open the Daylanes app once to start your free trial. The agent tools work during the trial and with a licence."
        }
        if stamp.licensed || now < stamp.trialEndsAt { return nil }
        return "Your Daylanes trial has ended. Buy a licence in the Daylanes app to use your data with agents again. Tracking has continued, so nothing is lost."
    }
}
