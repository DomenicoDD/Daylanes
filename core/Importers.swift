import Foundation

/// One thing an importer found in a log.
enum ImportItem {
    /// An entry to insert or refresh. `inherit` names an entry an earlier version wrote whose project it takes over.
    case entry([String: SQLValue], inherit: String? = nil)
    /// An entry an earlier version wrote that this log no longer produces.
    case remove(String)
    /// A tool's newest plan-limit snapshot (Codex's 5-hour and weekly windows).
    case limits(provider: String, JSON)

    var id: String? {
        switch self {
        case let .entry(fields, _): fields["id"]?.string
        case let .remove(id): id
        case .limits: nil
        }
    }
}

/// Counters a sync reports, in the Python engine's shape.
final class ImportStats {
    var filesRead = 0, filesUnchanged = 0, filesDeferred = 0, filesOutsideWindow = 0
    var ignoredLines = 0, eventsProcessed = 0
    var directories: [(String, [String])] = []
    var sourceErrors: [String] = []

    var json: JSON {
        .object([
            ("files_read", .int(Int64(filesRead))), ("files_unchanged", .int(Int64(filesUnchanged))),
            ("files_deferred", .int(Int64(filesDeferred))), ("files_outside_window", .int(Int64(filesOutsideWindow))),
            ("ignored_lines", .int(Int64(ignoredLines))), ("events_processed", .int(Int64(eventsProcessed))),
            ("directories", .object(directories.map { ($0.0, .strings($0.1)) })), ("source_errors", .strings(sourceErrors)),
        ])
    }

    func setDirectories(_ name: String, _ paths: [String]) {
        if let index = directories.firstIndex(where: { $0.0 == name }) { directories[index].1 = paths } else { directories.append((name, paths)) }
    }
}

/// A log that can't be read yet: compressed without a decoder, or still being written.
struct UnreadableSource: Error, CustomStringConvertible {
    let description: String
}

/// Helpers that read loosely typed log records the way the Python importers do.
enum Log {
    static func obj(_ value: JSON) -> JSON { value.pairs != nil ? value : .object([]) }

    /// A nonblank string, unchanged (Python's `importers.string`).
    static func text(_ value: JSON) -> String? {
        guard let text = value.stringValue, !text.pythonStripped.isEmpty else { return nil }
        return text
    }

    /// A whole token count between 0 and 10**12, else 0 (Python's `importers.number`).
    static func number(_ value: JSON) -> Int {
        if case let .int(count) = value, count >= 0, count <= 1_000_000_000_000 { return Int(count) }
        return 0
    }

    /// Python truthiness.
    static func truthy(_ value: JSON) -> Bool {
        switch value {
        case .null: false
        case let .bool(flag): flag
        case let .int(number): number != 0
        case let .double(number): number != 0
        case let .string(text): !text.isEmpty
        case let .array(items): !items.isEmpty
        case let .object(pairs): !pairs.isEmpty
        }
    }

    private static var folderCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// An absolute folder with symlinks resolved; nil for a relative or missing one.
    static func canonicalFolder(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/") else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = folderCache[value] { return cached }
        let resolved = Values.resolvedPath(value)
        if folderCache.count > 2048 { folderCache.removeAll() }
        folderCache[value] = resolved
        return resolved
    }

    static func metadata(_ provider: String, session: String?, folder: String?, branch: String?) -> [String: SQLValue] {
        ["provider": .text(provider), "session": session.map(SQLValue.text) ?? .null,
         "folder": canonicalFolder(folder).map(SQLValue.text) ?? .null, "branch": branch.map(SQLValue.text) ?? .null,
         "task": Store.taskFromBranch(branch).map(SQLValue.text) ?? .null]
    }

    static let tokenFields = ["input", "cached", "cache_write", "output"]

    /// (input, cache reads, cache writes, output); for Codex and others the cached part is inside input.
    static func normalizedUsage(_ raw: JSON, provider: String) -> [Int] {
        let counts = number(raw["input_tokens"])
        let output = number(raw["output_tokens"])
        if provider == "claude" {
            return [counts, number(raw["cache_read_input_tokens"]), number(raw["cache_creation_input_tokens"]), output]
        }
        let cached = min(counts, number(raw["cached_input_tokens"]))
        let writes = min(counts - cached, number(raw["cache_write_input_tokens"]))
        return [counts - cached - writes, cached, writes, output]
    }

    static func tokens(_ counts: [Int]) -> [String: SQLValue] {
        Dictionary(uniqueKeysWithValues: zip(tokenFields, counts.map { SQLValue.integer(Int64($0)) }))
    }

    static func merged(_ parts: [String: SQLValue]...) -> [String: SQLValue] {
        parts.reduce(into: [:]) { result, part in result.merge(part) { _, new in new } }
    }

    // MARK: Reading files

    /// The decoder for Codex's compressed logs: TRACKER_UNZSTD, the bundled TrackerUnzstd, or `zstd`.
    static func zstdDecoder() -> [String]? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["TRACKER_UNZSTD"], !configured.isEmpty { candidates.append(configured) }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("TrackerUnzstd").path)
        }
        for folder in (environment["PATH"] ?? "").split(separator: ":") { candidates.append(String(folder) + "/zstd") }
        for helper in candidates where FileManager.default.isExecutableFile(atPath: helper) {
            return (helper as NSString).lastPathComponent == "zstd" ? [helper, "-dcq"] : [helper]
        }
        return nil
    }

    /// A file's bytes split into lines that keep their "\n", decompressing .zst logs.
    static func lines(_ path: String) throws -> [Data] {
        let data = try contents(path)
        // memchr over the raw bytes: Data's generic firstIndex(of:) checks its storage on every byte.
        var result: [Data] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let end = lineEnd(base, offset, buffer.count)
                result.append(Data(bytes: base + offset, count: end - offset))
                offset = end
            }
        }
        return result
    }

    /// The offset just past the next "\n" at or after `offset`, or the end.
    static func lineEnd(_ base: UnsafeRawPointer, _ offset: Int, _ count: Int) -> Int {
        guard let found = memchr(base + offset, 0x0A, count - offset) else { return count }
        return base.distance(to: UnsafeRawPointer(found)) + 1
    }

    /// Runs a decoder and returns its output, exit status and error text. posix_spawn and waitpid rather
    /// than Process: waitUntilExit spins the run loop and notices the exit about 70 ms late, per file.
    static func run(_ arguments: [String], name: String) throws -> (Data, Int32, Data) {
        var output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw UnreadableSource(description: "\(name): \(String(cString: strerror(errno)))") }
        guard pipe(&errors) == 0 else {
            close(output[0]); close(output[1])
            throw UnreadableSource(description: "\(name): \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        for fd in output + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, nil, &argv, environ)
        close(output[1]); close(errors[1])
        guard spawned == 0 else {
            close(output[0]); close(errors[0])
            throw UnreadableSource(description: "\(name): \(String(cString: strerror(spawned)))")
        }
        func drain(_ fd: Int32) -> Data {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let count = read(fd, &chunk, chunk.count)
                if count > 0 { data.append(chunk, count: count); continue }
                if count < 0, errno == EINTR { continue }
                break
            }
            close(fd)
            return data
        }
        var stderr = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { stderr = drain(errors[0]); group.leave() }
        let decoded = drain(output[0])
        group.wait()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        // WIFEXITED / WEXITSTATUS; a signal counts as failure.
        let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return (decoded, code, stderr)
    }

    /// A file's bytes, decompressing .zst logs.
    static func contents(_ path: String) throws -> Data {
        let name = (path as NSString).lastPathComponent
        let data: Data
        if name.hasSuffix(".zst") || name.hasSuffix(".zstd") {
            guard let decoder = zstdDecoder() else {
                throw UnreadableSource(description: "No zstd decoder: build the app with bin/build-desktop or install zstd")
            }
            let (decoded, status, stderr) = try run(decoder + [path], name: name)
            if status != 0, decoded.isEmpty {
                let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw UnreadableSource(description: "\(name): \(message.isEmpty ? "decoding failed" : message)")
            }
            // A log still being written can end inside a frame: the complete records before it count.
            data = decoded
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return data
    }

    /// The JSON objects in a JSON Lines file; lines that aren't JSON count as ignored once complete.
    /// Read one at a time, like Python's generator: a Codex log can decode to most of a gigabyte, and
    /// keeping every parsed record of it alive at once costs many times that.
    static func records(_ path: String, _ stats: ImportStats) throws -> Records {
        Records(data: try contents(path), stats: stats)
    }

    struct Records: Sequence {
        let data: Data
        let stats: ImportStats

        func makeIterator() -> Iterator { Iterator(data: data, stats: stats) }

        struct Iterator: IteratorProtocol {
            let data: Data
            let stats: ImportStats
            var offset = 0

            mutating func next() -> JSON? {
                while offset < data.count {
                    let (row, complete) = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> (JSON?, Bool) in
                        let base = buffer.baseAddress!
                        let end = Log.lineEnd(base, offset, buffer.count)
                        let line = [UInt8](UnsafeRawBufferPointer(rebasing: buffer[offset..<end]))
                        offset = end
                        return (try? JSON.parse(bytes: line), line.last == 0x0A)
                    }
                    guard let row else {
                        if complete { stats.ignoredLines += 1 }
                        continue
                    }
                    if row.pairs != nil { return row }
                }
                return nil
            }
        }
    }

    /// File name without ".zst" and ".jsonl" (the session id Codex and Claude Code use).
    static func transcriptID(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".zst") { name.removeLast(4) }
        if name.hasSuffix(".jsonl") { name.removeLast(6) }
        return name
    }

    /// Python's ordering of `Path` objects: component by component.
    static func pathLess(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: "/"), right = b.split(separator: "/")
        for (x, y) in zip(left, right) where x != y { return pyLess(String(x), String(y)) }
        return left.count < right.count
    }

    /// Python's string order (by code point), not Swift's Unicode collation.
    static func pyLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    /// Every file under `directory` whose name matches one of the suffix patterns, not following
    /// symlinked folders (Python's `Path.rglob`).
    static func walk(_ directory: String, matching match: (String) -> Bool) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
        var found: [String] = []
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if match(name) { found.append(directory + "/" + relative) }
        }
        return found
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    static func isDirectory(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Every transcript once. Codex compresses older logs (.jsonl.zst); when both copies exist the plain
    /// one is newer, and a log in sessions/ wins over its copy in archived_sessions/.
    static func transcriptFiles(_ directories: [String]) -> [String] {
        var chosen: [(String, String)] = []
        var keys = Set<String>()
        for directory in directories where isDirectory(directory) {
            let found = walk(directory) { name in name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") }
            let ordered = found.sorted { a, b in
                let za = a.hasSuffix(".zst"), zb = b.hasSuffix(".zst")
                return za != zb ? !za : pyLess(a, b)
            }
            let parent = (directory as NSString).deletingLastPathComponent
            for path in ordered where isRegularFile(path) {
                let relative = String(path.dropFirst(directory.count + 1))
                let key = parent + "\u{0}" + ((relative as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent(transcriptID(path))
                if keys.insert(key).inserted { chosen.append((key, path)) }
            }
        }
        return chosen.map(\.1).sorted(by: pathLess)
    }

    // MARK: Signatures

    static func signature(_ path: String) throws -> String {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { throw CocoaError(.fileNoSuchFile) }
            if code == EACCES || code == EPERM { throw CocoaError(.fileReadNoPermission) }
            throw CocoaError(.fileReadUnknown)
        }
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return "\(info.st_size):\(nanos):\(info.st_ino)"
    }

    static func modified(_ path: String) throws -> Double {
        var info = stat()
        guard stat(path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) * 1e-9
    }
}

/// A tool that keeps its history in files: where they are and how to read one.
struct FileSource {
    let name: String
    let directories: [String]
    let read: (_ path: String, _ stats: ImportStats) throws -> [ImportItem]
    var files: (() -> [String])?
    /// The history is an SQLite database, whose committed changes can sit in its -wal file.
    var database = false

    func list() -> [String] { files?() ?? Log.transcriptFiles(directories) }

    func signature(_ path: String) throws -> String {
        var stamp = try Log.signature(path)
        if database, Log.exists(path + "-wal") { stamp += "+" + (try Log.signature(path + "-wal")) }
        return stamp
    }
}
