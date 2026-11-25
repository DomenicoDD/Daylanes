import Foundation

// `TrackerCLI`: the engine's command line. It takes the same arguments and prints the same output as the
// former Python engine (`python3 -m tracker`).

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "api", arguments.dropFirst().first == "schema" {
    print(Engine.describe().pythonText())
    exit(0)
}

if arguments.first == "call" {
    // tracker call <operation> [--json '{…}'] [--db PATH]
    var rest = Array(arguments.dropFirst())
    guard let name = rest.first else {
        FileHandle.standardError.write(Data("tracker: usage: tracker call <operation> [--json PARAMS]\n".utf8))
        exit(2)
    }
    rest.removeFirst()
    var params = JSON.object([])
    var database = Values.databasePath()
    while let option = rest.first {
        rest.removeFirst()
        if option == "--json", let text = rest.first {
            rest.removeFirst()
            do { params = try JSON.parse(text) } catch {
                FileHandle.standardError.write(Data("tracker: \(error.localizedDescription)\n".utf8))
                exit(2)
            }
        } else if option == "--db", let path = rest.first {
            rest.removeFirst()
            database = Values.resolvedPath(path)
        } else {
            FileHandle.standardError.write(Data("tracker: unrecognized argument \(option)\n".utf8))
            exit(2)
        }
    }
    // `tracker call` is how an agent without MCP reaches the same operations, so it locks with the MCP.
    if let reason = LicenceStamp.lockReason() {
        FileHandle.standardError.write(Data("tracker: \(reason)\n".utf8))
        exit(3)
    }
    do {
        let result = try Engine.call(name, params, context: OperationContext(databasePath: database, actor: .cli))
        print(result.pythonText())
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("tracker: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// tracker [--db PATH] diary guide|work|submit ROUTINE: what a pasted Diary prompt runs (core/DiaryGuide.swift).
do {
    var rest = arguments[...]
    var database = Values.databasePath()
    if let first = rest.first, first.hasPrefix("--db=") {
        database = Values.resolvedPath(String(first.dropFirst(5)))
        rest = rest.dropFirst()
    } else if rest.first == "--db", rest.count > 1 {
        database = Values.resolvedPath(rest[rest.startIndex + 1])
        rest = rest.dropFirst(2)
    }
    if rest.first == "diary" {
        if let reason = LicenceStamp.lockReason() {
            FileHandle.standardError.write(Data("tracker: \(reason)\n".utf8))
            exit(3)
        }
        let cli = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let (status, text) = DiaryCLI.run(Array(rest.dropFirst()), database: database, cli: cli) {
            FileHandle.standardInput.readDataToEndOfFile()
        }
        (status == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8))
        exit(status)
    }
}

// tracker mcp: the local MCP server for agents (core/MCP.swift).
if let status = MCP.run(arguments: arguments) {
    exit(status)
}

if arguments.first == "diary-run" {
    // diary-run DATABASE ROUTINE AGENT EXECUTABLE FOLDER [legacy conversation ID] [--force]
    let force = arguments.contains("--force")
    let values = arguments.filter { $0 != "--force" }
    guard [6, 7].contains(values.count), let routine = UUID(uuidString: values[2]),
          let agent = DiaryAgent(rawValue: values[3]) else {
        FileHandle.standardError.write(Data("tracker: invalid diary-run arguments\n".utf8))
        exit(2)
    }
    do {
        try DiarySchedule.run(database: values[1], id: routine,
                              runner: .init(agent: agent, executable: values[4], directory: values[5]), force: force)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if arguments.isEmpty || arguments == ["-h"] || arguments == ["--help"] {
    print(CLI.usage)
    exit(arguments.isEmpty ? 2 : 0)
}

let stdinData = CLI.readsInput(arguments) ? FileHandle.standardInput.readDataToEndOfFile() : nil
do {
    guard let output = try CLI.run(arguments, input: stdinData) else {
        FileHandle.standardError.write(Data("\(CLI.usage)\ntracker: error: unknown command: \(arguments.joined(separator: " "))\n".utf8))
        exit(2)
    }
    FileHandle.standardOutput.write(output)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
