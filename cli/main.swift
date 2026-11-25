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
    do {
        let result = try Engine.call(name, params, context: OperationContext(databasePath: database, actor: .cli))
        print(result.pythonText())
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("tracker: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// tracker mcp: the local MCP server for agents (core/MCP.swift).
if let status = MCP.run(arguments: arguments) {
    exit(status)
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
