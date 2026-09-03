import SwiftUI

struct ProjectsView: View {
    @Environment(ProjectStore.self) private var projectStore
    @State private var selectedProject: JarvisProject?

    var body: some View {
        List(projectStore.projects) { project in
            let snapshot = projectStore.snapshot(for: project)
            Button {
                projectStore.focus(project)
                selectedProject = project
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: project.isFolder ? "folder" : "doc")
                            .foregroundStyle(.cyan)
                        Text(project.name)
                            .font(.headline)
                        Spacer()
                        Text(project.id == projectStore.focusedProjectID ? "Focused" : "")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    Text(project.rootPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(snapshot.isRepository ? snapshot.lastCommitSubject : project.isFolder ? "Dossier local" : "Document local")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Projects and sources")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { projectStore.chooseDocument() } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("Ajouter un document")
                Button { projectStore.chooseFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Ajouter un projet ou dossier")
            }
        }
        .sheet(item: $selectedProject) { project in
            ProjectSourceDetailView(project: project)
                .environment(projectStore)
        }
    }
}
