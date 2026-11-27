import Foundation

// Checks for the Swift engine (core/). Build and run on macOS:
//   d="$(mktemp -d)"; xcrun swiftc -parse-as-library core/*.swift tests/CoreChecks.swift -o "$d/check" && "$d/check"

@main
struct CoreChecks {
    static var failures = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) rethrows {
        if try !condition() {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    static func expectError(_ message: String, line: Int = #line, _ body: () throws -> Void) {
        do {
            try body()
            failures += 1
            print("FAIL line \(line): expected an error containing \"\(message)\"")
        } catch {
            if !error.localizedDescription.contains(message) {
                failures += 1
                print("FAIL line \(line): got \"\(error.localizedDescription)\", expected \"\(message)\"")
            }
        }
    }

    static func main() throws {
        jsonText()
        decimals()
        pythonDecimals()
        days()
        timestamps()
        rules()
        try chromeProfiles()
        try chromeProfileClients()
        try slackWorkspaceClients()
        try trackingRuleSaves()
        try timelineTime()
        try ledger()
        try harnessHelpers()
        try network()
        try providerUsage()
        try paths()
        if failures > 0 {
            print("\(failures) core check(s) failed")
            exit(1)
        }
        print("Core checks passed")
    }

    static func providerUsage() throws {
        let now = Int(ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!.timeIntervalSince1970 * 1000)
        func reply(_ text: String) throws -> JSON {
            try JSON.parse(bytes: Array(text.utf8), decimalFloats: true)
        }
        let fal = try ProviderUsageAPI(.fal, credential: "key:secret", now: now) { url, headers in
            check(headers["Authorization"] == "Key key:secret", "fal's billing authorization")
            if url.contains("/v1/keys") {
                return try reply(#"{"keys":[{"key_id":"project-key","alias":"Website"}],"has_more":false,"next_cursor":null}"#)
            }
            check(url.contains("expand=auth_method_structured"), "fal asks for key IDs")
            if url.contains("cursor=next-page") {
                return try reply(#"{"time_series":[{"bucket":"2026-11-20T00:00:00Z","results":[{"endpoint_id":"fal-ai/test","quantity":3,"unit":"image","cost_total":0.012,"currency":"USD"}]}],"has_more":false,"next_cursor":null}"#)
            }
            return try reply(#"{"time_series":[{"bucket":"2026-11-20T00:00:00Z","results":[{"endpoint_id":"fal-ai/test","quantity":2,"unit":"image","cost_total":0.004,"currency":"USD","auth_method_structured":{"api_key_id":"project-key"}}]}],"has_more":true,"next_cursor":"next-page"}"#)
        }.fetch()
        let db = try Database(path: ":memory:")
        try db.script(Schema.tables)
        try Store.createProject(db, name: "Website", client: "Example", kind: "billable", folder: nil)
        try Store.createProject(db, name: "Other", client: "Different", kind: "billable", folder: nil)
        try ProviderUsage.replace(db, provider: .fal, cache: fal)
        try ProviderUsage.assign(db, provider: .fal, keyID: "project-key", project: "Website", alias: nil)
        let start = "2026-11-01", end = "2026-11-23"
        let global = try ProviderUsage.report(db, start: start, end: end)!.arrayValue!.first!
        check(global["totals"]["spend"]["USD"].doubleValue == 0.016, "fal totals combine paginated net costs")
        check(global["unassigned"]["spend"]["USD"].doubleValue == 0.012, "unkeyed usage remains unassigned")
        let client = try Reports.report(db, start: start, end: end, period: "month", project: nil, client: "Example", task: nil)
        let assigned = client["provider_usage"].arrayValue?.first
        check(assigned?["totals"]["spend"]["USD"].doubleValue == 0.004, "client report contains its project's key spend only")
        let snapshot = try Desktop.snapshot(db, start: start, end: end, period: "month")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let accounts = try decoder.decode([ProviderUsage.Account].self, from: Data(snapshot["provider_usage"].pythonText().utf8))
        check(accounts.first?.keys.first?.project == "Website" && accounts.first?.keys.first?.name == "Website",
              "desktop snapshot decodes the discovered key name and saved project")
        check(accounts.first?.totals.quantities["image"] == 5, "desktop snapshot keeps unlike billing units distinct")
        try ProviderUsage.assign(db, provider: .fal, keyID: "project-key", project: "Other", alias: nil)
        try check(ProviderUsage.report(db, start: start, end: end, project: "Website") == nil, "reassignments apply to cached usage")
        let outOfRange = try ProviderUsage.report(db, start: "2026-01-01", end: "2026-02-01")!.arrayValue!.first!
        check(outOfRange["from"].isNull && outOfRange["totals"]["spend"].pairs?.isEmpty == true,
              "uncached dates have no spend coverage")
        try ProviderUsage.clear(db, provider: .fal)
        try check(ProviderUsage.cached(db, .fal) == nil && ProviderUsage.routes(db, .fal).isEmpty, "disconnect clears cache and routes")

        let higgs = try ProviderUsageAPI(.higgsfield, credential: "key:secret", now: now) { url, _ in
            check(url.hasPrefix("https://api.higgsfield.ai/models/usage?") && url.contains("expand=auth_method"),
                  "Higgsfield requests account usage by API key")
            return try reply(#"{"time_series":[{"bucket":"2026-11-20T00:00:00Z","results":[{"model":"soul","unit":"generation","quantity":"2","cost":"0.1880","currency":"USD","auth_method":"3f0c8a2e-5b7d-4e19-9a61-2c4d8e7f1a90"}]}],"total":1,"page":1,"limit":100}"#)
        }.fetch()
        check(higgs.keys.first?.id == "3f0c8a2e-5b7d-4e19-9a61-2c4d8e7f1a90", "Higgsfield discovers IDs from usage")
        check(higgs.records[0].metrics.quantities["generation"] == 2, "Higgsfield reports successful generation quantities")

        let replicate = try ProviderUsageAPI(.replicate, credential: "prediction-token", now: now) { url, _ in
            check(url == "https://api.replicate.com/v1/predictions", "Replicate's read endpoint")
            return try reply(#"{"next":null,"results":[{"id":"a","model":"owner/model","created_at":"2026-11-20T17:23:00Z","metrics":{"predict_time":0.75},"input":{"prompt":"private"}}]}"#)
        }.fetch()
        check(replicate.records[0].metrics.quantities["Processing seconds"] == Decimal(string: "0.75") &&
              replicate.records[0].keyID == nil && replicate.records[0].metrics.spend.isEmpty,
              "Replicate prediction metadata stays account-wide and unpriced")
        expectError("unreadable usage response") {
            _ = try ProviderUsageAPI(.replicate, credential: "prediction-token", now: now) { url, _ in
                check(url == "https://api.replicate.com/v1/predictions", "Replicate never follows a cross-host cursor")
                return try reply(#"{"next":"https://example.com/v1/predictions?cursor=leak","results":[]}"#)
            }.fetch()
        }

        let ollama = try ProviderUsageAPI(.ollama, credential: "ollama-key", now: now) { url, _ in
            if url.hasSuffix("/api/balance") {
                return try reply(#"{"included":{"balance_usd":72.5},"purchased":{"balance_usd":25}}"#)
            }
            return try reply(#"{"granularity":"day","scope":"self","from":"2026-10-23T00:00:00Z","until":"2026-11-22T12:00:00Z","buckets":[{"from":"2026-11-20T00:00:00Z","groups":[{"model":"model","request_count":2,"usage_usd":0.012,"input_tokens":40,"cached_input_tokens":35,"output_tokens":20}],"remainder":{"request_count":1}},{"from":"2026-11-22T00:00:00Z","partial":true,"request_count":5}]}"#)
        }.fetch()
        check(ollama.records.count == 2 && ollama.records[0].metrics.quantities["Tokens"] == 60,
              "Ollama excludes partial days and counts cached tokens once")
        check(ollama.records[1].metrics.hasUnpricedUsage && ollama.balance?["Purchased credits"] == 25,
              "Ollama preserves unpriced usage and available credits")

        let hash = String(repeating: "a", count: 64)
        let openrouter = try ProviderUsageAPI(.openrouter, credential: "management-key", now: now) { url, _ in
            if url.contains("/keys?") {
                return try reply(url.contains("offset=0") ? #"{"data":[{"hash":"\#(hash)","name":"Project"}]}"# : #"{"data":[]}"#)
            }
            check(URLComponents(string: url)?.queryItems == [URLQueryItem(name: "api_key_hash", value: hash)],
                  "OpenRouter filters usage to the selected key hash")
            return try reply(#"{"data":[{"date":"2026-11-21T00:30:00.000+01:00","model":null,"model_permaslug":"provider/model","usage":0.002,"requests":"1","prompt_tokens":5.0,"completion_tokens":3}]}"#)
        }.fetch(mappedKeys: [hash])
        let routed = openrouter.records.first
        check(routed?.keyID == hash && routed?.day == "2026-11-20" && routed?.model == "provider/model" &&
              routed?.metrics.quantities["Tokens"] == 8 && routed?.metrics.spend["USD"] == Decimal(string: "0.002"),
              "OpenRouter assigns filtered activity with exact counts, a UTC timestamp and a model permaslug")
        expectError("row 1, requests") {
            let bad = try reply(#"{"date":"2026-11-20","model":"model","usage":0.01,"requests":1.0000000000000000000000000001,"prompt_tokens":5,"completion_tokens":3}"#)
            _ = try OpenRouterActivity.decodeRows([bad], start: start, end: end)
        }
    }

    static func jsonText() {
        let value = JSON.object([
            ("name", .string("Café \"A\"\n\u{01}")), ("list", .array([.int(1), .double(1.5), .null, .bool(true)])),
            ("empty", .array([])), ("nothing", .object([])),
        ])
        let expected = """
        {
          "name": "Café \\"A\\"\\n\\u0001",
          "list": [
            1,
            1.5,
            null,
            true
          ],
          "empty": [],
          "nothing": {}
        }
        """
        check(value.pythonText() == expected, "pretty JSON matches Python:\n\(value.pythonText())")
        let parsed = try? JSON.parse(#"{"b": 1, "a": [2, "xé"], "c": {"d": null}, "e": 2.5e3}"#)
        check(parsed?.pairs?.map(\.0) == ["b", "a", "c", "e"], "parsing keeps key order")
        check(parsed?["a"].arrayValue?[1].stringValue == "xé", "parsing decodes \\u escapes")
        check(parsed?["e"].doubleValue == 2500, "parsing reads exponents")
        check(JSON.pythonFloat(2) == "2.0" && JSON.pythonFloat(0.1) == "0.1", "floats print like Python")
    }

    static func decimals() {
        check((try? Values.cents("12.5")) == 1250, "12.5 is 1250 cents")
        check((try? Values.cents(" 3 ")) == 300, "amounts may have spaces")
        check((try? Values.cents("1e2")) == 10000, "exponents are accepted")
        expectError("at most two decimal places") { _ = try Values.cents("1.005") }
        expectError("nonnegative") { _ = try Values.cents("-1") }
        expectError("nonnegative") { _ = try Values.cents("12abc") }
        check(Values.money(1250) == "12.50" && Values.money(-75) == "-0.75" && Values.money(0) == "0.00", "money formats")
        check(Values.hours(5_400_000) == "1.5000" && Values.hours(180) == "0.0000" && Values.hours(540) == "0.0002",
              "hours round half to even")
        check((try? Values.durationMillis("1.5")) == 90_000, "minutes become milliseconds")
        expectError("between one millisecond") { _ = try Values.durationMillis("0") }
        expectError("between one millisecond") { _ = try Values.durationMillis("1441") }
    }

    /// PyDecimal against values printed by CPython's decimal module (default context).
    static func pythonDecimals() {
        func d(_ text: String) -> PyDecimal { PyDecimal(text)! }
        check(d("0.0000001").description == "1E-7", "small values use exponents like str()")
        check(d("1.50").description == "1.50" && d("1E+2").description == "1E+2", "trailing zeros and exponents stay")
        check(d("1E+2").plain == "100" && d("0E-8").plain == "0.00000000", "format 'f' writes them out")
        check((d("1") / d("3")).description == "0.3333333333333333333333333333", "division keeps 28 digits")
        check((d("2") / d("3")).fixedText(2) == "0.67" && d("0.125").fixedText(2) == "0.12" && d("0.135").fixedText(2) == "0.14",
              "'.2f' rounds half to even")
        check((PyDecimal(5_400_000) / PyDecimal(3_600_000)).description == "1.5", "exact quotients use the ideal exponent")
        check((d("100") / d("4")).description == "25" && (d("1.00") / d("4")).description == "0.25", "exact division")
        check(d("2.5").roundedHalfUp == 3 && d("-2.5").roundedHalfUp == -3 && d("2.4999").roundedHalfUp == 2, "ROUND_HALF_UP")
        check(d("1.500").normalized().description == "1.5" && d("100").normalized().description == "1E+2"
              && d("0.000").normalized().description == "0", "normalize strips zeros")
        check(d("12.3456789").quantized(-6).description == "12.345679", "quantize rounds half to even")
        check((d("0.1") + d("0.2")).description == "0.3" && (d("1.10") - d("1.1")).description == "0.00", "sums keep exponents")
        check((PyDecimal(0) + d("1.25")).description == "1.25" && (d("-0") + d("-0")).description == "-0", "zero signs")
        check((d("1.5") * d("2")).description == "3.0" && (PyDecimal(120000) * d("0.00000125")).description == "0.15000000",
              "products add exponents")
        check((d("9999999999999999999999999999") + d("1")).description == "1.000000000000000000000000000E+28",
              "sums round to 28 digits")
        check(d("-1.005").fixedText(2) == "-1.00" && d("-0.001").quantized(-2).plain == "-0.00", "negative rounding")
        check(PyDecimal("1_000") == d("1000") && PyDecimal("abc") == nil && PyDecimal("NaN") == nil, "parsing")
        check(PyDecimal(exactly: 0.1)?.description == "0.1000000000000000055511151231257827021181583404541015625",
              "floats convert exactly")
        check(PyDecimal.money(1250) == "12.50" && PyDecimal.hours(540) == "0.0002", "money and hours")
    }

    static func days() {
        let rome = TimeZone(identifier: "Europe/Rome")!, angeles = TimeZone(identifier: "America/Los_Angeles")!
        check(Day(year: 2026, month: 11, day: 20).weekday == 4, "2026-11-20 is a Friday")
        check(Day(year: 2024, month: 2, day: 28).adding(days: 1).iso == "2024-02-29", "leap days")
        check(Day(ordinal: Day(year: 1, month: 1, day: 1).ordinal).iso == "0001-01-01", "ordinals round-trip")
        check(Day(year: 2026, month: 10, day: 26).midnight(rome) - Day(year: 2026, month: 10, day: 25).midnight(rome)
              == 25 * 3_600_000, "the day DST ends has 25 hours")
        check(Day.local(1_793_606_400_000, angeles).iso == "2026-11-02" && Day.local(1_793_606_400_000 - 9 * 3_600_000, angeles).iso == "2026-11-01", "local days follow the zone")
        check(Day.month(1_793_606_400_000, rome) == "2026-11", "months follow the zone")
        expectError("Invalid isoformat string: 'soon'") { _ = try Day.parse("soon") }
        expectError("day is out of range for month") { _ = try Day.parse("2026-02-30") }
        check(Reports.grouped(1234567) == "1,234,567" && Reports.grouped(12) == "12", "thousands separators")
        check(Desktop.spreadsheetText("=SUM(A1)") == "'=SUM(A1)" && Desktop.spreadsheetText(" -1") == "' -1"
              && Desktop.spreadsheetText("ok") == "ok", "spreadsheet formulas are quoted")
        check(Desktop.csvRow(["a,b", "say \"hi\"", "x"]) == "\"a,b\",\"say \"\"hi\"\"\",x\r\n", "CSV quoting")
    }

    static func timestamps() {
        let rome = TimeZone(identifier: "Europe/Rome")!
        check(Values.parseAt("2026-11-20", zone: rome) == 1_795_129_200_000, "a date is local midnight")
        check(Values.parseAt("2026-11-20T10:30:00Z", zone: rome) == 1_795_170_600_000, "Z is UTC")
        check(Values.parseAt("2026-11-20T11:30:00+01:00", zone: .gmt) == 1_795_170_600_000, "offsets apply")
        check(Values.parseAt("2026-11-20T10:30:00.250Z", zone: rome) == 1_795_170_600_250, "fractions keep milliseconds")
        check(Values.parseAt("2026-11-20T10:30:00.25Z", zone: rome) == nil, "Python 3.9 needs 3 or 6 fraction digits")
        check(Values.parseAt("2026-02-30", zone: rome) == nil, "impossible dates fail")
        check(Values.parseAt("yesterday", zone: rome) == nil, "words fail")
        check(Store.taskFromBranch("feature/abc-12-login") == "ABC-12", "task keys come from branches")
        check(Store.taskFromBranch("ABC-1-and-DEF-2") == nil, "two keys mean no task")
    }

    static func rules() {
        check((try? Focus.browserRule("domain", "App.Example.com.")) == "app.example.com", "domains are lower case")
        check((try? Focus.browserRule("url", "HTTPS://Example.com:443/a/b/")) == "https://example.com/a/b", "default ports go")
        check((try? Focus.browserRule("url", "http://example.com:8080")) == "http://example.com:8080/", "other ports stay")
        check((try? Focus.browserRule("domain", "café.example")) == "xn--caf-dma.example", "IDNA host names")
        check(IDNA.punycode("bücher") == "bcher-kva", "punycode")
        expectError("Use only the domain") { _ = try Focus.browserRule("domain", "example.com/path") }
        expectError("without credentials") { _ = try Focus.browserRule("domain", "user@example.com") }
        expectError("without credentials") { _ = try Focus.browserRule("domain", "bad_host.com") }
        expectError("https://") { _ = try Focus.browserRule("url", "ftp://example.com") }
        expectError("query strings") { _ = try Focus.browserRule("url", "https://example.com/?q=1") }
        expectError("valid domain") { _ = try Focus.browserRule("url", "https://example.com:99999/") }
        check((try? Focus.canonicalUUID("{1B4E28BA-2FA1-11D2-883F-0016D3CCA427}")) == "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
              "UUIDs are canonical")
        check((try? GitHub.repoName("Acme/Shop.git/")) == "acme/shop", "repository names")
    }

    static func chromeProfiles() throws {
        let fixture = #"""
            {"profile":{"info_cache":{
                "Default":{"name":"Personal","gaia_given_name":"Taylor"},
                "Profile 12":{"name":"Profile 12","enterprise_label":"Example Studio","gaia_given_name":"Taylor",
                              "user_name":"private@example.test"},
                "Profile 13":{"name":"Work","is_ephemeral":true},
                "Guest Profile":{"name":"Guest"}
            }}}
            """#
        let catalog = ChromeProfile.decodeCatalog(Data(fixture.utf8))
        check(catalog.map(\.id) == ["Profile 12", "Default"], "Chrome profiles omit guest and temporary directories")
        check(catalog.first?.object == .object([("id", .string("Profile 12")), ("name", .string("Example Studio"))]),
              "Chrome profile listings use the managed label and expose only the name and ID")
        check(ChromeProfile.identify(windowTitle: "Meet - Google Chrome – Taylor (Example Studio)", in: catalog)?.id == "Profile 12",
              "the active Chrome window's full profile suffix resolves to its stable ID")
        check(ChromeProfile.identify(windowTitle: "Meet - Google Chrome - Example Studio", in: catalog)?.id == "Profile 12",
              "the raw Chrome accessibility separator resolves too")
        check(ChromeProfile.identify(windowTitle: "Meet - Google Chrome – Taylor", in: catalog) == nil,
              "a shared display name leaves the profile unresolved")
        check(ChromeProfile.identify(windowTitle: "Example Studio meeting - Google Chrome", in: catalog) == nil,
              "a web page title alone doesn't identify a profile")
        check(ChromeProfile.identify(windowTitle: "Fake - Google Chrome – Example Studio - Google Chrome", in: catalog) == nil,
              "a Chrome-shaped suffix inside the page title isn't used")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("profile-checks-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("Local State")
        try Data(fixture.utf8).write(to: source)
        check(ChromeProfile.discover(home: home).profiles.isEmpty, "a missing system catalog starts empty")
        try ChromeProfile.importCatalog(from: source, home: home)
        let imported = ChromeProfile.discover(home: home)
        check(imported.requiresImport && imported.profiles == catalog, "imported profiles and matching aliases work without filesystem access to Chrome")
        let onlyProfile = ChromeProfile.Catalog(profiles: [catalog[0]], requiresImport: false)
        let importedProfile = ChromeProfile.Catalog(profiles: [catalog[0]], requiresImport: true)
        check(onlyProfile.profile(forVerifiedWindowTitle: "A page - Google Chrome") == catalog[0],
              "Chrome's unnamed normal window resolves when the live catalog has one profile")
        check(onlyProfile.profile(forVerifiedWindowTitle: "A page - Google Chrome (Guest)") == nil
              && importedProfile.profile(forVerifiedWindowTitle: "A page - Google Chrome") == nil,
              "guest windows and imported single-profile catalogs do not resolve unnamed windows")
        let saved = try String(contentsOf: home.appendingPathComponent("Library/Application Support/Tracker/ChromeProfiles/catalog.json"), encoding: .utf8)
        check(!saved.contains("private@example.test"), "the import does not copy account email addresses")

        try Data("{}".utf8).write(to: source)
        expectError("Choose Chrome’s Local State file") { try ChromeProfile.importCatalog(from: source, home: home) }
        check(ChromeProfile.discover(home: home) == imported, "an invalid import preserves the saved profile list")
    }

    static func chromeProfileClients() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-client-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["TRACKER_DB": folder.appendingPathComponent("ledger.sqlite3").path]

        @discardableResult
        func run(_ args: String...) throws -> JSON {
            guard let data = try CLI.run(args, environment: environment), !data.isEmpty else { return .null }
            return try JSON.parse(data)
        }

        try run("client", "save", "Profile client")
        try run("project", "add", "Website", "--client=Project client", "--kind=billable")
        try run("focus", "chrome-client", "Profile 7", "--client=Profile client")
        try check(run("focus", "config")["chrome_profile_clients"]["Profile 7"] == .string("Profile client"),
                  "a client without any projects can be saved against a stable Chrome profile ID")
        expectError("Unknown client") { try run("focus", "chrome-client", "Default", "--client=Missing") }

        let start = Int64(1_790_000_000_000)
        let ids = (0..<3).map { _ in UUID().uuidString.lowercased() }
        let blocks = ids.enumerated().map { index, id in
            let offset = Int64(index) * 60_000
            return JSON.object([
                ("id", .string(id)), ("app_id", .string("com.google.Chrome")), ("app_name", .string("Google Chrome")),
                ("started_at", .int(start + offset)), ("ended_at", .int(start + offset + 60_000)), ("closed", .bool(true)),
                ("client", .string("Profile client")), ("ignored", .bool(index == 2)),
                ("match", index == 1 ? .object([("project", .string("Website")), ("field", .string("domain")),
                                                ("keyword", .string("example.com"))]) : .null),
            ])
        }
        _ = try CLI.run(["focus", "record"], input: Data(JSON.array(blocks).pythonText().utf8), environment: environment)

        let day = Day.local(Int(start), try Values.zone("UTC")).iso
        let timeline = try run("focus", "timeline", "--day=\(day)", "--with-human-time")
        let rows = Dictionary(uniqueKeysWithValues: timeline["blocks"].arrayValue!.map { ($0["id"].stringValue!, $0) })
        check(rows[ids[0]]?["client"] == .string("Profile client") && rows[ids[0]]?["project"].isNull == true,
              "unmatched Chrome time keeps the client and remains unassigned at project level")
        check(rows[ids[1]]?["client"] == .string("Project client") && rows[ids[1]]?["project"] == .string("Website"),
              "a matching project determines the client even when the Chrome profile maps elsewhere")
        check(rows[ids[2]]?["client"].isNull == true, "ignored time does not expose the profile client")
        check(timeline["logged_human_millis"].intValue == 60_000, "client-only time is outside project totals")

        try run("client", "save", "Renamed client", "--previous=Profile client")
        try check(run("focus", "config")["chrome_profile_clients"]["Profile 7"] == .string("Renamed client"),
                  "renaming a client updates its profile mapping")
        try run("focus", "chrome-client", "Profile 7", "--clear")
        try check(run("focus", "config")["chrome_profile_clients"]["Profile 7"].isNull, "a mapping can be cleared")
        let historical = try run("focus", "timeline", "--day=\(day)")["blocks"].arrayValue!
        check(historical.first { $0["id"] == .string(ids[0]) }?["client"] == .string("Renamed client"),
              "existing time keeps its client when a mapping is cleared")
    }

    static func slackWorkspaceClients() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slack-client-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["TRACKER_DB": folder.appendingPathComponent("ledger.sqlite3").path]

        @discardableResult
        func run(_ args: String...) throws -> JSON {
            guard let data = try CLI.run(args, environment: environment), !data.isEmpty else { return .null }
            return try JSON.parse(data)
        }

        let channelURL = "https://app.slack.com/client/TWORKSPACE/CCHANNEL"
        let browser = SlackTrackingContext.browser(channelURL + "?thread_ts=1.23")!
        let title = "#website (Channel) - Acme - Studio - Slack"
        let desktop = SlackTrackingContext.desktop("(4) " + title)!
        let signedInNames = (1...12).map { "Workspace \($0)" }
        check(SlackWorkspaceMenu.names(beforeSeparator: signedInNames + ["workspace 1", "", "Sign in to Another Workspace…"]) == signedInNames,
              "Slack discovery lists all signed-in names and skips duplicate names and menu actions")
        check(SlackWorkspaceMenu.names(beforeSeparator: ["Sign in to Another Workspace…"]) == nil,
              "an unrecognized Slack menu does not produce workspace names")
        check(browser.channelRule == .website(channelURL), "Slack website rules discard message and thread context")
        check(desktop.channelRule == .windowTitle(title), "Slack desktop rules scope the channel to the workspace and ignore unread counts")
        check(SlackTrackingContext.browser("https://app.slack.com.example.test/client/TWORKSPACE/CCHANNEL") == nil,
              "a non-Slack tab cannot supply Slack workspace context")
        check(SlackTrackingContext.browser("https://app.slack.com/client/TWORKSPACE/DCONVERSATION")?.channelRule == nil
              && SlackTrackingContext.desktop("A person - Acme - Studio - Slack")?.channelRule == nil,
              "Slack DMs supply only workspace context")

        try run("client", "save", "Slack client")
        let config = try run("focus", "slack-client", "--workspace=\(channelURL)", "--desktop-name=Acme - Studio", "--client=Slack client")
        let mappings = try JSONDecoder().decode([SlackWorkspaceClient].self, from: Data(config["slack_workspace_clients"].pythonText().utf8))
        check(mappings.count == 1 && mappings[0].workspaceID == "TWORKSPACE", "a pasted channel URL saves just the workspace ID")
        check(SlackWorkspaceClient.match(browser, in: mappings)?.client == "Slack client"
              && SlackWorkspaceClient.match(desktop, in: mappings)?.client == "Slack client", "browser and desktop share the client mapping")
        expectError("already mapped") {
            try run("focus", "slack-client", "--desktop-name=acme - studio", "--client=Slack client")
        }
        try run("client", "save", "Renamed Slack client", "--previous=Slack client")
        try check(run("focus", "config")["slack_workspace_clients"].arrayValue?.first?["client"] == .string("Renamed Slack client"),
                  "client renames preserve the Slack workspace mapping")
        try run("focus", "slack-client", "--id=\(mappings[0].id)", "--clear")
        try check(run("focus", "config")["slack_workspace_clients"].arrayValue?.isEmpty == true, "Slack mappings can be removed")
    }

    static func trackingRuleSaves() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rule-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("ledger.sqlite3").path
        let environment = ["TRACKER_DB": path]

        @discardableResult
        func run(_ args: String...) throws -> [JSON] {
            let output = try CLI.run(args, environment: environment) ?? Data()
            if output.isEmpty { return [] }
            return try JSON.parse(output)["rules"].arrayValue ?? []
        }

        try run("project", "add", "Tracker", "--kind=internal")
        try run("project", "add", "Other", "--kind=internal")
        do {
            let db = try Schema.open(path)
            try db.execute("DROP TABLE focus_rules")
            try db.script(Schema.focusRules.replacingOccurrences(of: "project TEXT REFERENCES", with: "project TEXT NOT NULL REFERENCES"))
            try db.execute("INSERT INTO focus_rules (id, field, keyword, project) VALUES ('pre-ignore', 'app', 'Preview', 'Tracker')")
        }
        let migrated = try run("focus", "config")
        check(migrated.first?["id"] == .string("pre-ignore") && migrated.first?["project"] == .string("Tracker"),
              "the nullable destination migration keeps existing rules")
        try run("focus", "delete-rule", "pre-ignore")
        let first = try run("focus", "save-rule", "--field=domain", "--keyword=daylanes.app", "--project=Tracker",
                            "--chrome-profile=Work")
        let repeated = try run("focus", "save-rule", "--field=domain", "--keyword=DAYLANES.APP.", "--project=Tracker",
                               "--chrome-profile=work")
        check(first.count == 1 && repeated == first, "saving equivalent browser conditions reuses the original rule")
        expectError("already routes to Tracker") {
            try run("focus", "save-rule", "--field=domain", "--keyword=daylanes.app", "--project=Other",
                    "--chrome-profile=work")
        }
        expectError("already routes to Tracker") {
            try run("focus", "save-rule", "--field=domain", "--keyword=daylanes.app", "--project=Tracker",
                    "--chrome-profile=Work", "--tag=Relaunch")
        }
        let withPath = try run("focus", "save-rule", "--field=url", "--keyword=HTTPS://Daylanes.App:443/help/",
                               "--project=Other", "--chrome-profile=Work")
        let withSecondProfile = try run("focus", "save-rule", "--field=domain", "--keyword=daylanes.app",
                                        "--project=Other", "--chrome-profile=Personal")
        check(withPath.count == 2 && withSecondProfile.count == 3, "a narrower URL and a different profile can keep their own routes")
        let personalID = withSecondProfile.first { $0["chrome_profile"] == .string("Personal") }!["id"].stringValue!
        expectError("identical rule already exists") {
            try run("focus", "save-rule", "--id=\(personalID)", "--field=domain", "--keyword=daylanes.app",
                    "--project=Tracker", "--chrome-profile=Work")
        }
        let scoped = try run("focus", "save-rule", "--field=domain", "--keyword=meet.google.com",
                             "--project=Tracker", "--chrome-profile-id=Profile 12")
        let meet = scoped.first { $0["keyword"] == .string("meet.google.com") }
        check(meet?["chrome_profile_id"] == .string("Profile 12") && meet?["chrome_profile"].isNull == true,
              "the CLI stores a profile directory separately from manual labels")
        expectError("already routes to Tracker") {
            try run("focus", "save-rule", "--field=domain", "--keyword=meet.google.com",
                    "--project=Other", "--chrome-profile-id=Profile 12")
        }
        expectError("Choose an ID") {
            try run("focus", "save-rule", "--field=domain", "--keyword=meet.google.com",
                    "--project=Other", "--chrome-profile-id=../Example Studio")
        }
        let originalID = first[0]["id"].stringValue!
        let edited = try run("focus", "save-rule", "--id=\(originalID)", "--field=domain", "--keyword=daylanes.app",
                             "--project=Tracker", "--chrome-profile=Work", "--tag=Review")
        check(edited.first { $0["id"] == .string(originalID) }?["tag"] == .string("Review"),
              "editing a rule can change its destination details")

        do {
            let db = try Schema.open(path)
            try db.execute("""
                INSERT INTO focus_rules (id, field, keyword, project) VALUES
                ('legacy-one', 'domain', 'example.com', 'Tracker'),
                ('legacy-two', 'domain', 'example.com', 'Tracker'),
                ('legacy-conflict', 'domain', 'example.com', 'Other')
                """)
        }
        let legacy = try run("focus", "config").filter { $0["keyword"] == .string("example.com") }
        check(Set(legacy.compactMap { $0["id"].stringValue }) == ["legacy-one", "legacy-conflict"],
              "upgrading keeps the effective rule and any legacy competing destination")

        let domain = Focus.websiteCondition("example.org")
        let url = Focus.websiteCondition("example.org/work?search=sample#details")
        check(domain == ("domain", "example.org") && url == ("url", "https://example.org/work"),
              "Website input distinguishes a bare domain from a path and drops query and fragment data")
        let ignored = try run("focus", "save-rule", "--ignore", "--field=\(url.field)", "--keyword=\(url.keyword)",
                              "--chrome-profile-id=Default")
        let savedIgnore = ignored.first { $0["keyword"] == .string("https://example.org/work") }!
        check(savedIgnore["project"].isNull && savedIgnore["ignore"] == .bool(true)
              && savedIgnore["chrome_profile_id"] == .string("Default"), "an ignore rule needs no project and keeps its scope")
        let twoTitles = try run("focus", "save-rule", "--ignore", "--field=window", "--keyword=Invoice", "--app-id=com.apple.Preview",
                                "--app-scope=Preview")
        let differentTitle = try run("focus", "save-rule", "--project=Tracker", "--field=window", "--keyword=Receipt",
                                     "--app-id=com.apple.Preview", "--app-scope=Preview")
        check(differentTitle.count == twoTitles.count + 1, "two title conditions can use the same exact app")
    }

    static func timelineTime() throws {
        let dbPath = NSTemporaryDirectory() + "timeline-checks-\(UUID().uuidString)/ledger.sqlite3"
        defer { try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent) }
        let environment = ["TRACKER_DB": dbPath]
        func run(_ args: String...) throws -> Data { try CLI.run(args, environment: environment)! }
        _ = try run("init", "--timezone=Europe/Rome")
        _ = try run("project", "add", "Site", "--kind=internal")
        _ = try run("time", "Site", "--minutes=12", "--at=2026-11-24T23:59:00")
        let zone = try Values.zone("Europe/Rome")
        let midnight = try Day.parse("2026-11-25").midnight(zone)
        let minute = 60_000
        let db = try Schema.open(dbPath)
        let blocks: [(String, Int, Int, Int, String?, Int)] = [
            ("across-midnight", -2, 2, 1, "Site", 0),
            ("review-one", -40, -37, 1, nil, 0),
            ("review-two", -32, -30, 1, nil, 0),
            ("ignored", -21, -17, 1, nil, 1),
            ("recording", 40, 60, 0, "Site", 0),
        ]
        for (id, start, end, closed, project, ignored) in blocks {
            try db.execute("INSERT INTO focus_blocks VALUES (?, 'com.openai.codex', 'ChatGPT', ?, ?, ?, ?, ?)",
                           [id, midnight + start * minute, midnight + end * minute, closed, project, ignored])
        }
        try db.execute("INSERT INTO toggl_time VALUES (1, 1, 1, 'Site', ?, ?)", [midnight - 12 * minute, midnight - 9 * minute])
        try db.execute("INSERT INTO entries (id, kind, at, provider, millis) VALUES ('agent', 'runtime', ?, 'codex', ?)",
                       [midnight, 120 * minute])
        func snapshot() throws -> JSON {
            try JSON.parse(try run("snapshot", "--start=2026-11-23", "--end=2026-11-30", "--with-human-time"))
        }
        let before = try snapshot()
        check(before["daily_human_millis"]["2026-11-24"].intValue == 17 * minute, "daily logged time includes manual, Toggl and assigned app time")
        check(before["daily_human_millis"]["2026-11-25"].intValue == 2 * minute, "daily logged time clips at midnight and excludes agent runtime and active blocks")
        check(before["totals"]["human_hours"].stringValue == PyDecimal.hours(19 * minute), "daily human time adds up to the period total")
        check(before["unassigned_focus_millis"].intValue == 5 * minute, "review time excludes ignored blocks")
        let day = try JSON.parse(try run("focus", "timeline", "--day=2026-11-24", "--with-human-time"))
        check(day["logged_human_millis"] == before["daily_human_millis"]["2026-11-24"], "Timeline and Overview agree for the same day")

        expectError("still being recorded") {
            _ = try run("focus", "classify", "review-one", "--ignore", "--also=recording")
        }
        try check(snapshot()["unassigned_focus_millis"].intValue == 5 * minute, "failed group changes roll back every block")
        _ = try run("focus", "classify", "review-one", "--ignore", "--also=review-two")
        try check(snapshot()["unassigned_focus_millis"].intValue == 0, "ignoring a group removes both entries from review")
        _ = try run("focus", "classify", "review-one", "--project=Site", "--also=review-two")
        try check(snapshot()["daily_human_millis"]["2026-11-24"].intValue == 22 * minute, "group assignment adds time from both entries")

        let id = UUID().uuidString.lowercased()
        let start = midnight - 7 * minute
        func recordIgnored(end: Int, closed: Bool) throws {
            try Focus.record(db, .array([.object([
                ("id", .string(id)), ("app_id", .string("com.apple.Passwords")), ("app_name", .string("Passwords")),
                ("started_at", .int(Int64(start))), ("ended_at", .int(Int64(end))), ("closed", .bool(closed)),
                ("ignored", .bool(true)), ("github", .object([("repo", .string("test/project"))])),
            ])]))
        }
        try recordIgnored(end: start + minute, closed: false)
        try recordIgnored(end: start + 2 * minute, closed: true)
        let ignoredDay = try JSON.parse(try run("focus", "timeline", "--day=2026-11-24", "--with-human-time"))
        let block = ignoredDay["blocks"].arrayValue?.first { $0["id"] == .string(id) }
        check(block?["ignored"] == .bool(true) && block?["closed"] == .bool(true)
              && block?["ended_at"].intValue == start + 2 * minute && block?["github_repo"].isNull == true,
              "automatically ignored blocks close with their full duration and no GitHub context")
        check(ignoredDay["logged_human_millis"].intValue == 22 * minute, "ignored time does not count toward logged time")
    }

    static func ledger() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["TRACKER_DB": folder.appendingPathComponent("ledger.sqlite3").path]
        func run(_ arguments: String...) throws -> String {
            String(decoding: try CLI.run(arguments, environment: environment) ?? Data("<not ported>".utf8), as: UTF8.self)
        }

        let initial = try JSON.parse(try run("init", "--timezone", "Europe/Rome", "--currency", "usd"))
        check(initial["currency"].stringValue == "USD" && initial["timezone"].stringValue == "Europe/Rome", "init sets defaults")
        check(initial["database"].stringValue?.hasSuffix("/ledger.sqlite3") == true, "init reports the ledger path")
        let attributes = try FileManager.default.attributesOfItem(atPath: environment["TRACKER_DB"]!)
        check((attributes[.posixPermissions] as? Int) == 0o600, "the ledger is private to its owner")

        try check(try run("project", "add", "--kind", "internal", "--", "Site") == "", "project add prints nothing")
        try _ = run("project", "add", "Shop", "--kind=billable", "--client=Acme", "--folder", folder.path, "--github", "https://github.com/Acme/Shop.git/")
        expectError("Billable projects need a client") { _ = try run("project", "add", "X", "--kind", "billable") }
        expectError("already exists") { _ = try run("project", "add", "Site", "--kind", "internal", "--new-only") }
        expectError("invalid choice") { _ = try run("project", "add", "Y", "--kind", "work") }
        expectError("required: --kind") { _ = try run("project", "add", "Y") }
        let projects = try JSON.parse(try run("project", "list"))
        check(projects.arrayValue?.count == 2, "two projects")
        let shop = projects.arrayValue?.first { $0["name"].stringValue == "Shop" }
        check(shop?["client"].stringValue == "Acme" && shop?["kind"].stringValue == "billable", "project fields")
        check(shop?["github_repo"].stringValue == "acme/shop", "the repository is normalised")
        check(shop?["folders"].arrayValue?.first?.stringValue == Values.resolvedPath(folder.path), "the folder is mapped")
        check(projects.arrayValue?.first { $0["name"].stringValue == "Site" }?["client"].stringValue == "Me", "own work goes to the self client")

        // A folder whose git remote is on GitHub links its repository; unlinking by hand sticks.
        let clone = folder.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["-C", clone.path, "init", "-q"]
        try gitInit.run(); gitInit.waitUntilExit()
        let gitRemote = Process()
        gitRemote.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitRemote.arguments = ["-C", clone.path, "remote", "add", "origin", "git@github.com:Acme/Docs.git"]
        try gitRemote.run(); gitRemote.waitUntilExit()
        try _ = run("project", "add", "Docs", "--kind=internal", "--folder", clone.path)
        try _ = run("project", "add", "Wiki", "--kind=internal")
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let gitOther = Process()
        gitOther.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitOther.arguments = ["-C", other.path, "init", "-q"]
        try gitOther.run(); gitOther.waitUntilExit()
        let remoteOther = Process()
        remoteOther.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        remoteOther.arguments = ["-C", other.path, "remote", "add", "origin", "https://github.com/Acme/Docs"]
        try remoteOther.run(); remoteOther.waitUntilExit()
        try _ = run("project", "map", "Wiki", other.path)
        try check(try JSON.parse(try run("github", "autolink", "--project", "Docs")) == .array([]),
                  "a repository two projects share is not linked to one of them")
        try _ = run("github", "unlink", "Wiki")
        try check(try JSON.parse(try run("github", "autolink")) == .array([]),
                  "a repository an opted-out project names is not linked to another")
        try _ = run("project", "unmap", "Wiki", other.path)
        try check(try JSON.parse(try run("github", "autolink")).arrayValue?.count == 1, "autolink links folder repositories")
        func docsRepo() throws -> String? {
            try JSON.parse(try run("project", "list")).arrayValue?.first { $0["name"].stringValue == "Docs" }?["github_repo"].stringValue
        }
        try check(try docsRepo() == "acme/docs", "a folder's GitHub remote links the repository")
        try _ = run("github", "unlink", "Docs")
        try check(try JSON.parse(try run("github", "autolink")) == .array([]), "an unlinked repository is not linked again")
        try check(try docsRepo() == nil, "unlinking sticks")
        try _ = run("github", "set", "Docs", "acme/docs")
        try check(try docsRepo() == "acme/docs", "linking by hand still works")

        try check(try JSON.parse(try run("client", "list")) == .strings(["Acme", "Me"]), "clients are listed")
        try check(try JSON.parse(try run("client", "save", "Acme Corp", "--previous", "Acme")) == .strings(["Acme Corp", "Me"]),
              "a client can be renamed")
        expectError("changed since it was loaded") { _ = try run("client", "save", "B", "--previous", "Gone") }
        let renamed = try JSON.parse(try run("project", "list")).arrayValue?.first { $0["name"].stringValue == "Shop" }
        check(renamed?["client"].stringValue == "Acme Corp", "renaming moves the projects")

        let looks = try JSON.parse(try run("appearance", "--project=Shop", "--color=#3478f6"))
        check(looks.arrayValue?.first?["color"].stringValue == "#3478F6", "project colours are stored upper case")
        expectError("Icons belong to clients") { _ = try run("appearance", "--project", "Shop", "--icon", "x.png") }
        expectError("Use a colour like") { _ = try run("appearance", "--project", "Shop", "--color", "blue") }
        try check(try JSON.parse(try run("appearance", "--project=Shop", "--color=")) == .array([]), "a blank colour clears it")

        let plans = try JSON.parse(try run("subscription", "set", "Max", "--monthly", "100", "--provider=claude"))
        check(plans["currency"].stringValue == "USD" && plans["monthly_total"].stringValue == "100.00", "plans add up")
        check(plans["plans"].arrayValue?.first?["provider"].stringValue == "claude", "plans keep their provider")
        expectError("already exists") { _ = try run("subscription", "set", "Max", "--monthly", "1", "--new-only") }
        try check(try JSON.parse(try run("subscription", "remove", "Max"))["plans"] == .array([]), "plans can be removed")
        expectError("Currency is fixed") {
            _ = try run("subscription", "set", "Pro", "--monthly", "20")
            _ = try run("init", "--currency", "EUR")
        }

        try check(try run("model-rate", "codex", "gpt-5", "--input", "1.25", "--cached", "0.13", "--cache-write", "0",
                      "--output", "10") == "", "model rates are saved")
        expectError("at most two decimal places") {
            _ = try run("model-rate", "codex", "gpt-5", "--input", "1.255", "--cached", "0", "--cache-write", "0", "--output", "0")
        }
        expectError("harness ID") {
            _ = try run("model-rate", "Codex", "gpt-5", "--input", "1", "--cached", "0", "--cache-write", "0", "--output", "0")
        }

        let entry = try run("time", "Site", "--minutes", "90", "--activity", "reviewing", "--at", "2026-11-20T09:00:00")
        check(entry.hasPrefix("time:") && entry.hasSuffix("\n") && entry.count == 5 + 32 + 1, "time prints its id")
        let expense = try run("expense", "Shop", "API credits", "--amount", "12.40", "--reimburse")
        check(expense.hasPrefix("expense:"), "expense prints its id")
        expectError("Unknown project") { _ = try run("time", "Nope", "--minutes", "5") }
        expectError("ISO date") { _ = try run("time", "Site", "--minutes", "5", "--at", "soon") }
        try check(try run("remove", entry.trimmingCharacters(in: .newlines)) == "", "manual entries can be removed")
        expectError("No manual entry") { _ = try run("remove", "time:missing") }
        expectError("Unknown imported entry") { _ = try run("assign", "codex:1", "--use-folder") }
        expectError("one of the arguments") { _ = try run("assign", "codex:1") }

        let db = try Schema.open(environment["TRACKER_DB"]!)
        let stored = try db.first("SELECT * FROM entries WHERE kind = 'expense'")
        check(stored?["cents"].int == 1240 && stored?["reimbursable"].int == 1 && stored?["label"].string == "API credits",
              "expenses are stored in cents")
        try check(try CLI.run(["no-such-command"], environment: environment) == nil, "unknown commands return nil")
        check(Engine.operation("list_projects")?.effect == .read, "operations declare their effect")
        expectError("invalid harness_id value: 'Bad_Name'") { _ = try run("import-harness", "Bad_Name") }
        expectError("invalid int value: 'x'") { _ = try run("sync", "--recent-days", "x") }
    }

    static func paths() throws {
        let root = NSTemporaryDirectory() + "core-paths-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/real/child", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real/child")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let real = Values.resolvedPath(root)
        check(Values.resolvedPath(root + "/link/../work") == real + "/real/work", "\"..\" applies after a symlink, like Python")
        check(Values.resolvedPath(root + "/missing/../x") == real + "/x", "missing parts are kept")
        check(Values.parseAt("2026-11-20T10:30:00+23:00", zone: TimeZone(secondsFromGMT: 0)!) == 1_795_087_800_000,
              "offsets beyond Foundation's 18 hours")
    }

    static func harnessHelpers() throws {
        // Values from the Python engine (tracker/harnesses.py).
        check(H.digest(.null, .string("m"), .object([("input", .int(1)), ("cached", .int(2))]), .string("0.5"))
              == "825ff173e72b948f188b", "digests match Python's sha1 of sorted JSON")
        check(Harnesses.droidModel("custom:Claude-Sonnet-4.5-[Proxy]") == "claude-sonnet-4-5", "Droid model names")
        check(H.cost(.double(0.1 + 0.2)) == "0.3" && H.cost(.double(1e-11)) == "0.0" && H.cost(.bool(true)) == nil,
              "recorded costs round like Python")
        check(H.millis(.string("2026-09-21 14:13:20")) == 1_790_000_000_000 && H.millis(.string("1790000000.5")) == 1_790_000_000_500,
              "timestamps in SQLite and Unix forms")
        check(H.matches("u2.jsonl.deleted.1", "*.jsonl.deleted.*") && !H.matches("a.json", "*.jsonl"), "fnmatch patterns")
        let blob: [UInt8] = [0x08, 0x96, 0x01, 0x12, 0x03, 0x61, 0x62, 0x63]  // field 1 = 150, field 2 = "abc"
        let fields = try Harnesses.proto(blob)
        check(Harnesses.protoInt(fields, 1) == 150 && Harnesses.protoText(fields, 2) == "abc", "protobuf fields decode")
        expectError("Truncated protobuf") { _ = try Harnesses.proto([0x12, 0x05, 0x61]) }
        check(Sync.providers.count == 20 && Harnesses.fileSources().count == 17, "every agent is registered")
    }

    static func network() throws {
        check(HTTP.query([("start_date", "2026-11-02T08:00:00.000+00:00"), ("a b", "~x/")])
              == "start_date=2026-11-02T08%3A00%3A00.000%2B00%3A00&a+b=~x%2F", "urlencode quotes like quote_plus")
        let parsed = try JSON.parse(bytes: Array(#"{"a": 0.10, "b": 2, "c": "0.1"}"#.utf8), decimalFloats: true)
        check(parsed["a"].decimalText == "0.10" && parsed["b"] == .int(2) && parsed["c"].decimalText == nil,
              "decimal floats keep their text")
        check(Prices.rate(.string(" 0.5 ")) == "0.5" && Prices.rate(.double(1e-7)) == "1E-7" && Prices.rate(.string("101")) == nil
              && Prices.rate(.bool(true)) == nil && Prices.rate(.string("-0")) == "-0", "catalog rates")
        check(Toggl.utcStamp(1_794_045_600_250) == "2026-11-07T10:00:00.250+00:00", "Toggl timestamps")
        check(Toggl.pythonInt(" 1_794 ") == 1794 && Toggl.pythonInt("1__2") == nil && Toggl.pythonInt("+5") == 5
              && Toggl.pythonInt("x") == nil, "header integers")
        check(JSON.object([("a", .array([.string("it's"), .null, .bool(true)]))]).reprText == #"{'a': ["it's", None, True]}"#,
              "Python repr")
    }
}
