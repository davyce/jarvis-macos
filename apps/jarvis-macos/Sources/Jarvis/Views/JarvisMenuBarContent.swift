import AppKit
import SwiftUI

struct JarvisMenuBarLabel: View {
    @Environment(ProjectStore.self) private var projectStore

    private var hasBuildFailure: Bool {
        projectStore.projects.contains { project in
            if case .failed = projectStore.buildSnapshot(for: project).state { return true }
            return false
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A dedicated, correctly-sized asset -- MenuBarExtra's SwiftUI-to-
            // NSStatusItem snapshot does not respect a `.frame()` constraint
            // on the general-purpose 128pt JarvisMark, which made it render
            // at native size and get clipped to a solid sliver of its dark
            // background with the "J" cropped out entirely.
            Image("JarvisMenuBarMark")
                .renderingMode(.original)

            if let badgeColor {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: 20, height: 20)
    }

    /// The Jarvis mark always stays visible; a small badge signals state on
    /// top of it instead of replacing the icon entirely.
    private var badgeColor: Color? {
        if hasBuildFailure { return .red }
        if projectStore.isListening { return .cyan }
        return nil
    }
}

struct JarvisMenuBarContent: View {
    @Environment(ProjectStore.self) private var projectStore
    @Environment(\.openWindow) private var openWindow
    @State private var listeningError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("JARVIS")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: projectStore.isListening ? "ear.fill" : "ear")
                    .foregroundStyle(projectStore.isListening ? .cyan : .secondary)
                    .help(projectStore.isListening ? "Ecoute active" : "Ecoute inactive")
            }

            VStack(spacing: 8) {
                ForEach(projectStore.projects) { project in
                    let git = projectStore.snapshot(for: project)
                    let build = projectStore.buildSnapshot(for: project)
                    Button {
                        projectStore.focus(project)
                        openMainWindow()
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(dotColor(git: git, build: build))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                    .font(.body.weight(.medium))
                                Text(git.isRepository ? git.branch : "Indisponible")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if case .failed = build.state {
                                Image(systemName: "hammer.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Toggle(
                "Ecoute active (clap)",
                isOn: Binding(
                    get: { projectStore.isListening },
                    set: { enabled in Task { listeningError = await projectStore.setListening(enabled) } }
                )
            )
            .toggleStyle(.switch)
            .font(.callout)
            if let listeningError {
                Text(listeningError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Actualiser") { projectStore.refreshAll() }
                Spacer()
                Button("Ouvrir Jarvis") { openMainWindow() }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 260)
    }

    private func dotColor(git: GitSnapshot, build: BuildSnapshot) -> Color {
        if case .failed = build.state { return .red }
        if !git.isRepository { return .secondary }
        return git.changedFileCount > 0 ? .orange : .green
    }

    private func openMainWindow() {
        WindowPresenter.openMainWindow = { openWindow(id: "main") }
        WindowPresenter.presentMainWindow()
    }
}
