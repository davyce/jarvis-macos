import SwiftUI

struct NowView: View {
    @Environment(ProjectStore.self) private var projectStore

    var body: some View {
        Group {
            if let project = projectStore.focusedProject {
                let snapshot = projectStore.snapshot(for: project)
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        header(project: project)
                        focus(project: project, snapshot: snapshot)
                        attention(snapshot: snapshot)
                        recentFiles(project: project)
                        projects
                    }
                    .padding(48)
                    .frame(maxWidth: 920, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No project selected", systemImage: "folder")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(project: JarvisProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JARVIS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Ready to continue.")
                .font(.system(size: 34, weight: .medium))
            Text("Focused on \(project.name).")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func focus(project: JarvisProject, snapshot: GitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CURRENT FOCUS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text(project.name)
                    .font(.title2.weight(.semibold))
                LabeledContent("Branch") {
                    Text(snapshot.branch)
                        .font(.body.monospaced())
                }
                LabeledContent("Last commit") {
                    Text(snapshot.lastCommitSubject)
                        .multilineTextAlignment(.trailing)
                }
                if let date = snapshot.lastCommitDate {
                    LabeledContent("Last activity") {
                        Text(date, style: .relative)
                    }
                }
            }
            .padding(22)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func attention(snapshot: GitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ATTENTION")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if snapshot.changedFileCount > 0 {
                Text("\(snapshot.changedFileCount) file\(snapshot.changedFileCount == 1 ? "" : "s") changed but not committed.")
                    .font(.title3)
                Text("Jarvis can inspect the changes when the project context is connected.")
                    .foregroundStyle(.secondary)
            } else if snapshot.isRepository {
                Text("No uncommitted changes detected.")
                    .font(.title3)
                Text("The Git working tree is clean.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Git information is not available.")
                    .font(.title3)
                Text("Check the project path before enabling observation.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recentFiles(project: JarvisProject) -> some View {
        let files = projectStore.recentFiles(for: project)

        return VStack(alignment: .leading, spacing: 12) {
            Text("FICHIERS RECENTS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if files.isEmpty {
                Text("Aucun fichier recent detecte.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(files) { file in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(file.name)
                                .lineLimit(1)
                            Spacer()
                            Text(file.modifiedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROJECTS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(projectStore.projects) { project in
                Button {
                    projectStore.focus(project)
                } label: {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Text(projectStore.snapshot(for: project).branch)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
