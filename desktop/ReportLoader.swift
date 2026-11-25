import Foundation

extension Ledger {
    /// Runs the engine's `report-rows` command for a period ("yyyy-MM-dd", end exclusive), optionally limited
    /// to one client and to some of its projects (an empty list means all of them).
    static func reportRows(start: String, endExclusive: String, client: String?, projects: [String]) async throws -> ReportData {
        var arguments = ["report-rows", "--start", start, "--end", endExclusive]
        if let client {
            arguments.append("--client=\(client)")
        }
        for project in projects {
            arguments.append("--project=\(project)")
        }
        let data = try await run(arguments)
        return try ReportData.decode(data)
    }
}
