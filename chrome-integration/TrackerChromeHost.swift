import Darwin
import Foundation

enum TrackerChromeHost {
    private struct Manifest: Decodable {
        let allowed_origins: [String]
    }

    static func manifestAllows(_ origin: String, path: URL) -> Bool {
        guard let data = try? Data(contentsOf: path), data.count <= TrackerChromeWire.maxFrame,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              (1...4).contains(manifest.allowed_origins.count),
              manifest.allowed_origins.allSatisfy({
                  $0.range(of: "\\Achrome-extension://[a-p]{32}/\\z", options: .regularExpression) != nil
              }) else {
            return false
        }
        return manifest.allowed_origins.contains { origin == $0 || origin + "/" == $0 }
    }

    /// True when any browser's registration still allows the extension that launched this helper.
    static func registered(_ origin: String, home: URL) -> Bool {
        TrackerChromeWire.browsers.contains {
            manifestAllows(origin, path: TrackerChromeWire.manifest(for: $0, home: home))
        }
    }

    static func serve(in directory: URL, authorized: () -> Bool) {
        let identifier = UUID().uuidString.prefix(8)
        let endpoint = directory.appendingPathComponent("s-\(getpid())-\(identifier)")
        guard var address = TrackerChromeWire.socketPath(endpoint) else { return }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { return }
        defer { close(server) }

        let bound = TrackerChromeWire.withAddress(&address) { bind(server, $0, $1) }
        guard bound == 0 else { return }
        defer { unlink(endpoint.path) }
        guard chmod(endpoint.path, 0o600) == 0, listen(server, 4) == 0 else { return }

        var watched = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: server, events: Int16(POLLIN), revents: 0)]
        while true {
            let count = poll(&watched, nfds_t(watched.count), -1)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            let input = watched[0].revents
            if input & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
            if input & Int16(POLLIN) != 0 {
                // A reply to an expired request can reach the pipe after its local client has left.
                guard TrackerChromeWire.read(TrackerChromeWire.Reply.self, from: STDIN_FILENO,
                                             by: TrackerChromeWire.now() + 0.05) != nil else { return }
            }
            if watched[1].revents & Int16(POLLIN) != 0 {
                guard authorized() else { return }
                handleClient(of: server)
            }
        }
    }

    private static func handleClient(of server: Int32) {
        let client = accept(server, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        guard TrackerChromeWire.localPeer(client) else { return }
        // Chrome verifies the active window and tab through several asynchronous API calls.
        let deadline = TrackerChromeWire.now() + 0.75
        guard let request = TrackerChromeWire.read(TrackerChromeWire.Request.self, from: client, by: deadline),
              request.valid,
              TrackerChromeWire.write(request, to: STDOUT_FILENO, by: deadline) else { return }
        while let reply = TrackerChromeWire.read(TrackerChromeWire.Reply.self, from: STDIN_FILENO, by: deadline) {
            guard reply.valid(for: request) else { continue }
            _ = TrackerChromeWire.write(reply, to: client, by: deadline)
            return
        }
    }
}
