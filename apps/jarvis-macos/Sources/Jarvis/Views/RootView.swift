import SwiftUI

enum JarvisSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case now = "Now"
    case jarvis = "Jarvis"
    case projects = "Projects"
    case connections = "Connections"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house"
        case .now: return "circle.dotted"
        case .jarvis: return "sparkles"
        case .projects: return "square.stack.3d.up"
        case .connections: return "link"
        }
    }
}

struct RootView: View {
    @Environment(ProjectStore.self) private var projectStore
    @Environment(\.openWindow) private var openWindow
    @State private var selection: JarvisSection?

    init() {
        let opensGmail = ProcessInfo.processInfo.arguments.contains("--connect-gmail")
        _selection = State(initialValue: opensGmail ? .connections : .home)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("JARVIS")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .tracking(1.6)
                        Text("LIMULE COMPANION")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 10, trailing: 8))
                }

                Section("WORKSPACE") {
                    ForEach(JarvisSection.allCases) { section in
                        sectionLabel(for: section)
                            .tag(section)
                    }
                }

                Section("PROJECTS") {
                    ForEach(projectStore.projects) { project in
                        Button {
                            projectStore.focus(project)
                            selection = .now
                        } label: {
                            ProjectSidebarRow(
                                project: project,
                                snapshot: projectStore.snapshot(for: project),
                                isFocused: project.id == projectStore.focusedProjectID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            switch selection ?? .now {
            case .home:
                HomeView()
            case .now:
                NowView()
            case .jarvis:
                JarvisCommandView()
            case .projects:
                ProjectsView()
            case .connections:
                ConnectionsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = .jarvis
                } label: {
                    Image(systemName: "command")
                }
                .help("Ouvrir Jarvis (Cmd+K)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    projectStore.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rafraichir les projets")
                .disabled(projectStore.isRefreshing)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jarvisOpenCommand)) { _ in
            selection = .jarvis
        }
        .onAppear {
            WindowPresenter.openMainWindow = { openWindow(id: "main") }
        }
    }

    @ViewBuilder
    private func sectionLabel(for section: JarvisSection) -> some View {
        if section == .jarvis {
            Label {
                Text(section.rawValue)
            } icon: {
                Image("JarvisMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
        } else {
            Label(section.rawValue, systemImage: section.icon)
        }
    }
}

private struct ProjectSidebarRow: View {
    let project: JarvisProject
    let snapshot: GitSnapshot
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(isFocused ? Color.cyan.opacity(0.8) : .secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(snapshot.isRepository ? snapshot.branch : "Not available")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
