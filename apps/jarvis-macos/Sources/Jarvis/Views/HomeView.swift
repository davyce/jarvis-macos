import Charts
import SwiftUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var projectStore
    @State private var isCheckingBuild = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let project = projectStore.focusedProject {
                    let snapshot = projectStore.snapshot(for: project)
                    overview(project: project, snapshot: snapshot)
                    chartGrid(project: project, snapshot: snapshot)
                    buildStatus(project: project)
                    intelligence(snapshot: snapshot, project: project)
                }
            }
            .padding(42)
            .frame(maxWidth: 1280, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func buildStatus(project: JarvisProject) -> some View {
        let build = projectStore.buildSnapshot(for: project)

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("STATUT DU BUILD")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(buildTitle(for: build))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Button {
                    Task {
                        isCheckingBuild = true
                        await projectStore.checkBuild(project)
                        isCheckingBuild = false
                    }
                } label: {
                    Label(isCheckingBuild ? "Verification..." : "Verifier le build", systemImage: "hammer")
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingBuild)
            }

            Divider().overlay(.white.opacity(0.08))

            switch build.state {
            case .unknown:
                Text("Le build n'a pas encore ete verifie pour ce projet.")
                    .foregroundStyle(.secondary)
            case .notDetected:
                Text("Aucun outil de build reconnu (Xcode, npm, cargo, make) dans ce dossier.")
                    .foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verification en cours...")
                        .foregroundStyle(.secondary)
                }
            case .success:
                Label(
                    "Dernier build reussi" + (build.checkedAt.map { " \u{00B7} \($0.formatted(.relative(presentation: .named)))" } ?? ""),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .failed(let detail):
                Label(
                    "Dernier build en echec" + (build.checkedAt.map { " \u{00B7} \($0.formatted(.relative(presentation: .named)))" } ?? ""),
                    systemImage: "xmark.octagon.fill"
                )
                .foregroundStyle(.red)
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .dashboardSurface()
    }

    private func buildTitle(for build: BuildSnapshot) -> String {
        if let tool = build.tool { return tool.label }
        switch build.state {
        case .notDetected: return "Outil non detecte"
        default: return "Pas encore verifie"
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text("JARVIS")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .tracking(2)
                Text("Ton environnement de travail, compris en continu.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                projectStore.refreshAll()
            } label: {
                Label(
                    projectStore.isRefreshing ? "Analyse en cours" : "Actualiser l'espace de travail",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(projectStore.isRefreshing)
        }
    }

    private func overview(project: JarvisProject, snapshot: GitSnapshot) -> some View {
        HStack(spacing: 14) {
            MetricCard(
                title: "FOCUS ACTUEL",
                value: project.name,
                detail: snapshot.isRepository ? snapshot.branch : "Git indisponible",
                symbol: "scope"
            )
            MetricCard(
                title: "MODIFICATIONS",
                value: "\(snapshot.changedFileCount)",
                detail: snapshot.changedFileCount == 0 ? "Arbre de travail propre" : "Fichiers a revoir",
                symbol: "doc.badge.gearshape"
            )
            MetricCard(
                title: "COMMITS 7 JOURS",
                value: "\(snapshot.activityHistory.reduce(0) { $0 + $1.commitCount })",
                detail: "Activite Git locale",
                symbol: "chart.line.uptrend.xyaxis"
            )
            MetricCard(
                title: "DERNIERE ACTIVITE",
                value: relativeDate(snapshot.lastCommitDate),
                detail: snapshot.lastCommitSubject,
                symbol: "clock"
            )
        }
    }

    private func chartGrid(project: JarvisProject, snapshot: GitSnapshot) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PROJECT PULSE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Activite Git de \(project.name)")
                            .font(.title3.weight(.semibold))
                    }
                    Spacer()
                    Text("7 jours")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Chart(snapshot.activityHistory) { point in
                    AreaMark(
                        x: .value("Jour", point.date, unit: .day),
                        y: .value("Commits", point.commitCount)
                    )
                    .foregroundStyle(.cyan.opacity(0.16))

                    LineMark(
                        x: .value("Jour", point.date, unit: .day),
                        y: .value("Commits", point.commitCount)
                    )
                    .foregroundStyle(.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("Jour", point.date, unit: .day),
                        y: .value("Commits", point.commitCount)
                    )
                    .foregroundStyle(.cyan)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 210)
            }
            .dashboardSurface()

            WorkspaceHealthCard()
                .frame(width: 340)
        }
    }

    private func intelligence(snapshot: GitSnapshot, project: JarvisProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SUIVI INTELLIGENT")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Ce qui merite ton attention")
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Image("JarvisMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            }

            Divider().overlay(.white.opacity(0.08))

            InsightRow(
                symbol: snapshot.changedFileCount > 0 ? "exclamationmark.circle" : "checkmark.circle",
                tint: snapshot.changedFileCount > 0 ? .orange : .green,
                title: snapshot.changedFileCount > 0
                    ? "\(snapshot.changedFileCount) fichier\(snapshot.changedFileCount == 1 ? "" : "s") en attente de commit"
                    : "L'arbre de travail est propre",
                detail: snapshot.changedFileCount > 0
                    ? "Jarvis peut ensuite inspecter les changements et preparer une reprise de travail."
                    : "Le prochain signal viendra des nouveaux commits, builds et observations locales."
            )
            InsightRow(
                symbol: "arrow.triangle.branch",
                tint: .cyan,
                title: "Contexte charge : \(project.name) / \(snapshot.branch)",
                detail: "Dernier commit : \(snapshot.lastCommitSubject)"
            )
        }
        .dashboardSurface()
    }

    private func relativeDate(_ date: Date?) -> String {
        guard let date else { return "Inconnue" }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol)
                    .foregroundStyle(.cyan.opacity(0.9))
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .dashboardSurface()
    }
}

private struct WorkspaceHealthCard: View {
    @Environment(ProjectStore.self) private var projectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WORKSPACE HEALTH")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Portefeuille projets")
                .font(.title3.weight(.semibold))

            ForEach(projectStore.projects) { project in
                let snapshot = projectStore.snapshot(for: project)
                HStack(spacing: 10) {
                    Circle()
                        .fill(snapshot.isRepository ? Color.cyan : .secondary.opacity(0.55))
                        .frame(width: 8, height: 8)
                    Text(project.name)
                    Spacer()
                    Text(snapshot.isRepository ? healthLabel(snapshot) : "En attente")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: healthValue(snapshot))
                    .tint(snapshot.changedFileCount > 0 ? .orange : .cyan)
            }
        }
        .dashboardSurface()
    }

    private func healthLabel(_ snapshot: GitSnapshot) -> String {
        snapshot.changedFileCount == 0 ? "Stable" : "A revoir"
    }

    private func healthValue(_ snapshot: GitSnapshot) -> Double {
        guard snapshot.isRepository else { return 0.08 }
        return snapshot.changedFileCount == 0 ? 0.92 : 0.58
    }
}

private struct InsightRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    func dashboardSurface() -> some View {
        padding(22)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
    }
}
