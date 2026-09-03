import Foundation

enum GitCommandRunner {
    struct Result {
        let succeeded: Bool
        let output: String
    }

    static func commitAll(projectPath: String, message: String) -> Result {
        let stage = run(projectPath: projectPath, arguments: ["add", "--all"])
        guard stage.succeeded else { return stage }
        return run(projectPath: projectPath, arguments: ["commit", "-m", message])
    }

    static func push(projectPath: String) -> Result {
        run(projectPath: projectPath, arguments: ["push"])
    }

    static func status(projectPath: String) -> Result {
        run(projectPath: projectPath, arguments: ["status", "--short", "--branch"])
    }

    static func createPullRequest(projectPath: String, title: String, body: String?, base: String?) -> Result {
        var arguments = ["gh", "pr", "create", "--title", title]
        if let body, !body.isEmpty { arguments += ["--body", body] }
        if let base, !base.isEmpty { arguments += ["--base", base] }
        return runExecutable("/usr/bin/env", arguments: arguments, currentDirectory: projectPath)
    }

    private static func run(projectPath: String, arguments: [String]) -> Result {
        runExecutable("/usr/bin/git", arguments: ["-C", projectPath] + arguments, currentDirectory: projectPath)
    }

    private static func runExecutable(_ executable: String, arguments: [String], currentDirectory: String) -> Result {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return Result(succeeded: false, output: error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
            + error.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(succeeded: process.terminationStatus == 0, output: text)
    }
}
