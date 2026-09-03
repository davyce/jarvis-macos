import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class ProjectStore {
    private static let projectsKey = "jarvis.projects.v1"
    private static let focusKey = "jarvis.focus.v1"
    private static let activeConversationKey = "jarvis.activeConversation.v1"
    private static let lastSyncedAtKey = "jarvis.sync.lastSyncedAt.v1"
    private static let workspaceItemsKey = "jarvis.workspace.items.v1"

    var projects: [JarvisProject]
    var focusedProjectID: String
    /// Files/folders explicitly connected to the conversation (dropped onto
    /// the composer), independent of the focused project. See
    /// `WorkspaceItem`.
    var workspaceItems: [WorkspaceItem] = []
    var snapshots: [String: GitSnapshot] = [:]
    var buildSnapshots: [String: BuildSnapshot] = [:]
    var recentFilesByProject: [String: [RecentFileEntry]] = [:]
    var isRefreshing = false
    var commandHistory: [CommandEntry] = []
    var conversations: [Conversation] = []
    var activeConversationID: String = ""
    var isListening = false
    var syncState: WorkspaceSyncState = .idle
    var voiceSessionState: VoiceSessionState = .idle
    var voiceError: String?
    /// Monotonic event consumed by `JarvisCommandView` to start hands-free
    /// listening after a clap greeting. A counter cannot lose two closely
    /// spaced events the way a Bool that is immediately reset can.
    var clapConversationRequestID = 0

    private var projectWatcher: ProjectWatcher?
    private var isClapGreetingInFlight = false

    init() {
        let decodedProjects = UserDefaults.standard.data(forKey: Self.projectsKey)
            .flatMap { try? JSONDecoder().decode([JarvisProject].self, from: $0) }

        projects = (decodedProjects ?? JarvisProject.initialProjects)
            .sorted { $0.order < $1.order }
        focusedProjectID = UserDefaults.standard.string(forKey: Self.focusKey) ?? "limule"

        if !projects.contains(where: { $0.id == focusedProjectID }) {
            focusedProjectID = projects.first?.id ?? "limule"
        }
        workspaceItems = UserDefaults.standard.data(forKey: Self.workspaceItemsKey)
            .flatMap { try? JSONDecoder().decode([WorkspaceItem].self, from: $0) } ?? []

        conversations = LocalDatabase.shared.loadConversations()
        if conversations.isEmpty {
            let conversation = Conversation.started()
            LocalDatabase.shared.createConversation(conversation)
            conversations = [conversation]
        }
        activeConversationID = UserDefaults.standard.string(forKey: Self.activeConversationKey) ?? conversations[0].id
        if !conversations.contains(where: { $0.id == activeConversationID }) {
            activeConversationID = conversations[0].id
        }
        commandHistory = LocalDatabase.shared.loadHistory(conversationID: activeConversationID)
        isListening = ClapDetector.shared.isListening
        let lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncedAtKey) as? Double
        syncState = lastSyncedAt.map { .synced(at: Date(timeIntervalSince1970: $0)) } ?? .idle

        persist()
        JarvisNotifier.requestAuthorizationIfNeeded()
        // A double-clap used to only raise the window
        // (`ClapDetector.bringJarvisToFront`); wiring a real greeting here
        // is what makes it feel like the ambient trigger it's meant to be,
        // per Davy's "comme le Jarvis dans Marvel" ask. Set before
        // `bootstrapIfEnabled()` so it's live from the very first clap if
        // listening is already on at launch.
        ClapDetector.shared.onDoubleClap = { [weak self] in
            Task { @MainActor in
                WindowPresenter.presentMainWindow()
                await self?.greetFromClap()
            }
        }
        ClapDetector.bootstrapIfEnabled()
        isListening = ClapDetector.shared.isListening
        Task { refreshAll() }
        if let initial = projects.first(where: { $0.id == focusedProjectID }) {
            Task { await checkBuild(initial) }
            startWatching(initial)
        }
        // Local state is already loaded and rendered above; the cloud pull
        // only layers in asynchronously afterward, never blocking launch.
        Task { await pullAndMergeFromCloud() }
    }

    var focusedProject: JarvisProject? {
        projects.first { $0.id == focusedProjectID }
    }

    func snapshot(for project: JarvisProject) -> GitSnapshot {
        snapshots[project.id] ?? .unavailable()
    }

    func buildSnapshot(for project: JarvisProject) -> BuildSnapshot {
        buildSnapshots[project.id] ?? .unknown
    }

    func recentFiles(for project: JarvisProject) -> [RecentFileEntry] {
        recentFilesByProject[project.id] ?? []
    }

    func appendCommandEntry(_ entry: CommandEntry) {
        commandHistory.append(entry)
        LocalDatabase.shared.insert(entry, conversationID: activeConversationID)
        if let project = focusedProject {
            ProjectMemoryStore.record(entry, for: project)
        }
        LocalDatabase.shared.touchConversation(activeConversationID, updatedAt: entry.createdAt)

        guard let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        conversations[index].updatedAt = entry.createdAt
        if entry.role == .user, conversations[index].title == Conversation.defaultTitle {
            let title = String(entry.text.prefix(48))
            conversations[index].title = title
            LocalDatabase.shared.renameConversation(activeConversationID, title: title)
        }
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)
        pushConversation(activeConversationID)
    }

    /// Starts a fresh, empty thread; the previous one stays in `conversations`
    /// so the user can switch back to it via `switchConversation`.
    func startNewConversation() {
        let conversation = Conversation.started()
        LocalDatabase.shared.createConversation(conversation)
        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        UserDefaults.standard.set(conversation.id, forKey: Self.activeConversationKey)
        commandHistory = []
    }

    func switchConversation(_ id: String) {
        guard id != activeConversationID, conversations.contains(where: { $0.id == id }) else { return }
        activeConversationID = id
        UserDefaults.standard.set(id, forKey: Self.activeConversationKey)
        commandHistory = LocalDatabase.shared.loadHistory(conversationID: id)
    }

    /// Permanently deletes a conversation and its messages. If it was the
    /// active one, switches to whichever conversation is now most recently
    /// updated, or starts a fresh one if none remain -- the app should
    /// never end up with zero conversations to show.
    func deleteConversation(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        LocalDatabase.shared.deleteConversation(id)
        conversations.remove(at: index)

        guard id == activeConversationID else { return }
        if let next = conversations.first {
            activeConversationID = next.id
            UserDefaults.standard.set(next.id, forKey: Self.activeConversationKey)
            commandHistory = LocalDatabase.shared.loadHistory(conversationID: next.id)
        } else {
            startNewConversation()
        }
    }

    /// Bounds how much of the active conversation is sent to the LLM: the
    /// most recent messages up to a character budget (a rough token proxy)
    /// rather than the full history, so long threads don't blow up the
    /// request or get silently truncated by the server.
    func contextWindow(characterBudget: Int = 12_000) -> [CommandEntry] {
        var used = 0
        var result: [CommandEntry] = []
        for entry in commandHistory.reversed() {
            used += entry.text.count
            if used > characterBudget, !result.isEmpty { break }
            result.append(entry)
        }
        return result.reversed()
    }

    /// Rejects accidental canned loops from the remote model while allowing
    /// normal short confirmations to remain short. The comparison is only a
    /// guard rail; it never rewrites a response on its own.
    func resemblesRecentJarvisReply(_ candidate: String) -> Bool {
        let normalizedCandidate = Self.normalizedReply(candidate)
        guard normalizedCandidate.count >= 80 else { return false }
        return commandHistory
            .filter { $0.role == .jarvis }
            .suffix(4)
            .contains { entry in
                let previous = Self.normalizedReply(entry.text)
                guard previous.count >= 80 else { return false }
                return normalizedCandidate == previous
                    || normalizedCandidate.hasPrefix(previous)
                    || previous.hasPrefix(normalizedCandidate)
            }
    }

    private static func normalizedReply(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    func checkBuild(_ project: JarvisProject) async {
        let previousState = buildSnapshots[project.id]?.state
        buildSnapshots[project.id] = BuildSnapshot(
            tool: buildSnapshots[project.id]?.tool,
            state: .running,
            checkedAt: nil
        )

        guard let tool = BuildInspector.detectTool(projectPath: project.rootPath) else {
            buildSnapshots[project.id] = BuildSnapshot(tool: nil, state: .notDetected, checkedAt: .now)
            return
        }

        let result = await BuildInspector.run(projectPath: project.rootPath, tool: tool)
        buildSnapshots[project.id] = result

        if shouldNotify(previous: previousState, current: result.state) {
            JarvisNotifier.notifyBuildResult(project: project, snapshot: result)
        }
    }

    private func shouldNotify(previous: BuildSnapshot.State?, current: BuildSnapshot.State) -> Bool {
        switch (previous, current) {
        case (.success, .failed), (.failed, .success):
            return true
        case (nil, .failed), (.unknown, .failed), (.notDetected, .failed):
            return true
        default:
            return false
        }
    }

    /// Central "listening" control: gates the microphone-based clap detector.
    /// Deliberately NOT reused for voice commands (see `voiceSessionState`) --
    /// clap detection is an always-on ambient trigger, a voice session is a
    /// short, user-initiated recording with a different lifecycle. They only
    /// share the underlying mic-permission dependency, via `MicrophonePermission`.
    func setListening(_ enabled: Bool) async -> String? {
        guard enabled else {
            ClapDetector.shared.stop()
            UserDefaults.standard.set(false, forKey: ClapDetector.enabledDefaultsKey)
            isListening = false
            return nil
        }

        let granted = await ClapDetector.requestAccessIfNeeded()
        guard granted else {
            UserDefaults.standard.set(false, forKey: ClapDetector.enabledDefaultsKey)
            isListening = false
            return "Acces micro refuse. Autorise Jarvis dans Reglages Systeme > Confidentialite et securite > Microphone."
        }

        do {
            try ClapDetector.shared.start()
            UserDefaults.standard.set(true, forKey: ClapDetector.enabledDefaultsKey)
            isListening = true
            return nil
        } catch {
            isListening = false
            return "Impossible de demarrer l'ecoute : \(error.localizedDescription)"
        }
    }

    // MARK: - Clap greeting

    /// Reacts to a double-clap by having Jarvis actually say something --
    /// a short, time-of-day-appropriate greeting appended to the
    /// conversation and spoken aloud when TTS is configured (a no-op audio
    /// wise, same as `speak`, if ElevenLabs isn't connected -- the text
    /// still lands either way). A no-op entirely while a voice
    /// session/reply is already in flight, so a clap can't interrupt or
    /// pile onto that.
    func greetFromClap() async {
        guard voiceSessionState == .idle, !isClapGreetingInFlight else { return }
        isClapGreetingInFlight = true
        defer { isClapGreetingInFlight = false }
        let text = clapGreeting()
        appendCommandEntry(CommandEntry(role: .jarvis, text: text, detail: "Salutation (double-clap)"))
        await speak(text)
        // A clap is meant to open a real back-and-forth, not just trigger a
        // one-off spoken greeting -- "comme le Jarvis dans Marvel" means the
        // mic should already be listening the instant the greeting ends, no
        // extra click. `JarvisCommandView` owns hands-free conversation
        // mode's actual loop/state (mirroring how it, not this store, owns
        // `send()`'s trigger dispatch); this just signals it to start,
        // consumed and reset immediately via `.onChange`.
        clapConversationRequestID += 1
    }

    /// Two sentences, a touch of dry warmth, and -- when there's a focused
    /// project to mention -- proof it actually knows what's going on,
    /// rather than a generic bot greeting. Modeled on the tone of the
    /// Marvel J.A.R.V.I.S. (calm, capable, quietly attentive) rather than
    /// its content -- the mentions stay to things this app can genuinely
    /// see (the focused project), not invented sci-fi capability.
    private func clapGreeting() -> String {
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "chef"
        let projectName = projects.first(where: { $0.id == focusedProjectID })?.name
        let hour = Calendar.current.component(.hour, from: Date())
        var variants: [String]
        switch hour {
        case 5..<12:
            variants = [
                "Bonjour \(firstName). J'espere que la nuit a ete bonne -- de mon cote, tout est calme et pret a reprendre exactement la ou on s'etait arretes.",
                "Bien le bonjour, \(firstName). Aucune alerte a signaler cette nuit, systemes en ordre -- je n'attendais plus que toi pour commencer la journee."
            ]
            if let projectName {
                variants.append("Bonjour \(firstName). Je gardais un oeil sur \(projectName) en t'attendant -- dis-moi si on reprend la-dessus ou si on part sur autre chose.")
            }
        case 12..<18:
            variants = [
                "Bonjour \(firstName). L'apres-midi avance, et je suis toujours la, disponible des que tu veux qu'on avance sur quelque chose.",
                "Content de te revoir, \(firstName). A ton service comme toujours -- dis-moi simplement ce qu'il te faut et on s'y met."
            ]
            if let projectName {
                variants.append("Bonjour \(firstName). \(projectName) est toujours sous les yeux si tu veux qu'on y jette un oeil ensemble -- sinon, je t'ecoute pour autre chose.")
            }
        case 18..<22:
            variants = [
                "Bonsoir \(firstName). La journee a du etre longue -- je reste disponible aussi longtemps qu'il le faudra si tu as encore besoin de moi.",
                "Bonsoir \(firstName), toujours dans les parages. Dis-moi ce qui te ferait plaisir ce soir, je m'en occupe."
            ]
            if let projectName {
                variants.append("Bonsoir \(firstName). On peut clore la journee sur \(projectName) si tu veux, ou tu preferes qu'on souffle un peu -- comme tu le sens.")
            }
        default:
            variants = [
                "\(firstName), encore debout a cette heure ? Aucun souci, je reste eveille avec toi -- dis-moi ce dont tu as besoin.",
                "Bonsoir \(firstName). La nuit est calme de mon cote -- je suis la si quelque chose te tracasse et t'empeche de dormir."
            ]
        }
        return variants.randomElement() ?? variants[0]
    }

    // MARK: - Voice pipeline (ElevenLabs)

    /// Starts recording a spoken command. Failures (mic permission denied,
    /// engine setup) surface via `voiceError` and leave the session `.idle`
    /// -- never stuck.
    func startVoiceRecording() async {
        guard voiceSessionState == .idle else { return }
        voiceError = nil
        do {
            try await VoiceRecorder.shared.start()
            voiceSessionState = .recording
        } catch {
            voiceSessionState = .idle
            voiceError = Self.voiceErrorMessage(error)
        }
    }

    /// Stops recording and transcribes it via ElevenLabs STT. Returns the
    /// transcript on success so the caller can fill the composer with it for
    /// review (per the "user validates before sending" decision) -- never
    /// sends anything itself. Returns `nil` on any failure; the session
    /// always ends back at `.idle` either way.
    func stopVoiceRecordingAndTranscribe() async -> String? {
        guard voiceSessionState == .recording else {
            voiceSessionState = .idle
            return nil
        }
        guard let url = VoiceRecorder.shared.stop() else {
            voiceSessionState = .idle
            if let message = VoiceRecorder.shared.consumeFinalizationError() {
                voiceError = "Impossible de finaliser l'enregistrement : \(message)"
            }
            return nil
        }
        voiceSessionState = .transcribing
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let transcript = try await ElevenLabsService.transcribe(audioFileURL: url)
            voiceSessionState = .idle
            return transcript
        } catch {
            voiceSessionState = .idle
            voiceError = Self.voiceErrorMessage(error)
            return nil
        }
    }

    /// Records and transcribes one utterance with silence-based auto-stop
    /// (see `VoiceRecorder.recordUntilSilence`) -- for hands-free
    /// conversation mode's turn loop. Unlike
    /// `stopVoiceRecordingAndTranscribe`, the caller never clicks again to
    /// end the turn; silence itself does. Returns `nil` on any failure or
    /// if nothing was ever said, same as that function; the session always
    /// ends back at `.idle` either way.
    func listenForOneTurn() async -> String? {
        guard voiceSessionState == .idle else { return nil }
        voiceError = nil
        voiceSessionState = .recording
        let url: URL?
        do {
            url = try await VoiceRecorder.shared.recordUntilSilence()
        } catch {
            voiceSessionState = .idle
            voiceError = Self.voiceErrorMessage(error)
            return nil
        }
        guard let url else {
            voiceSessionState = .idle
            if let message = VoiceRecorder.shared.consumeFinalizationError() {
                voiceError = "Impossible de finaliser l'enregistrement : \(message)"
            }
            return nil
        }
        voiceSessionState = .transcribing
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let transcript = try await ElevenLabsService.transcribe(audioFileURL: url)
            voiceSessionState = .idle
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : transcript
        } catch {
            voiceSessionState = .idle
            voiceError = Self.voiceErrorMessage(error)
            return nil
        }
    }

    /// Speaks `text` aloud via ElevenLabs TTS. A no-op if ElevenLabs isn't
    /// connected or no voice is selected in Connexions -- speaking a reply
    /// is always an enhancement, never something the rest of the app
    /// depends on.
    func speak(_ text: String) async {
        guard voiceSessionState == .idle,
              ElevenLabsService.hasKey,
              let voiceID = ElevenLabsService.selectedVoiceID else { return }
        do {
            // A reply must be synthesized as one coherent utterance. Splitting
            // a conversation into independent clips resets the voice's prosody
            // on every sentence and makes Jarvis sound mechanical.
            let audio = try await ElevenLabsService.synthesize(text: text, voiceID: voiceID)
            guard voiceSessionState == .idle else { return }
            voiceSessionState = .speaking
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try VoicePlayback.shared.play(audio) { continuation.resume() }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if voiceSessionState == .speaking {
                voiceSessionState = .idle
            }
        } catch {
            if voiceSessionState == .speaking {
                voiceSessionState = .idle
            }
            voiceError = Self.voiceErrorMessage(error)
        }
    }

    /// Interrupts an in-progress `speak(_:)` call. `VoicePlayback.stop()`
    /// resumes that call's suspended continuation itself (see its doc
    /// comment), which is what actually resets `voiceSessionState` back to
    /// `.idle` -- this just triggers that, and is a no-op when nothing is
    /// playing.
    func stopSpeaking() {
        voiceSessionState = .idle
        VoicePlayback.shared.stop()
    }

    /// Cancels an in-progress `listenForOneTurn()` mid-recording -- used
    /// when the user explicitly stops hands-free conversation mode while
    /// still actively listening. A no-op otherwise.
    func cancelListening() {
        VoiceRecorder.shared.cancelListening()
    }

    private static func voiceErrorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func focus(_ project: JarvisProject) {
        focusedProjectID = project.id
        UserDefaults.standard.set(project.id, forKey: Self.focusKey)
        refresh(project)
        if buildSnapshots[project.id] == nil {
            Task { await checkBuild(project) }
        }
        startWatching(project)
    }

    /// A project name embedded in a normal request is a useful context cue,
    /// but only switch when it is unambiguous. This avoids the old behaviour
    /// where a comparison merely mentioning ZOLA could unexpectedly steal
    /// focus from the active project.
    @discardableResult
    func adoptProjectMentioned(in request: String) -> JarvisProject? {
        let normalized = request.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let candidates = projects.filter { project in
            let name = project.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return normalized.contains("pour \(name)")
                || normalized.contains("dans \(name)")
                || normalized.contains("sur \(name)")
                || normalized.hasPrefix("\(name) ")
        }
        guard candidates.count == 1, let project = candidates.first, project.id != focusedProjectID else { return nil }
        focus(project)
        return project
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Ajouter"
        panel.message = "Choisir un dossier que Jarvis peut observer"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSource(url: url, sourceType: .folder)
    }

    func chooseDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ajouter"
        panel.message = "Choisir un document que Jarvis peut lire"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSource(url: url, sourceType: .document)
    }

    func remove(_ project: JarvisProject) {
        guard !JarvisProject.initialProjects.contains(where: { $0.id == project.id }) else { return }
        projects.removeAll { $0.id == project.id }
        if focusedProjectID == project.id {
            focusedProjectID = projects.first?.id ?? ""
            UserDefaults.standard.set(focusedProjectID, forKey: Self.focusKey)
        }
        snapshots.removeValue(forKey: project.id)
        buildSnapshots.removeValue(forKey: project.id)
        recentFilesByProject.removeValue(forKey: project.id)
        persist()
        deleteProjectRemote(project.id)
    }

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            await withTaskGroup(of: (String, GitSnapshot).self) { group in
                for project in projects {
                    group.addTask(priority: .utility) {
                        (project.id, GitInspector.inspect(projectPath: project.rootPath))
                    }
                }
                for await (id, snapshot) in group {
                    snapshots[id] = snapshot
                }
            }
            await withTaskGroup(of: (String, [RecentFileEntry]).self) { group in
                for project in projects {
                    group.addTask(priority: .utility) {
                        (project.id, RecentFilesInspector.recentFiles(in: project.rootPath))
                    }
                }
                for await (id, files) in group {
                    recentFilesByProject[id] = files
                }
            }
            isRefreshing = false
        }
    }

    func refresh(_ project: JarvisProject) {
        Task { await refreshSnapshot(for: project) }
        Task { await refreshRecentFiles(for: project) }
    }

    private func refreshSnapshot(for project: JarvisProject) async {
        let path = project.rootPath
        let snapshot = await Task.detached(priority: .utility) {
            GitInspector.inspect(projectPath: path)
        }.value
        snapshots[project.id] = snapshot
    }

    private func refreshRecentFiles(for project: JarvisProject) async {
        let path = project.rootPath
        let files = await Task.detached(priority: .utility) {
            RecentFilesInspector.recentFiles(in: path)
        }.value
        recentFilesByProject[project.id] = files
    }

    private func startWatching(_ project: JarvisProject) {
        projectWatcher?.stop()
        guard FileManager.default.fileExists(atPath: project.rootPath) else {
            projectWatcher = nil
            return
        }
        let watcher = ProjectWatcher(path: project.rootPath) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let current = self.focusedProject, current.id == project.id else { return }
                self.refresh(current)
            }
        }
        watcher.start()
        projectWatcher = watcher
    }

    private func addSource(url: URL, sourceType: JarvisProject.SourceType) {
        if let existing = projects.first(where: { $0.rootPath == url.path }) {
            focus(existing)
            return
        }

        let project = JarvisProject(
            id: UUID().uuidString,
            name: url.deletingPathExtension().lastPathComponent,
            rootPath: url.path,
            order: projects.count,
            sourceType: sourceType
        )
        projects.append(project)
        persist()
        pushProject(project)
        focus(project)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: Self.projectsKey)
    }

    // MARK: - Workspace (connected files/folders)

    /// Adds each URL as a workspace item -- a directory becomes `.folder`,
    /// anything else `.file`. Skips URLs that don't exist on disk and ones
    /// already connected (by path), so dropping the same item twice is a
    /// no-op rather than a duplicate chip.
    func addWorkspaceItems(_ urls: [URL]) {
        var didAdd = false
        for url in urls {
            let path = url.path
            guard !workspaceItems.contains(where: { $0.path == path }) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            workspaceItems.append(WorkspaceItem(
                id: UUID().uuidString,
                path: path,
                kind: isDirectory.boolValue ? .folder : .file,
                addedAt: .now
            ))
            didAdd = true
        }
        guard didAdd else { return }
        persistWorkspace()
    }

    func removeWorkspaceItem(_ id: String) {
        workspaceItems.removeAll { $0.id == id }
        persistWorkspace()
    }

    private func persistWorkspace() {
        guard let data = try? JSONEncoder().encode(workspaceItems) else { return }
        UserDefaults.standard.set(data, forKey: Self.workspaceItemsKey)
    }

    // MARK: - Limule state sync (conversations + projects)

    /// Pulls remote projects/conversations, merges with local (last-write-wins
    /// for whole records, union-by-id for messages -- see `WorkspaceMerge`),
    /// and writes the merged result back to local storage. Never throws out;
    /// any failure just updates `syncState` for the UI to show.
    func pullAndMergeFromCloud() async {
        guard LimuleAPIService.hasKey else {
            syncState = .unavailable(reason: "Connecte Limule pour synchroniser.")
            return
        }
        syncState = .syncing
        do {
            let remoteProjects = try await WorkspaceSyncService.getNamespace("projects", as: JarvisProject.self)
            projects = WorkspaceMerge.mergeProjects(local: projects, remote: remoteProjects)
                .sorted { $0.order < $1.order }
            persist()

            let remoteConversations = try await WorkspaceSyncService.getNamespace(
                "conversations", as: WorkspaceSyncService.ConversationPayload.self
            )
            for (id, remotePayload) in remoteConversations {
                let localPayload = conversations.first(where: { $0.id == id }).map {
                    WorkspaceSyncService.ConversationPayload(
                        conversation: $0,
                        messages: LocalDatabase.shared.loadHistory(conversationID: id)
                    )
                }
                guard let merged = WorkspaceMerge.mergeConversation(local: localPayload, remote: remotePayload) else { continue }

                LocalDatabase.shared.upsertConversation(merged.conversation)
                for message in merged.messages {
                    LocalDatabase.shared.insertMessageIfMissing(message, conversationID: id)
                }
                if let index = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[index] = merged.conversation
                } else {
                    conversations.append(merged.conversation)
                }
            }
            conversations.sort { $0.updatedAt > $1.updatedAt }
            if conversations.contains(where: { $0.id == activeConversationID }) {
                commandHistory = LocalDatabase.shared.loadHistory(conversationID: activeConversationID)
            }

            markSynced()
        } catch {
            syncState = .unavailable(reason: Self.syncErrorMessage(error))
        }
    }

    /// "Synchroniser maintenant": a full pull-and-merge, then re-push every
    /// local project/conversation -- a cheap reconciliation pass that catches
    /// anything a mutation-triggered push missed while offline.
    func syncNow() async {
        await pullAndMergeFromCloud()
        guard LimuleAPIService.hasKey else { return }
        for project in projects {
            try? await WorkspaceSyncService.putItem(namespace: "projects", itemKey: project.id, value: project)
        }
        for conversation in conversations {
            let messages = LocalDatabase.shared.loadHistory(conversationID: conversation.id)
            let payload = WorkspaceSyncService.ConversationPayload(conversation: conversation, messages: messages)
            try? await WorkspaceSyncService.putItem(namespace: "conversations", itemKey: conversation.id, value: payload)
        }
    }

    private func pushProject(_ project: JarvisProject) {
        guard LimuleAPIService.hasKey else { return }
        Task {
            do {
                try await WorkspaceSyncService.putItem(namespace: "projects", itemKey: project.id, value: project)
            } catch {
                syncState = .unavailable(reason: Self.syncErrorMessage(error))
            }
        }
    }

    private func pushConversation(_ conversationID: String) {
        guard LimuleAPIService.hasKey, let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let payload = WorkspaceSyncService.ConversationPayload(
            conversation: conversation,
            messages: LocalDatabase.shared.loadHistory(conversationID: conversationID)
        )
        Task {
            do {
                try await WorkspaceSyncService.putItem(namespace: "conversations", itemKey: conversationID, value: payload)
            } catch {
                syncState = .unavailable(reason: Self.syncErrorMessage(error))
            }
        }
    }

    private func deleteProjectRemote(_ id: String) {
        guard LimuleAPIService.hasKey else { return }
        Task { try? await WorkspaceSyncService.deleteItem(namespace: "projects", itemKey: id) }
    }

    private func markSynced() {
        let now = Date.now
        syncState = .synced(at: now)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastSyncedAtKey)
    }

    private static func syncErrorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
