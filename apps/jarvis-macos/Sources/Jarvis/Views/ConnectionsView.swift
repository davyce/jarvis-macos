import SwiftUI
import UniformTypeIdentifiers

struct ConnectionsView: View {
    @Environment(ProjectStore.self) private var projectStore
    @State private var mail = LimuleMailService()
    @State private var limuleKey = ""
    @State private var limuleConnected = LimuleAPIService.hasKey
    @State private var limuleIsLoading = false
    @State private var limuleError: String?
    @State private var isImportingGoogleConfiguration = false
    @State private var githubToken = ""
    @State private var user: GitHubService.User?
    @State private var repositories: [GitHubService.Repository] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var didRequestAutomaticGmailConnection = false
    @State private var clapError: String?
    @State private var systemActionRefreshToken = 0
    @State private var limuleBridgeRefreshToken = 0
    @State private var fileActionRefreshToken = 0
    @State private var elevenLabsKey = ""
    @State private var elevenLabsConnected = ElevenLabsService.hasKey
    @State private var elevenLabsIsLoading = false
    @State private var elevenLabsError: String?
    @State private var elevenLabsVoices: [ElevenLabsService.Voice] = []
    @State private var isLoadingVoices = false
    /// Suivi used to dump up to 30 entries flat -- scrolling past it to
    /// reach ElevenLabs/Limule/GitHub below took many scrolls once real
    /// usage accumulated history. Reveals 10 at a time instead.
    @State private var auditVisibleCount = 10
    @State private var preferencesNotes = UserPreferencesStore.notes
    @State private var memoryRefreshToken = 0

    var body: some View {
        Form {
            Section("Preferences") {
                Text("Notes libres sur ta maniere de travailler avec Jarvis -- style de reponse, decisions valables sur la duree, choses a ne pas repeter. Incluses dans chaque conversation avec le cerveau Limule tant qu'elles restent ecrites ici.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $preferencesNotes)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .onChange(of: preferencesNotes) {
                        UserPreferencesStore.setNotes(preferencesNotes)
                    }
            }
            if let project = projectStore.focusedProject {
                let _ = memoryRefreshToken
                let memory = ProjectMemoryStore.memory(for: project)
                Section("Memoire de travail - \(project.name)") {
                    Text("Contexte conserve localement entre les conversations et fourni au cerveau Limule pour ce projet.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !memory.lastUserRequest.isEmpty {
                        LabeledContent("Derniere demande") {
                            Text(memory.lastUserRequest).lineLimit(3).multilineTextAlignment(.trailing)
                        }
                    }
                    if !memory.lastJarvisReply.isEmpty {
                        LabeledContent("Derniere reponse") {
                            Text(memory.lastJarvisReply).lineLimit(3).multilineTextAlignment(.trailing)
                        }
                    }
                    if !memory.recentDecisions.isEmpty {
                        Text("Decisions recentes")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(memory.recentDecisions, id: \.self) { decision in
                            Text(decision).font(.caption)
                        }
                    }
                    Button("Effacer la memoire de \(project.name)", role: .destructive) {
                        ProjectMemoryStore.clear(projectID: project.id)
                        memoryRefreshToken += 1
                    }
                }
            }
            Section("Actions systeme (Bridge)") {
                Text("Actions reelles sur le Mac (clic, frappe clavier, mise au premier plan) via l'API Accessibilite macOS. Desactivees par defaut ; chacune demande une confirmation explicite avant sa toute premiere execution.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Permission Accessibilite") {
                    if AccessibilityPermission.isTrusted {
                        Text("Accordee").foregroundStyle(.green)
                    } else {
                        Button("Ouvrir Reglages Systeme") {
                            AccessibilityPermission.requestIfNeeded()
                            AccessibilityPermission.openSystemSettings()
                        }
                    }
                }

                ForEach(SystemActionCapability.allCases) { capability in
                    Toggle(
                        capability.title,
                        isOn: Binding(
                            get: { SystemActionPermissionStore.shared.isEnabled(capability) },
                            set: { enabled in
                                SystemActionPermissionStore.shared.setEnabled(enabled, for: capability)
                                systemActionRefreshToken += 1
                            }
                        )
                    )
                    Text(capability.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("LIMULE Bridge") {
                Text("Controle direct de ce Mac (clic, clavier, fichiers, navigateur, messages) via le serveur local de l'app LIMULE. Aucune confirmation par action -- desactive par defaut, et chaque appel est journalise dans le Suivi ci-dessous, reussi ou non.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Disponibilite") {
                    if LimuleBridgeAuthentication.token() != nil {
                        Text("Jeton trouve").foregroundStyle(.green)
                    } else {
                        Text("Jeton introuvable -- lance l'app LIMULE au moins une fois sur ce Mac")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(
                    "Activer LIMULE Bridge",
                    isOn: Binding(
                        get: { LimuleBridgeSettings.isEnabled },
                        set: { enabled in
                            LimuleBridgeSettings.setEnabled(enabled)
                            limuleBridgeRefreshToken += 1
                        }
                    )
                )
            }
            Section("Actions fichiers") {
                Text("Recherche, lecture et modification de fichiers n'importe ou sur le Mac (nom et contenu). Recherche/lecture toujours libres ; modifier/dupliquer/supprimer/deplacer sont desactives par defaut et demandent une confirmation avant leur toute premiere execution.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(FileActionCapability.allCases) { capability in
                    Toggle(
                        capability.title,
                        isOn: Binding(
                            get: { FileActionPermissionStore.shared.isEnabled(capability) },
                            set: { enabled in
                                FileActionPermissionStore.shared.setEnabled(enabled, for: capability)
                                fileActionRefreshToken += 1
                            }
                        )
                    )
                    Text(capability.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Suivi") {
                let entries = AuditTrailEntry.loadAll(limit: 200)
                if entries.isEmpty {
                    Text("Aucune action systeme, LIMULE Bridge ou fichier executee pour l'instant.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(entries.prefix(auditVisibleCount)) { entry in
                        AuditTrailRow(entry: entry)
                    }
                    if entries.count > auditVisibleCount {
                        Button("Voir plus (\(entries.count - auditVisibleCount) restants)") {
                            auditVisibleCount += 10
                        }
                        .font(.caption)
                    }
                }
            }
            .id("\(systemActionRefreshToken)-\(limuleBridgeRefreshToken)-\(fileActionRefreshToken)")
            Section("Presence") {
                Toggle(
                    "Ecoute active (clap)",
                    isOn: Binding(
                        get: { projectStore.isListening },
                        set: { handleClapToggle($0) }
                    )
                )
                Text("Quand l'ecoute est active, Jarvis apparait dans la barre de menus et analyse localement le niveau sonore du micro pour detecter deux claps rapproches et se remettre au premier plan. Aucun son n'est enregistre ni transmis. La commande vocale (ElevenLabs, ci-dessous) est independante : elle se declenche via le bouton micro dans la conversation, et ne partage avec cette ecoute que la permission microphone macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                if let clapError { Text(clapError).font(.caption).foregroundStyle(.red) }
            }
            Section("ElevenLabs (voix)") {
                if elevenLabsConnected {
                    LabeledContent("ElevenLabs") {
                        Text("Connecte").foregroundStyle(.green)
                    }
                    if let preview = ElevenLabsService.keyPreview {
                        LabeledContent("Cle") { Text(preview).font(.system(.body, design: .monospaced)) }
                    }
                    if elevenLabsVoices.isEmpty {
                        Button("Charger les voix") { Task { await loadVoices() } }
                            .disabled(isLoadingVoices)
                    } else {
                        HStack {
                            Picker("Voix", selection: Binding(
                                get: { ElevenLabsService.selectedVoiceID ?? "" },
                                set: { ElevenLabsService.selectedVoiceID = $0.isEmpty ? nil : $0 }
                            )) {
                                Text("Aucune").tag("")
                                ForEach(elevenLabsVoices) { voice in
                                    Text(voice.name).tag(voice.voiceID)
                                }
                            }
                            Button {
                                Task { await loadVoices() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingVoices)
                            .help("Actualiser la liste des voix (ex. apres en avoir ajoute une depuis la Bibliotheque de voix ElevenLabs)")
                        }
                    }
                    Text("Jarvis lit sa reponse a voix haute uniquement quand la question a ete posee au micro (jamais pour un message tape).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Deconnecter ElevenLabs", role: .destructive) {
                        ElevenLabsService.disconnect()
                        elevenLabsConnected = false
                        elevenLabsVoices = []
                    }
                } else {
                    Text("Cle API ElevenLabs pour la transcription (STT) des commandes vocales et la lecture (TTS) des reponses de Jarvis.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("sk_...", text: $elevenLabsKey)
                    Link("Gerer mes cles sur ElevenLabs", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                    Button("Connecter ElevenLabs") { Task { await connectElevenLabs() } }
                        .disabled(elevenLabsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || elevenLabsIsLoading)
                }
                if let elevenLabsError { Text(elevenLabsError).font(.caption).foregroundStyle(.red) }
            }
            Section("Limule API") {
                if limuleConnected {
                    LabeledContent("Cerveau Limule") {
                        Text("Connecte").foregroundStyle(.green)
                    }
                    if let preview = LimuleAPIService.keyPreview {
                        LabeledContent("Cle") { Text(preview).font(.system(.body, design: .monospaced)) }
                    }
                    Text("Jarvis utilise cette cle pour les demandes intelligentes envoyees a l'API Limule.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Deconnecter Limule", role: .destructive) {
                        LimuleAPIService.disconnect()
                        limuleConnected = false
                    }
                } else {
                    Text("Une seule cle API Limule est necessaire. Elle reste dans le Trousseau macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("lim_...", text: $limuleKey)
                    Link("Gerer mes cles sur Limule", destination: URL(string: "https://www.limuleia.com/login")!)
                    Button("Connecter Limule") { Task { await connectLimule() } }
                        .disabled(!limuleKey.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("lim_") || limuleIsLoading)
                }
                if let limuleError { Text(limuleError).font(.caption).foregroundStyle(.red) }
            }
            Section("Synchronisation") {
                LabeledContent("Etat") { syncStatusView }
                if case .synced(let at) = projectStore.syncState {
                    LabeledContent("Derniere synchro") {
                        Text(Self.relativeFormatter.localizedString(for: at, relativeTo: .now))
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Synchroniser maintenant") { Task { await projectStore.syncNow() } }
                    .disabled(!limuleConnected || projectStore.syncState == .syncing)
                Text("Historique de conversation et liste de projets partages entre tes machines via ton compte Limule. Les reglages et les permissions Bridge restent locaux a chaque machine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mail") {
                if let email = mail.email {
                    LabeledContent("Compte Google") { Text(email).foregroundStyle(.green) }
                    LabeledContent("Gmail") {
                        Text(mail.gmailConnected ? "Connected" : "Not connected")
                            .foregroundStyle(mail.gmailConnected ? .green : .secondary)
                    }
                    if let estimate = mail.inboxEstimate {
                        LabeledContent("Messages accessibles") { Text("\(estimate)") }
                    }
                    if mail.gmailConnected {
                        Button {
                            Task { await mail.refreshGmail() }
                        } label: {
                            Label("Actualiser Gmail", systemImage: "arrow.clockwise")
                        }
                        .disabled(mail.isLoading)
                        Button("Disconnect Gmail", role: .destructive) { Task { await mail.disconnectGmail() } }
                    } else {
                        Text("Jarvis can read, search, and prepare emails only after you approve Google access.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Connect Gmail") { Task { await mail.connectGmail() } }
                            .disabled(mail.isLoading)
                    }
                } else {
                    Text("Connexion directe entre Jarvis et Google. Les jetons restent dans le Trousseau macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !mail.hasClientID {
                        Button("Importer la configuration Google") {
                            isImportingGoogleConfiguration = true
                        }
                        Link("Ouvrir les clients OAuth Google", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
                    } else if let projectID = mail.googleProjectID {
                        LabeledContent("Projet Google Cloud") { Text(projectID).foregroundStyle(.green) }
                    }
                    Button("Continuer avec Google") {
                        Task { await mail.connectGmail() }
                    }
                    .disabled(mail.isLoading || !mail.hasClientID)
                }
                if let error = mail.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("GitHub") {
                if let user {
                    LabeledContent("Connected account") { Text(user.login).foregroundStyle(.green) }
                    Button("Refresh repositories") { Task { await refresh() } }
                    Button("Disconnect GitHub", role: .destructive) {
                        GitHubService.disconnect()
                        self.user = nil
                        repositories = []
                    }
                } else {
                    Text("Paste a fine-grained personal access token. Jarvis verifies it before saving it in the macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("github_pat_...", text: $githubToken)
                    Link("Create a fine-grained token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    Button("Connect GitHub") { Task { await connect() } }
                        .disabled(githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if !repositories.isEmpty {
                Section("Tous les depots accessibles (\(repositories.count))") {
                    ForEach(repositories) { repository in
                        Link(destination: repository.html_url) {
                            HStack {
                                Text(repository.full_name)
                                Spacer()
                                Text(repository.private ? "Private" : "Public").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Les depots publics sont tous charges. Un depot prive apparait seulement si le token GitHub lui donne acces.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connections")
        .fileImporter(
            isPresented: $isImportingGoogleConfiguration,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                _ = try mail.importGoogleConfiguration(Data(contentsOf: url))
            } catch {
                mail.errorMessage = error.localizedDescription
            }
        }
        .task {
            await restore()
            await mail.restore()
            if elevenLabsConnected { await loadVoices() }
            if ProcessInfo.processInfo.arguments.contains("--connect-gmail"),
               !mail.gmailConnected,
               !didRequestAutomaticGmailConnection {
                didRequestAutomaticGmailConnection = true
                await mail.connectGmail()
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    @ViewBuilder
    private var syncStatusView: some View {
        switch projectStore.syncState {
        case .idle:
            Text("Pas encore synchronise").foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Synchronisation...")
            }
            .foregroundStyle(.secondary)
        case .synced:
            Text("Synchronise").foregroundStyle(.green)
        case .unavailable(let reason):
            Text(reason).foregroundStyle(.secondary)
        }
    }

    private func handleClapToggle(_ enabled: Bool) {
        Task {
            clapError = await projectStore.setListening(enabled)
        }
    }

    private func connectLimule() async {
        limuleIsLoading = true
        defer { limuleIsLoading = false }
        do {
            try await LimuleAPIService.connect(apiKey: limuleKey)
            limuleKey = ""
            limuleConnected = true
            limuleError = nil
        } catch {
            limuleError = error.localizedDescription
        }
    }

    private func restore() async {
        guard GitHubService.hasToken else { return }
        await refresh()
    }

    private func connectElevenLabs() async {
        elevenLabsIsLoading = true
        defer { elevenLabsIsLoading = false }
        do {
            try await ElevenLabsService.connect(apiKey: elevenLabsKey)
            elevenLabsKey = ""
            elevenLabsConnected = true
            elevenLabsError = nil
            await loadVoices()
        } catch {
            elevenLabsError = error.localizedDescription
        }
    }

    private func loadVoices() async {
        isLoadingVoices = true
        defer { isLoadingVoices = false }
        do {
            elevenLabsVoices = try await ElevenLabsService.listVoices()
        } catch {
            elevenLabsError = error.localizedDescription
        }
    }

    private func connect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            user = try await GitHubService.connect(token: githubToken)
            githubToken = ""
            repositories = try await GitHubService.repositories()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            user = try await GitHubService.currentUser()
            repositories = try await GitHubService.repositories()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct AuditTrailRow: View {
    let entry: AuditTrailEntry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter
    }()

    private var outcomeColor: Color {
        if entry.wasDeclined { return .secondary }
        return entry.succeeded ? .green : .red
    }

    private var outcomeLabel: String {
        if entry.wasDeclined { return "Refuse" }
        return entry.succeeded ? "Reussi" : "Echec"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.formatter.string(from: entry.createdAt))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.origin)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    Text(entry.title).font(.caption.weight(.medium))
                }
                Text(entry.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(outcomeLabel).font(.caption2.weight(.semibold)).foregroundStyle(outcomeColor)
        }
        .padding(.vertical, 2)
    }
}
