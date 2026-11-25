import CryptoKit
import Foundation

struct LedgerRange: Hashable, Codable, Sendable {
    let start: String
    let endExclusive: String
    let timezone: String

    var arguments: [String] { ["--start", start, "--end", endExclusive] }

    func matches(_ snapshot: Snapshot) -> Bool {
        start == snapshot.start && endExclusive == snapshot.endExclusive && timezone == snapshot.timezone
    }
}

/// Derived views of the ledger. Each menu option gets one replaceable file and one decoded copy.
actor LedgerSnapshots {
    struct FileVersion: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init?(_ path: String) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let device = attrs[.systemNumber] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber,
                  let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date else { return nil }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified
        }
    }

    struct Version: Codable, Equatable {
        let database: FileVersion
        let wal: FileVersion?

        func isSameLedger(as other: Self) -> Bool {
            database.device == other.database.device && database.inode == other.database.inode
        }
    }

    struct Request {
        let period: Period
        let range: LedgerRange
        let version: Version?
    }

    struct Cached {
        let snapshot: Snapshot
        let createdAt: Date
        let version: Version

        func madeToday(now: Date = .now) -> Bool {
            guard let zone = TimeZone(identifier: snapshot.timezone) else { return false }
            return Day.local(Int(createdAt.timeIntervalSince1970 * 1000), zone)
                == Day.local(Int(now.timeIntervalSince1970 * 1000), zone)
        }
    }

    private struct File: Codable {
        let createdAt: Date
        let version: Version
        let data: Data
    }

    private struct Build {
        let id: UUID
        let startedAt: Date
        let request: Request
        let task: Task<(Snapshot, Data), Error>
    }

    private let database: String
    private let directory: URL?
    private var memory: [String: Cached] = [:]
    private var builds: [String: Build] = [:]

    init(database: String = Values.databasePath(),
         cacheRoot: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        let resolved = Values.resolvedPath(database)
        let fingerprint = SHA256.hash(data: Data(resolved.utf8)).map { String(format: "%02x", $0) }.joined()
        self.database = resolved
        self.directory = cacheRoot?.appendingPathComponent("com.domenicodidonna.tracker/Snapshots-v1/\(fingerprint)")
    }

    func request(_ period: Period, timezone fallback: String) -> Request {
        let timezone = (try? Database.readOnly(database, timeout: 0.1)).flatMap { try? Store.timezoneName($0) } ?? fallback
        let version = FileVersion(database).map { Version(database: $0, wal: FileVersion(database + "-wal")) }
        return Request(period: period, range: period.range(timezone: timezone), version: version)
    }

    func cached(for request: Request) -> Cached? {
        guard let version = request.version else { return nil }
        let slot = request.period.cacheSlot
        if let entry = memory[slot], request.range.matches(entry.snapshot),
           entry.version.isSameLedger(as: version) { return entry }

        guard let url = file(for: slot), let data = try? Data(contentsOf: url),
              let saved = try? PropertyListDecoder().decode(File.self, from: data),
              saved.version.isSameLedger(as: version), let snapshot = try? Ledger.decodeSnapshot(saved.data),
              snapshot.database == database, request.range.matches(snapshot) else { return nil }
        let entry = Cached(snapshot: snapshot, createdAt: saved.createdAt, version: saved.version)
        memory[slot] = entry
        return entry
    }

    func rebuild(_ request: Request, priority: TaskPriority = .userInitiated,
                 afterEdit: Bool = false, earliestBuild: Date = .distantPast) async throws -> Snapshot {
        let slot = request.period.cacheSlot
        if let build = builds[slot], build.request.range == request.range,
           build.startedAt >= earliestBuild, !afterEdit || build.request.version == request.version {
            return try await build.task.value.0
        }

        let database = self.database
        let id = UUID()
        let startedAt = Date.now
        let task = Task.detached(priority: priority) {
            guard let data = try CLI.run(["--db", database, "snapshot", "--with-human-time"] + request.range.arguments) else {
                throw Ledger.CommandError(message: "Daylanes couldn’t build this snapshot.")
            }
            return (try Ledger.decodeSnapshot(data), data)
        }
        builds[slot] = Build(id: id, startedAt: startedAt, request: request, task: task)
        defer {
            if builds[slot]?.id == id { builds[slot] = nil }
        }
        let (snapshot, data) = try await task.value
        if builds[slot]?.id == id, let version = request.version, request.range.matches(snapshot) {
            let entry = Cached(snapshot: snapshot, createdAt: startedAt, version: version)
            memory[slot] = entry
            if let directory, let url = file(for: slot) {
                let saved = File(createdAt: entry.createdAt, version: version, data: data)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                if let encoded = try? PropertyListEncoder().encode(saved) { try? encoded.write(to: url, options: .atomic) }
            }
        }
        return snapshot
    }

    private func file(for slot: String) -> URL? {
        directory?.appendingPathComponent(slot).appendingPathExtension("plist")
    }
}
