import Darwin
import Foundation

@main
enum BridgeHarness {
    static func main() {
        let args = CommandLine.arguments
        let location = URL(fileURLWithPath: args[2], isDirectory: args[1] != "allows")
        switch args[1] {
        case "host":
            _ = signal(SIGPIPE, SIG_IGN)
            TrackerChromeHost.serve(in: location) { args[3] == "allow" }
        case "allows":
            exit(TrackerChromeHost.manifestAllows(args[3], path: location) ? 0 : 1)
        case "sample":
            if let result = TrackerChromeClient.activeTab(in: location),
               let data = try? JSONEncoder().encode(result) {
                FileHandle.standardOutput.write(data)
            }
        default:
            exit(2)
        }
    }
}
