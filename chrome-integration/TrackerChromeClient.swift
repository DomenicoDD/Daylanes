import Darwin
import Foundation
import os

enum TrackerChromeClient {
    static func activeTab() async -> TrackerChromeWire.Reply? {
        guard let directory = TrackerChromeWire.directory(create: false) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: activeTab(in: directory))
            }
        }
    }

    static func activeTab(in directory: URL) -> TrackerChromeWire.Reply? {
        guard let endpoints = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let sockets = Array(endpoints.filter(isEndpoint).sorted().prefix(16))
        let group = DispatchGroup()
        let matches = OSAllocatedUnfairLock(initialState: [TrackerChromeWire.Reply]())
        for name in sockets {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                let endpoint = directory.appendingPathComponent(name)
                if let reply = sample(endpoint), reply.status == .tab {
                    matches.withLock { $0.append(reply) }
                }
            }
        }
        group.wait()
        // Two profiles can each report a focused window if the user switches mid-sample.
        return matches.withLock { $0.count == 1 ? $0.first : nil }
    }

    /// True when Chrome has the extension running and connected to the helper in at least one profile.
    static func helperRunning() -> Bool {
        guard let directory = TrackerChromeWire.directory(create: false),
              let endpoints = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return endpoints.contains(where: isEndpoint)
    }

    private static func isEndpoint(_ name: String) -> Bool {
        guard name.range(of: "^s-[0-9]+-[A-F0-9]{8}$", options: .regularExpression) != nil,
              let pid = name.split(separator: "-").dropFirst().first.flatMap({ Int32($0) }) else { return false }
        return kill(pid, 0) == 0
    }

    private static func sample(_ endpoint: URL) -> TrackerChromeWire.Reply? {
        var info = stat()
        guard lstat(endpoint.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o777 == 0o600,
              var address = TrackerChromeWire.socketPath(endpoint) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        TrackerChromeWire.suppressBrokenPipe(descriptor)
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return nil }

        // Leave time for the helper to relay the validated reply after Chrome answers.
        let deadline = TrackerChromeWire.now() + 0.90
        let connected = TrackerChromeWire.withAddress(&address) { connect(descriptor, $0, $1) }
        if connected != 0 {
            guard errno == EINPROGRESS,
                  TrackerChromeWire.ready(descriptor, for: Int16(POLLOUT), by: deadline) else { return nil }
        }

        let request = TrackerChromeWire.Request()
        guard TrackerChromeWire.localPeer(descriptor),
              TrackerChromeWire.write(request, to: descriptor, by: deadline),
              let reply = TrackerChromeWire.read(TrackerChromeWire.Reply.self, from: descriptor, by: deadline),
              reply.valid(for: request) else { return nil }
        return reply
    }
}
