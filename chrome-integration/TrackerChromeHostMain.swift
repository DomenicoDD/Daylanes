import Darwin
import Foundation

@main
enum TrackerChromeHostMain {
    static func main() {
        let arguments = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Chromium browsers pass the calling extension's origin as the first argument.
        guard arguments.count >= 2, TrackerChromeHost.registered(arguments[1], home: home),
              let directory = TrackerChromeWire.directory(create: true) else { exit(EXIT_FAILURE) }
        _ = signal(SIGPIPE, SIG_IGN)
        TrackerChromeHost.serve(in: directory) {
            TrackerChromeHost.registered(arguments[1], home: home)
        }
    }
}
