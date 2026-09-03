import Foundation

/// Small, deterministic working memory for each observed project. It keeps
/// the latest concrete context across conversations without asking a model to
/// silently decide what should be remembered about Davy.
enum ProjectMemoryStore {
    struct Memory: Codable, Equatable {
        var projectID: String
        var projectName: String
        var lastUserRequest: String = ""
        var lastJarvisReply: String = ""
        var recentDecisions: [String] = []
        var updatedAt: Date = .now
    }

    private static let maximumExcerptLength = 700

    static func memory(for project: JarvisProject) -> Memory {
        all()[project.id] ?? Memory(projectID: project.id, projectName: project.name)
    }

    static func record(_ entry: CommandEntry, for project: JarvisProject) {
        var item = memory(for: project)
        item.projectName = project.name
        let excerpt = compact(entry.text)
        switch entry.role {
        case .user:
            item.lastUserRequest = excerpt
            if isDecision(entry.text) {
                item.recentDecisions.removeAll { $0 == excerpt }
                item.recentDecisions.insert(excerpt, at: 0)
                item.recentDecisions = Array(item.recentDecisions.prefix(4))
            }
        case .jarvis:
            item.lastJarvisReply = excerpt
        }
        item.updatedAt = .now
        save(item)
    }

    static func context(for project: JarvisProject) -> String? {
        let item = memory(for: project)
        guard !item.lastUserRequest.isEmpty || !item.lastJarvisReply.isEmpty || !item.recentDecisions.isEmpty else {
            return nil
        }
        var lines = ["Memoire de travail persistante pour \(project.name) (mise a jour \(item.updatedAt.formatted(.relative(presentation: .named)))) :"]
        if !item.lastUserRequest.isEmpty { lines.append("- Derniere demande : \(item.lastUserRequest)") }
        if !item.lastJarvisReply.isEmpty { lines.append("- Derniere reponse : \(item.lastJarvisReply)") }
        if !item.recentDecisions.isEmpty {
            lines.append("- Decisions recentes :")
            lines.append(contentsOf: item.recentDecisions.map { "  - \($0)" })
        }
        lines.append("Utilise cette memoire comme contexte, mais ne la repete pas a Davy sauf s'il la demande.")
        return lines.joined(separator: "\n")
    }

    static func clear(projectID: String) {
        var values = all()
        values.removeValue(forKey: projectID)
        persist(values)
    }

    private static func all() -> [String: Memory] {
        guard let data = try? Data(contentsOf: storageURL()),
              let decoded = try? JSONDecoder().decode([String: Memory].self, from: data) else { return [:] }
        return decoded
    }

    private static func save(_ memory: Memory) {
        var values = all()
        values[memory.projectID] = memory
        persist(values)
    }

    private static func persist(_ memories: [String: Memory]) {
        guard let data = try? JSONEncoder().encode(memories) else { return }
        let url = storageURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func storageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("project-memory.json")
    }

    private static func compact(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(normalized.prefix(maximumExcerptLength))
    }

    private static func isDecision(_ text: String) -> Bool {
        let value = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return ["on valide", "je valide", "decide", "on part sur", "choisis", "garde", "priorite"].contains { value.contains($0) }
    }
}
