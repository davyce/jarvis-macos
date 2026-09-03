import Foundation

enum GitInspector {
    static func inspect(projectPath: String) -> GitSnapshot {
        guard FileManager.default.fileExists(atPath: projectPath),
              runGit(["-C", projectPath, "rev-parse", "--is-inside-work-tree"]) == "true"
        else {
            return .unavailable()
        }

        let branch = runGit(["-C", projectPath, "branch", "--show-current"])
        let subject = runGit(["-C", projectPath, "log", "-1", "--format=%s"])
        let dateText = runGit(["-C", projectPath, "log", "-1", "--format=%cI"])
        let statusLines = runGit(["-C", projectPath, "status", "--short"])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let commits = runGit([
            "-C", projectPath,
            "log", "--since=6.days", "--format=%cI"
        ])

        return GitSnapshot(
            branch: branch.isEmpty ? "Detached HEAD" : branch,
            lastCommitSubject: subject.isEmpty ? "No commits yet." : subject,
            lastCommitDate: ISO8601DateFormatter().date(from: dateText),
            changedFileCount: statusLines.count,
            changedFiles: Array(statusLines.prefix(8)),
            isRepository: true,
            activityHistory: activityHistory(from: commits),
            inspectedAt: .now
        )
    }

    private static func activityHistory(from commitDates: String) -> [ProjectActivityPoint] {
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        let counts = commitDates
            .split(separator: "\n")
            .compactMap { formatter.date(from: String($0)) }
            .reduce(into: [Date: Int]()) { result, date in
                result[calendar.startOfDay(for: date), default: 0] += 1
            }

        let today = calendar.startOfDay(for: .now)
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 6, to: today) else {
                return nil
            }
            return ProjectActivityPoint(date: date, commitCount: counts[date, default: 0])
        }
    }

    private static func runGit(_ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        guard process.terminationStatus == 0 else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
