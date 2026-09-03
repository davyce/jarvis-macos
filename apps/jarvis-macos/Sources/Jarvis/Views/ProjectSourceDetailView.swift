import AppKit
import SwiftUI

struct ProjectSourceDetailView: View {
    @Environment(ProjectStore.self) private var projectStore
    @Environment(\.dismiss) private var dismiss
    let project: JarvisProject
    @State private var entries: [URL] = []
    @State private var selectedFile: URL?
    @State private var content = ""
    @State private var error: String?
    @State private var commitMessage = ""
    @State private var showCommit = false
    @State private var showPush = false
    @State private var result: String?

    private var rootURL: URL { URL(fileURLWithPath: project.rootPath) }

    var body: some View {
        NavigationSplitView {
            List(entries, id: \.self) { url in
                Button {
                    select(url)
                } label: {
                    Label(url.lastPathComponent, systemImage: icon(for: url))
                }
                .buttonStyle(.plain)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 300)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selectedFile?.lastPathComponent ?? project.name)
                        .font(.title2.weight(.semibold))
                    HStack {
                        Button("Read") { if let selectedFile { read(selectedFile) } }
                            .buttonStyle(.bordered)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([selectedFile ?? rootURL])
                        }
                        .buttonStyle(.bordered)
                        if projectStore.snapshot(for: project).isRepository {
                            Button("Commit") { showCommit = true }.buttonStyle(.bordered)
                            Button("Push") { showPush = true }.buttonStyle(.borderedProminent)
                        }
                    }
                    if let error {
                        ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                    } else if content.isEmpty {
                        ContentUnavailableView("Choose a text file", systemImage: "doc.text")
                    } else {
                        Text(content)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(28)
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear { load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $showCommit) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create commit").font(.title2.weight(.semibold))
                Text("Jarvis will stage all current changes in \(project.name) before creating the local commit.")
                    .foregroundStyle(.secondary)
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showCommit = false }
                    Button("Commit") {
                        let command = GitCommandRunner.commitAll(projectPath: project.rootPath, message: commitMessage)
                        result = command.succeeded ? "Commit created." : "Commit failed: \(command.output)"
                        showCommit = false
                        projectStore.refresh(project)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(28)
            .frame(width: 460)
        }
        .alert("Push to remote?", isPresented: $showPush) {
            Button("Cancel", role: .cancel) {}
            Button("Push") {
                let command = GitCommandRunner.push(projectPath: project.rootPath)
                result = command.succeeded ? "Push completed." : "Push failed: \(command.output)"
                projectStore.refresh(project)
            }
        } message: {
            Text("Jarvis will run git push. The configured Git credential manager or GitHub CLI handles authentication.")
        }
        .alert("Git action", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK") { result = nil }
        } message: { Text(result ?? "") }
    }

    private func load() {
        if project.isFolder {
            entries = LocalFileReader.entries(in: rootURL)
        } else {
            entries = [rootURL]
            selectedFile = rootURL
            read(rootURL)
        }
    }

    private func select(_ url: URL) {
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if directory {
            entries = LocalFileReader.entries(in: url)
            selectedFile = nil
            content = ""
            error = nil
        } else {
            selectedFile = url
            read(url)
        }
    }

    private func read(_ url: URL) {
        do {
            content = try LocalFileReader.read(url: url)
            error = nil
        } catch {
            content = ""
            self.error = error.localizedDescription
        }
    }

    private func icon(for url: URL) -> String {
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return directory ? "folder" : "doc.text"
    }
}
