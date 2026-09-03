import Foundation

enum ResumeComposer {
    static func summary(
        project: JarvisProject,
        git: GitSnapshot,
        build: BuildSnapshot,
        recentFiles: [RecentFileEntry] = [],
        workspaceItems: [WorkspaceItem] = []
    ) -> String {
        guard git.isRepository else {
            let base = "Jarvis n'a pas encore d'information Git pour \(project.name). "
                + "Verifie le chemin du projet dans Connexions."
            guard let workspace = workspaceLine(workspaceItems) else { return base }
            return "\(base) \(workspace)"
        }

        var lines: [String] = []
        lines.append("Tu es sur \(project.name), branche \(git.branch).")

        if let date = git.lastCommitDate {
            lines.append(
                "Dernier commit \(date.formatted(.relative(presentation: .named))) : \"\(git.lastCommitSubject)\"."
            )
        } else {
            lines.append("Aucun commit trouve pour le moment.")
        }

        if git.changedFileCount == 0 {
            lines.append("L'arbre de travail est propre, rien en attente de commit.")
            if !recentFiles.isEmpty {
                let names = recentFiles.prefix(4).map(\.name).joined(separator: ", ")
                lines.append("Fichiers touches le plus recemment : \(names).")
            }
        } else {
            let preview = git.changedFiles.prefix(5).joined(separator: ", ")
            let remaining = git.changedFileCount - git.changedFiles.prefix(5).count
            let more = remaining > 0 ? " (+\(remaining) autre\(remaining == 1 ? "" : "s"))" : ""
            lines.append(
                "\(git.changedFileCount) fichier\(git.changedFileCount == 1 ? "" : "s") modifie\(git.changedFileCount == 1 ? "" : "s") non commite\(git.changedFileCount == 1 ? "" : "s") : \(preview)\(more)."
            )
        }

        switch build.state {
        case .success:
            lines.append("Dernier build verifie : succes.")
        case .failed(let detail):
            let firstLine = detail.split(separator: "\n").first.map(String.init) ?? "voir details"
            lines.append("Dernier build verifie : echec - \(firstLine)")
        case .running:
            lines.append("Un build est en cours de verification.")
        case .unknown, .notDetected:
            lines.append("Aucun statut de build verifie pour l'instant.")
        }

        if let workspace = workspaceLine(workspaceItems) {
            lines.append(workspace)
        }

        return lines.joined(separator: " ")
    }

    private static func workspaceLine(_ items: [WorkspaceItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let names = items.prefix(5).map(\.name).joined(separator: ", ")
        let remaining = items.count - items.prefix(5).count
        let more = remaining > 0 ? " (+\(remaining) autre\(remaining == 1 ? "" : "s"))" : ""
        return "Workspace connecte : \(names)\(more)."
    }
}
