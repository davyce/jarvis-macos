import Foundation

enum BuildInspector {
    static func detectTool(projectPath: String) -> BuildTool? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: projectPath) else {
            return nil
        }

        if contents.contains(where: { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }) {
            return .xcodebuild
        }
        if contents.contains("Package.swift") {
            return .swiftPackage
        }
        if contents.contains("Cargo.toml") {
            return .cargo
        }
        if contents.contains("package.json") {
            if contents.contains("pnpm-lock.yaml") { return .pnpm }
            if contents.contains("yarn.lock") { return .yarn }
            return .npm
        }
        if contents.contains("Makefile") {
            return .make
        }
        return nil
    }

    static func run(projectPath: String, tool: BuildTool) async -> BuildSnapshot {
        await Task.detached(priority: .utility) {
            guard let command = command(for: tool, projectPath: projectPath) else {
                return BuildSnapshot(tool: tool, state: .notDetected, checkedAt: .now)
            }

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
            process.environment = enrichedEnvironment()
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
            } catch {
                return BuildSnapshot(tool: tool, state: .failed(detail: error.localizedDescription), checkedAt: .now)
            }
            process.waitUntilExit()

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)

            if process.terminationStatus == 0 {
                return BuildSnapshot(tool: tool, state: .success, checkedAt: .now)
            }

            let tail = text
                .split(separator: "\n")
                .suffix(6)
                .joined(separator: "\n")
            return BuildSnapshot(
                tool: tool,
                state: .failed(detail: tail.isEmpty ? "Echec sans detail (code \(process.terminationStatus))." : tail),
                checkedAt: .now
            )
        }.value
    }

    private static func command(for tool: BuildTool, projectPath: String) -> (executable: String, arguments: [String])? {
        switch tool {
        case .xcodebuild:
            guard let projectFlag = xcodeProjectFlag(projectPath: projectPath),
                  let scheme = xcodeScheme(projectFlag: projectFlag) else { return nil }
            return ("/usr/bin/xcodebuild", projectFlag + ["-scheme", scheme, "-destination", "platform=macOS", "-quiet", "build"])
        case .swiftPackage:
            return ("/usr/bin/env", ["swift", "build"])
        case .npm:
            guard let script = buildScriptName(projectPath: projectPath) else { return nil }
            return ("/usr/bin/env", ["npm", "run", script])
        case .yarn:
            guard let script = buildScriptName(projectPath: projectPath) else { return nil }
            return ("/usr/bin/env", ["yarn", script])
        case .pnpm:
            guard let script = buildScriptName(projectPath: projectPath) else { return nil }
            return ("/usr/bin/env", ["pnpm", script])
        case .cargo:
            return ("/usr/bin/env", ["cargo", "build"])
        case .make:
            return ("/usr/bin/env", ["make"])
        }
    }

    /// `package.json` scripts vary per project: prefer an explicit "build",
    /// otherwise fall back to "build:web" (used by Limule). Returns nil when
    /// neither exists so the caller reports `.notDetected` instead of
    /// running a script that's guaranteed to fail with "Missing script".
    private static func buildScriptName(projectPath: String) -> String? {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else {
            return nil
        }
        if scripts["build"] != nil { return "build" }
        if scripts["build:web"] != nil { return "build:web" }
        return nil
    }

    private static func xcodeProjectFlag(projectPath: String) -> [String]? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: projectPath) else { return nil }
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return ["-workspace", projectPath + "/" + workspace]
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return ["-project", projectPath + "/" + project]
        }
        return nil
    }

    private static func xcodeScheme(projectFlag: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = projectFlag + ["-list"]
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "Schemes:") else { return nil }
        return text[range.upperBound...]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func enrichedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.volta/bin"
        ]
        let existing = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extraPaths + [existing]).joined(separator: ":")
        return environment
    }
}
