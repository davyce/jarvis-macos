import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JarvisCommandView: View {
    @Environment(ProjectStore.self) private var projectStore
    @State private var prompt = ""
    @State private var isThinking = false
    /// Set when `prompt` was just filled by voice transcription (never by
    /// typing) -- read once at `send()` time to decide whether this turn's
    /// replies get spoken aloud, per the "TTS only for voice-originated
    /// questions" decision.
    @State private var promptWasVoiceTranscribed = false
    @State private var pendingReplyIsVoiceOrigin = false
    /// Guards the `.onChange(of: prompt)` below from clearing
    /// `promptWasVoiceTranscribed` the moment it's set -- filling `prompt`
    /// with a transcript is itself a change to `prompt`.
    @State private var isApplyingTranscript = false
    /// Hands-free conversation mode: one mic click starts a loop that
    /// listens (silence-based auto-stop), auto-sends the transcript, waits
    /// for the spoken reply to finish, then listens again -- until the
    /// user clicks the mic again to stop it. See `runConversationLoop()`.
    @State private var isConversationModeActive = false
    @State private var conversationTask: Task<Void, Never>?
    /// Count of in-flight local file searches -- separate from `isThinking`
    /// on purpose. `isThinking` also disables the composer's send button
    /// (right, for a single-shot LLM call whose reply the next message
    /// would otherwise race against), but a file search must never block
    /// sending another message or starting another action while it runs in
    /// the background -- a counter (not a Bool) so several overlap cleanly.
    @State private var activeSearchCount = 0
    /// Filled after each local search -- lets a follow-up like "lis le
    /// fichier Dialogue satirique Youlou-Ngouabi" resolve to the actual
    /// path a prior search just showed, instead of requiring the user to
    /// copy/paste a full path for every single file action.
    @State private var lastSearchResults: [LocalFileService.FileEntry] = []
    /// The path of whatever file the conversation was last actually about
    /// -- top result of the last search, or the target of the last
    /// successful read/write/duplicate/delete/move. Lets "lis le fichier"
    /// (no name), "lis-le", "decris-moi ce fichier" resolve without
    /// re-typing a name/path every time, important across a long working
    /// session where repeating the same path over and over is friction.
    @State private var lastReferencedFilePath: String?
    /// True while a file dragged from Finder hovers over this window --
    /// drives the drop-target overlay below, purely visual feedback.
    @State private var isDropTargeted = false

    private var entries: [CommandEntry] {
        guard !projectStore.commandHistory.isEmpty else {
            return [
                CommandEntry(
                    role: .jarvis,
                    text: "Je suis pret. Je peux agir sur tes projets localement et consulter le cerveau Limule lorsque sa cle API est connectee.",
                    detail: "Actions locales + API Limule"
                )
            ]
        }
        return projectStore.commandHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            conversation
            Divider().overlay(.white.opacity(0.08))
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.cyan, lineWidth: 2)
                    .background(Color.cyan.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        Label("Depose des fichiers ou dossiers ici", systemImage: "doc.badge.arrow.up")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.cyan)
                            .padding(10)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                    .allowsHitTesting(false)
                    .padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { handleDroppedURLs(urls) }
            return true
        }
        .onChange(of: projectStore.clapConversationRequestID) {
            guard projectStore.clapConversationRequestID > 0 else { return }
            startConversationMode()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("JARVIS")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(1.5)
                Text("Commande et contexte de travail")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let project = projectStore.focusedProject {
                Label(project.name, systemImage: "scope")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.cyan)
            }
            historyMenu
            Button {
                projectStore.startNewConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Nouvelle conversation")
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
    }

    private var historyMenu: some View {
        Menu {
            ForEach(projectStore.conversations) { conversation in
                // A submenu (not a flat button) so each conversation gets
                // both a switch action and a destructive delete action
                // without needing a separate sheet/list view.
                Menu {
                    Button("Ouvrir") {
                        projectStore.switchConversation(conversation.id)
                    }
                    Button("Supprimer", role: .destructive) {
                        confirmDeleteConversation(conversation)
                    }
                } label: {
                    if conversation.id == projectStore.activeConversationID {
                        Label(conversation.title, systemImage: "checkmark")
                    } else {
                        Text(conversation.title)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
        .help("Historique des conversations")
    }

    /// Conversation deletion is permanent (no Trash-equivalent to fall
    /// back to, unlike file deletion elsewhere in this app) -- always
    /// confirmed, same `NSAlert` pattern as `FileActionConfirmation`.
    private func confirmDeleteConversation(_ conversation: Conversation) {
        let alert = NSAlert()
        alert.messageText = "Supprimer \u{201C}\(conversation.title)\u{201D} ?"
        alert.informativeText = "Cette conversation et tous ses messages seront supprimes definitivement. Cette action est irreversible."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        projectStore.deleteConversation(conversation.id)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(entries) { entry in
                        CommandEntryView(entry: entry, onSelectQuizOption: submit)
                            .id(entry.id)
                    }
                    if isThinking {
                        thinkingIndicator
                            .id("thinking")
                    }
                    if projectStore.voiceSessionState == .speaking {
                        speakingIndicator
                            .id("speaking")
                    }
                    if activeSearchCount > 0 {
                        searchIndicator
                            .id("searching")
                    }
                }
                .padding(34)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .onChange(of: entries.count) {
                guard let id = entries.last?.id else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: isThinking) {
                guard isThinking else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("thinking", anchor: .bottom)
                }
            }
            .onChange(of: projectStore.voiceSessionState) {
                guard projectStore.voiceSessionState == .speaking else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("speaking", anchor: .bottom)
                }
            }
            .onChange(of: activeSearchCount) {
                guard activeSearchCount > 0 else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("searching", anchor: .bottom)
                }
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 16) {
            // ThinkingOrb renders in monochrome ink; `.mask` recolors every
            // dot to Jarvis's cyan while keeping each one's own alpha exactly
            // (mask uses only the alpha channel, not the ink's grey value).
            Color.cyan
                .mask(ThinkingOrb(state: .solving, size: .px64, displaySize: 140))
                .frame(width: 140, height: 140)
            Text("JARVIS reflechit...")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var speakingIndicator: some View {
        HStack(spacing: 16) {
            LiquidOrbView()
                .frame(width: 420, height: 420)
            Text("JARVIS parle...")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Shown while a local file search runs in the background. Deliberately
    /// doesn't reuse `thinkingIndicator`/`isThinking` -- that state also
    /// disables the composer's send button, and a search must never block
    /// the user from sending another message or starting another action
    /// while it's still running.
    private var searchIndicator: some View {
        HStack(spacing: 16) {
            Color.cyan
                .mask(ThinkingOrb(state: .solving, size: .px64, displaySize: 90))
                .frame(width: 90, height: 90)
            Text("Recherche en cours...")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !projectStore.workspaceItems.isEmpty {
                workspaceChipRow
            }
            HStack(spacing: 9) {
                Image("JarvisMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                TextField("Demande a Jarvis...", text: $prompt)
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                    .onChange(of: prompt) {
                        if isApplyingTranscript {
                            isApplyingTranscript = false
                        } else {
                            // Any change to prompt that didn't come from
                            // applying a transcript (typing, a suggestion
                            // chip, send() clearing it) means this turn is
                            // no longer purely voice-originated -- an
                            // abandoned recording must not silently arm
                            // auto-speak for whatever gets sent next.
                            promptWasVoiceTranscribed = false
                        }
                    }
                micButton
                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
                .help("Envoyer")
            }
            .padding(14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            if isConversationModeActive {
                Label(voiceStatusText, systemImage: voiceStatusIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(projectStore.voiceSessionState == .recording ? .cyan : .secondary)
            }

            if let voiceError = projectStore.voiceError {
                Text(voiceError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                CommandSuggestion(title: "Ou en suis-je ?") {
                    submit("Ou en suis-je ?")
                }
                CommandSuggestion(title: "Verifie le build") {
                    submit("Verifie le build")
                }
                CommandSuggestion(title: "Ouvre dans l'editeur") {
                    submit("Ouvre dans l'editeur")
                }
                CommandSuggestion(title: "Passe sur ZOLA") {
                    submit("Passe sur ZOLA")
                }
            }
        }
        .padding(24)
    }

    private var workspaceChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(projectStore.workspaceItems) { item in
                    WorkspaceItemChip(item: item) {
                        projectStore.removeWorkspaceItem(item.id)
                    }
                }
            }
        }
    }

    private var micButton: some View {
        Button {
            if isConversationModeActive {
                stopConversationMode()
            } else {
                startConversationMode()
            }
        } label: {
            if isConversationModeActive {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            } else if projectStore.voiceSessionState == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "mic")
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.borderless)
        .disabled(!isConversationModeActive && (projectStore.voiceSessionState == .transcribing || projectStore.voiceSessionState == .speaking))
        .help(isConversationModeActive ? "Arreter la conversation" : "Parler a Jarvis")
    }

    private var voiceStatusText: String {
        switch projectStore.voiceSessionState {
        case .recording: "Jarvis t'ecoute..."
        case .transcribing: "Transcription en cours..."
        case .speaking: "Jarvis repond..."
        case .idle: "Conversation active"
        }
    }

    private var voiceStatusIcon: String {
        switch projectStore.voiceSessionState {
        case .recording: "waveform"
        case .transcribing: "text.bubble"
        case .speaking: "speaker.wave.2"
        case .idle: "circle.fill"
        }
    }

    private func startConversationMode() {
        guard !isConversationModeActive, projectStore.voiceSessionState == .idle else { return }
        isConversationModeActive = true
        conversationTask = Task { @MainActor in await runConversationLoop() }
    }

    /// Stops hands-free conversation mode from wherever it currently is in
    /// its cycle -- mid-recording (silence alone can't be relied on if the
    /// user is still talking), mid-transcription (nothing to interrupt;
    /// the loop notices `isConversationModeActive` is false once it
    /// resolves and simply won't act on it), or mid-reply-playback.
    private func stopConversationMode() {
        guard isConversationModeActive else { return }
        isConversationModeActive = false
        conversationTask?.cancel()
        conversationTask = nil
        projectStore.cancelListening()
        if projectStore.voiceSessionState == .speaking {
            projectStore.stopSpeaking()
        }
    }

    /// The hands-free loop: listen for one utterance (silence auto-stops
    /// it), send it as if typed, wait for the reply to finish being
    /// spoken, then listen again. Runs until `isConversationModeActive`
    /// goes false (`stopConversationMode()`) or the task is cancelled.
    private func runConversationLoop() async {
        while isConversationModeActive, !Task.isCancelled {
            guard let transcript = await projectStore.listenForOneTurn() else {
                if projectStore.voiceError != nil {
                    // A real failure (mic permission, engine setup...), not
                    // just silence/room noise -- stop instead of spinning
                    // on it forever.
                    stopConversationMode()
                    return
                }
                guard isConversationModeActive, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            guard isConversationModeActive, !Task.isCancelled else { return }

            promptWasVoiceTranscribed = true
            isApplyingTranscript = true
            prompt = transcript
            send()

            await waitForReplyToFinish()
        }
    }

    /// `send()`'s trigger dispatch is fire-and-forget in several branches,
    /// so `voiceSessionState` is the observable signal that a turn has a
    /// spoken reply. Jarvis does not listen while its own reply is playing:
    /// a "barge in and interrupt" experience was tried (recording with
    /// voice processing enabled while `VoicePlayback` was still speaking,
    /// to strip the app's own audio back out of the mic signal) but live
    /// testing found it produced a silent input stream on many Mac audio
    /// routes, so listening always waits for playback to finish first.
    private func waitForReplyToFinish() async {
        var waited: TimeInterval = 0
        while projectStore.voiceSessionState != .speaking, waited < 90 {
            guard isConversationModeActive, !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            waited += 0.15
        }

        guard projectStore.voiceSessionState == .speaking else { return }
        while projectStore.voiceSessionState == .speaking {
            guard isConversationModeActive, !Task.isCancelled else {
                projectStore.stopSpeaking()
                return
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func submit(_ value: String) {
        prompt = value
        send()
    }

    private func send() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        pendingReplyIsVoiceOrigin = promptWasVoiceTranscribed
        promptWasVoiceTranscribed = false
        prompt = ""
        let switchedProject = projectStore.adoptProjectMentioned(in: request)
        projectStore.appendCommandEntry(CommandEntry(
            role: .user,
            text: request,
            detail: switchedProject.map { "Contexte bascule vers \($0.name)" }
        ))

        let normalized = request.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        let resumeTriggers = ["ou en suis", "ou j'en suis", "reprendre le travail", "fais le point", "statut du projet"]
        if resumeTriggers.contains(where: normalized.contains) {
            guard let project = projectStore.focusedProject else { return }
            Task { await resumeSummary(for: project) }
            return
        }

        // LIMULE Bridge productivity triggers (timer/alarm/reminder/note/
        // document/message) -- checked before `noteTriggers` just below,
        // which uses a broad `.contains("rappel")`/`.contains("note ")`
        // catch-all that would otherwise swallow "cree un rappel dans
        // Rappels : ..." / "cree une note dans Notes : ...". These are all
        // narrowly prefix-anchored so they can never accidentally steal a
        // message meant for the local note trigger below (e.g.
        // "rappelle-moi de X" never has the prefix "cree un rappel...").
        if let seconds = bridgeTimerSeconds(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.startTimer(seconds: seconds))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let alarm = bridgeAlarmRequest(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.startAlarm(hour: alarm.hour, minute: alarm.minute, label: alarm.label))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let title = bridgeReminderTitle(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.createReminder(title: title, list: nil))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let note = bridgeNoteRequest(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.createNote(title: note.title, body: note.body))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // "cree une note dans Notes avec le texte que tu viens d'ecrire" --
        // referential variant of the trigger above: resolves the body from
        // Jarvis's own last reply instead of requiring it typed inline.
        // Live testing showed the LLM writing content (a poem, on request)
        // then correctly saying it couldn't save it itself and asking the
        // user to re-paste it -- exactly the copy-paste friction this
        // avoids.
        if let note = bridgeNoteWithContentRequest(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.createNote(title: note.title, body: note.body))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let document = bridgeDocumentRequest(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.createDocument(app: document.app, title: document.title, body: document.body))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // "cree un document Pages avec le poeme que tu viens de rediger" --
        // referential variant of the trigger above, same reasoning.
        if let document = bridgeDocumentWithContentRequest(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.createDocument(app: document.app, title: document.title, body: document.body))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let message = bridgeSendMessageRequest(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.sendMessage(recipient: message.recipient, text: message.text))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        let noteTriggers = ["rappel", "n'oublie pas", "noublie pas", "note ", "note que", "mes notes", "inscri"]
        if noteTriggers.contains(where: normalized.contains) {
            guard let project = projectStore.focusedProject else { return }
            let content = noteContent(from: request)
            let result = JarvisBridge.perform(.addNote(text: content), on: project)
            reply(result.message, detail: result.succeeded ? "Action Bridge - NOTES.md" : "Bridge : echec")
            return
        }

        if normalized.contains("build") || normalized.contains("compile") {
            guard let project = projectStore.focusedProject else { return }
            reply("Je verifie le build de \(project.name)...", detail: "Lancement de \(BuildInspector.detectTool(projectPath: project.rootPath)?.label ?? "la verification")")
            Task { await runBuildCheck(project: project) }
            return
        }

        if normalized.contains("branche") && (normalized.contains("cree") || normalized.contains("nouvelle")) {
            guard let project = projectStore.focusedProject else { return }
            if let name = branchName(from: request) {
                let result = JarvisBridge.perform(.createBranch(name: name), on: project)
                reply(result.message, detail: result.succeeded ? "Action Bridge" : "Bridge : echec")
                if result.succeeded { projectStore.refresh(project) }
            } else {
                reply("Precise le nom de la branche, par exemple : \u{201C}cree une branche fix-login\u{201D}.", detail: nil)
            }
            return
        }

        if normalized.contains("clique sur build") || normalized.contains("clic sur build") {
            guard let project = projectStore.focusedProject else { return }
            let result = JarvisBridge.perform(.system(.clickXcodeBuildButton), on: project)
            reply(result.message, detail: result.succeeded ? "Action systeme - Accessibilite" : "Action systeme : bloquee")
            return
        }

        // File actions, all checked before the generic "editeur"/"capture
        // d'ecran"/project-name catch-alls below: a search query or a
        // written file's content is arbitrary text that could itself
        // contain "editeur" or a project name as a substring, and a
        // `.contains(...)` generic check earlier in this chain would
        // otherwise hijack the message before ever reaching these. Every
        // trigger is prefix-anchored (`hasPrefix`, like `typedTextRequest`
        // below) so an unrelated message that merely mentions "cherche" or
        // "supprime" mid-sentence never matches by accident. Search/read
        // are always free; write/duplicate/delete/move are gated by
        // JarvisBridge+LocalFile.swift's permission+confirmation flow.
        if let query = fileSearchQuery(from: request, normalized: normalized) {
            reply("Je cherche \u{201C}\(query)\u{201D}...", detail: "Recherche locale en cours")
            activeSearchCount += 1
            Task {
                defer { activeSearchCount -= 1 }
                let result = await JarvisBridge.performFileAction(.search(query: query))
                if let entries = result.entries,
                   let json = FileListSpec(
                       query: query,
                       entries: entries.map { .init(path: $0.path, isDirectory: $0.isDirectory, modifiedAt: $0.modifiedAt) },
                       truncated: result.truncated
                   ).toJSON() {
                    lastSearchResults = entries
                    lastReferencedFilePath = entries.first?.path
                    reply("Voici ce que j'ai trouve :\n\n```filelist\n\(json)\n```", detail: "Recherche locale")
                } else {
                    reply(result.message, detail: result.succeeded ? "Recherche locale" : "Recherche : echec")
                }
            }
            return
        }

        if let rawPath = filePathToRead(from: request, normalized: normalized) {
            let path = resolveFilePath(rawPath)
            lastReferencedFilePath = path
            Task {
                let result = await JarvisBridge.performFileAction(.readText(path: path))
                if let content = result.content {
                    let language = (path as NSString).pathExtension
                    reply("Contenu de `\(path)` :\n\n```\(language)\n\(content)\n```", detail: "Lecture locale")
                } else {
                    reply(result.message, detail: "Lecture : echec")
                }
            }
            return
        }

        if let rawPath = filePathToOpen(from: request, normalized: normalized) {
            let path = resolveFilePath(rawPath)
            lastReferencedFilePath = path
            Task {
                let result = await JarvisBridge.performFileAction(.open(path: path))
                reply(result.message, detail: result.succeeded ? "Ouverture locale" : "Ouverture : echec")
            }
            return
        }

        if let fileWrite = fileWriteRequest(from: request, normalized: normalized) {
            let path = resolveFilePath(fileWrite.path)
            lastReferencedFilePath = path
            Task {
                let result = await JarvisBridge.performFileAction(.write(path: path, content: fileWrite.content))
                reply(result.message, detail: result.succeeded ? "Action fichier" : "Action fichier : bloquee")
            }
            return
        }

        if let rawPath = filePathToDuplicate(from: request, normalized: normalized) {
            let path = resolveFilePath(rawPath)
            lastReferencedFilePath = path
            Task {
                let result = await JarvisBridge.performFileAction(.duplicate(path: path))
                reply(result.message, detail: result.succeeded ? "Action fichier" : "Action fichier : bloquee")
            }
            return
        }

        if let rawPath = filePathToDelete(from: request, normalized: normalized) {
            let path = resolveFilePath(rawPath)
            lastReferencedFilePath = path
            Task {
                let result = await JarvisBridge.performFileAction(.delete(path: path))
                reply(result.message, detail: result.succeeded ? "Action fichier" : "Action fichier : bloquee")
            }
            return
        }

        if let fileMove = fileMoveRequest(from: request, normalized: normalized) {
            // fileMoveRequest already resolves `from` against
            // lastSearchResults internally (needed there to compute an
            // implicit destination directory for "renomme ... en <name>").
            // References `to`, not `from` -- after a successful move/rename
            // that's where the file actually lives now.
            lastReferencedFilePath = fileMove.to
            Task {
                let result = await JarvisBridge.performFileAction(.move(from: fileMove.from, to: fileMove.to))
                reply(result.message, detail: result.succeeded ? "Action fichier" : "Action fichier : bloquee")
            }
            return
        }

        // These two must be checked before the generic "editeur" -> openInEditor
        // catch-all below: both "focus editeur" and "ecris dans l'editeur ..."
        // contain the substring "editeur" too, so if the generic check ran
        // first it would swallow them and they'd never be reached.
        if normalized.contains("editeur au premier plan") || normalized.contains("focus editeur") {
            guard let project = projectStore.focusedProject else { return }
            let result = JarvisBridge.perform(.system(.focusEditorWindow), on: project)
            reply(result.message, detail: result.succeeded ? "Action systeme - Accessibilite" : "Action systeme : bloquee")
            return
        }

        if let text = typedTextRequest(from: request, normalized: normalized) {
            guard let project = projectStore.focusedProject else { return }
            let result = JarvisBridge.perform(.system(.typeIntoFocusedEditorField(text: text)), on: project)
            reply(result.message, detail: result.succeeded ? "Action systeme - Accessibilite" : "Action systeme : bloquee")
            return
        }

        if normalized.contains("editeur") || normalized.contains("vs code") || normalized.contains("vscode") || normalized.contains("xcode") {
            guard let project = projectStore.focusedProject else { return }
            let result = JarvisBridge.perform(.openInEditor, on: project)
            reply(result.message, detail: result.succeeded ? "Action Bridge" : "Bridge : action partielle")
            return
        }

        if normalized.contains("capture d'ecran") || normalized.contains("capture decran") || normalized.contains("screenshot") {
            Task {
                let result = await JarvisBridge.performScreenshotBridgeAction(displayID: nil)
                if let path = result.localPath, let width = result.width, let height = result.height,
                   let json = ScreenshotSpec(path: path, width: width, height: height, capturedAt: .now, displayID: nil).toJSON() {
                    reply("Capture d'ecran prise :\n\n```screenshot\n\(json)\n```", detail: "LIMULE Bridge")
                } else {
                    reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
                }
            }
            return
        }

        // LIMULE Bridge observation/utility triggers -- checked after the
        // screenshot trigger above (same "LIMULE Bridge" call family) and
        // before the generic project-name/"ouvre" fallbacks below, same
        // ordering discipline as the file-action block: none of these
        // phrases are substrings a project name or a free-text argument
        // would plausibly contain.
        if normalized.contains("bridge est disponible") || normalized.contains("bridge est-il disponible") || normalized.contains("verifie bridge") {
            Task {
                let result = await JarvisBridge.performLimuleObservation(.health)
                reply(result.content ?? result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if normalized.contains("liste les ecrans") || normalized.contains("liste des ecrans") {
            Task {
                let result = await JarvisBridge.performLimuleObservation(.displays)
                reply(result.content ?? result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if normalized.hasPrefix("inspecte ") || normalized.hasPrefix("structure de ") {
            let prefix = normalized.hasPrefix("inspecte ") ? "inspecte " : "structure de "
            let app = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            Task {
                let result = await JarvisBridge.performLimuleObservation(.snapshot(app: app.isEmpty ? nil : app))
                reply(result.content ?? result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if normalized.contains("lis le presse-papiers") || normalized.contains("lis le presse papiers") || normalized.contains("contenu du presse-papiers") || normalized.contains("contenu du presse papiers") {
            Task {
                let result = await JarvisBridge.performLimuleObservation(.getClipboard)
                reply(result.content ?? result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if normalized.contains("liste les fenetres") || normalized.contains("liste des fenetres") {
            Task {
                let result = await JarvisBridge.performLimuleObservation(.windows)
                reply(result.content ?? result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if normalized.contains("lis la page") || normalized.contains("texte de la page") {
            Task {
                let result = await JarvisBridge.performLimuleObservation(.browserText)
                reply(result.content ?? result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if normalized.contains("annule la derniere action") {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.undo)
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let text = bridgeClipboardWriteText(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.setClipboard(text: text))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let name = bridgeLaunchAppName(from: request, normalized: normalized) {
            guard let bundleID = resolveBundleID(forAppName: name) else {
                reply("Je ne trouve pas d'application nommee \u{201C}\(name)\u{201D} dans /Applications.", detail: nil)
                return
            }
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.launchApp(bundleID: bundleID))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let name = bridgeActivateAppName(from: request, normalized: normalized) {
            guard let bundleID = resolveBundleID(forAppName: name) else {
                reply("Je ne trouve pas d'application nommee \u{201C}\(name)\u{201D} dans /Applications.", detail: nil)
                return
            }
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.activateApp(bundleID: bundleID))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let url = bridgeBrowserNavigateURL(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.browserNavigate(url: url))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // Checked before the generic "clique sur NOM" press trigger below
        // -- more specific (requires the "dans le navigateur" suffix), so
        // it must win over the generic one or a browser click would be
        // sent to Bridge's desktop press route instead.
        if let target = bridgeBrowserClickTarget(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.browserClick(target: target))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // Checked before jalon 5's generic "tape TEXTE" raw-primitive
        // trigger for the same reason -- more specific (requires the "du
        // navigateur" suffix).
        if let browserType = bridgeBrowserTypeRequest(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.browserType(target: browserType.target, text: browserType.text))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // Named UI press ("clique sur NOM") -- deliberately generic
        // (hasPrefix "clique sur "), checked after the more specific
        // browser-click trigger above.
        if let target = bridgePressTarget(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.press(title: target.title, app: target.app))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // Raw coordinate/keyboard primitives -- last in the Bridge block,
        // checked after every named/specific trigger above so a more
        // meaningful phrase never falls through to a blind coordinate
        // click or generic keystroke by accident.
        if let point = bridgeCoordinates(from: request, normalized: normalized, prefixes: Self.doubleClickPrefixes) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.doubleClick(x: point.0, y: point.1))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let point = bridgeCoordinates(from: request, normalized: normalized, prefixes: Self.rightClickPrefixes) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.rightClick(x: point.0, y: point.1))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let point = bridgeCoordinates(from: request, normalized: normalized, prefixes: Self.clickPrefixes) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.click(x: point.0, y: point.1))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let drag = bridgeDragCoordinates(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.drag(fromX: drag.fromX, fromY: drag.fromY, toX: drag.toX, toY: drag.toY))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let combo = bridgeKeyCombo(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.key(combo: combo))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        if let delta = bridgeScrollDelta(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.scroll(dx: delta.0, dy: delta.1))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // Generic "tape TEXTE" -- last of all, after every other trigger
        // in this file that also starts with "tape " (editor-specific
        // `typedTextRequest`, browser-specific `bridgeBrowserTypeRequest`
        // above): both are checked earlier, so only a plain, otherwise
        // unmatched "tape ..." reaches this raw Bridge keystroke.
        if let text = bridgeRawTypeText(from: request, normalized: normalized) {
            Task {
                let result = await JarvisBridge.performLimuleBridgeAction(.type(text: text))
                reply(result.message, detail: result.succeeded ? "LIMULE Bridge" : "LIMULE Bridge : bloque")
            }
            return
        }

        // Anchored to an explicit focus-intent phrase -- a bare project
        // name mention anywhere in a message (e.g. "compare vitesse/memoire
        // de Jarvis vs ZOLA en radar") used to hijack the whole message via
        // an unanchored `.contains(...)` check, focusing the project
        // instead of ever reaching askLimule() for what was actually asked.
        if let remainder = projectFocusRemainder(from: normalized),
           let project = projectStore.projects.first(where: {
               remainder.contains($0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
           }) {
            projectStore.focus(project)

            if normalized.hasPrefix("ouvre ") {
                let result = JarvisBridge.perform(.openInFinder, on: project)
                reply(result.message, detail: "Action Bridge")
            } else {
                reply(
                    "Le focus est maintenant sur \(project.name). Je rafraichis son contexte Git.",
                    detail: "Projet actif : \(project.name)"
                )
            }
            return
        }

        if normalized.contains("ouvre") {
            guard let project = projectStore.focusedProject else { return }
            let result = JarvisBridge.perform(.openInFinder, on: project)
            reply(result.message, detail: "Action Bridge")
            return
        }

        if normalized.contains("rafraich") || normalized.contains("verifie") || normalized.contains("changement") || normalized.contains("git") {
            projectStore.refreshAll()
            let project = projectStore.focusedProject
            let snapshot = project.map(projectStore.snapshot)
            let detail = snapshot.map { "\($0.changedFileCount) fichier(s) non commite(s), branche \($0.branch)" }
            reply("J'ai relance l'analyse locale de l'espace de travail.", detail: detail ?? "Rafraichissement lance")
            return
        }

        Task { await askLimule() }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"
    ]

    /// Files/folders dropped from Finder anywhere in the window, all at
    /// once. An image is the one kind still posted directly into the chat
    /// (inline via the same ```screenshot fence real captures use, pointing
    /// straight at the dropped file's own path, no copy) -- everything else
    /// (documents, folders) is connected to the persistent workspace
    /// instead of dumping its content as a one-off message. See
    /// `WorkspaceItem` and `ProjectStore.addWorkspaceItems`.
    private func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var imageURLs: [URL] = []
        var workspaceURLs: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists, !isDirectory.boolValue, Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                imageURLs.append(url)
            } else {
                workspaceURLs.append(url)
            }
        }
        for url in imageURLs {
            handleDroppedImage(url)
        }
        guard !workspaceURLs.isEmpty else { return }
        projectStore.addWorkspaceItems(workspaceURLs)
        let names = workspaceURLs.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
        reply("Connecte au workspace : \(names). Ces elements restent disponibles tant qu'ils ne sont pas retires.", detail: "Workspace")
    }

    private func handleDroppedImage(_ url: URL) {
        let path = url.path
        projectStore.appendCommandEntry(CommandEntry(role: .user, text: "Image deposee : \(path)", detail: nil))
        lastReferencedFilePath = path
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first else {
            reply("Je n'ai pas pu lire cette image.", detail: "Depot de fichier : echec")
            return
        }
        if let json = ScreenshotSpec(path: path, width: rep.pixelsWide, height: rep.pixelsHigh, capturedAt: .now, displayID: nil).toJSON() {
            reply("Image deposee :\n\n```screenshot\n\(json)\n```", detail: "Depot de fichier")
        } else {
            reply("Image deposee : \(path)", detail: "Depot de fichier")
        }
    }

    /// Strips a reminder/note trigger phrase from the request to isolate the
    /// actual content to write. When the request is a bare back-reference
    /// ("note ca", "inscris ca dans mes notes") the content is pulled from
    /// the previous user message instead of the trigger phrase itself.
    private static let noteTriggerPrefixes = [
        "rappelle-moi de ", "rappelle moi de ", "rappelle-moi ", "rappelle moi ",
        "n'oublie pas de ", "noublie pas de ", "n'oublie pas ", "noublie pas ",
        "note que ", "note que", "note ",
        "ajoute a mes notes que ", "ajoute a mes notes ",
        "inscris ca dans mes notes", "inscris cela dans mes notes",
        "peux tu inscrire ca dans mes notes", "peux-tu inscrire ca dans mes notes"
    ]

    private func noteContent(from request: String) -> String {
        let normalized = request.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var stripped = request
        for prefix in Self.noteTriggerPrefixes {
            if normalized.hasPrefix(prefix) {
                stripped = String(request.dropFirst(prefix.count))
                break
            }
        }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        let referential: Set<String> = ["ca", "cela", "cette info", "cette information", "ceci", ""]
        if referential.contains(trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)) {
            if let previous = projectStore.commandHistory.dropLast().last(where: { $0.role == .user }) {
                return previous.text
            }
            return request
        }
        return trimmed
    }

    private static let typeTriggerPrefixes = [
        "ecris dans l'editeur ", "ecris dans l'editeur:", "ecris dans l'editeur :",
        "tape dans l'editeur ", "tape dans l'editeur:", "tape dans l'editeur :"
    ]

    /// Recognizes an explicit "type this into the editor" request and
    /// returns just the text to type, or nil if the request doesn't match
    /// this trigger at all.
    private func typedTextRequest(from request: String, normalized: String) -> String? {
        for prefix in Self.typeTriggerPrefixes where normalized.hasPrefix(prefix) {
            let content = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : content
        }
        return nil
    }

    private func branchName(from request: String) -> String? {
        guard let range = request.range(of: "branche", options: .caseInsensitive) else { return nil }
        let trailing = request[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return trailing.isEmpty ? nil : trailing
    }

    // MARK: - File action triggers

    /// Shared extraction for the five single-argument file triggers
    /// (search/read/duplicate/delete): requires the message to literally
    /// start with one of `verbs` (so an unrelated message is never
    /// hijacked), then finds the first "fichier"/"fichiers" after it and
    /// returns everything past that word, skipping a small set of French
    /// connector words. Deliberately NOT a single fixed multi-word phrase
    /// like "cherche le fichier " -- live testing showed real phrasing
    /// varies ("cherche le fichier X" parsed fine, but "cherche ce fichier
    /// dans mon ordinateur" and other natural variants didn't match a
    /// rigid prefix list). Anchoring on the verb + the word "fichier"
    /// (rather than "fichier" alone) keeps it from also matching unrelated
    /// requests like "cherche pourquoi le build echoue".
    /// Bare pronoun/reference to "the file we're talking about" -- no
    /// name, no path. Resolved against `lastReferencedFilePath` rather
    /// than falling through to the LLM (which has no real access to any
    /// file and, without a name to work with, has nothing honest to say
    /// beyond "I don't know which file"). Important across a long working
    /// session: re-typing the same path on every follow-up is friction.
    private static let referentialFileWords: Set<String> = [
        "le", "la", "lui", "il", "ca", "cela", "ceci", "celui-ci", "celui-la",
        "ce fichier", "le fichier", "ce document", "le document", ""
    ]

    /// `lastReferencedFilePath` is plain `@State` -- lost on every app
    /// relaunch and, being tied to this View's lifetime, not something to
    /// rely on for "long working session" continuity. When it's empty,
    /// re-derive the same answer from `commandHistory`, which persists in
    /// SQLite across relaunches: scan Jarvis's own past replies, most
    /// recent first, for a ```filelist fence (top search result) or a
    /// "Contenu de `path`" read confirmation, and reuse that path.
    private func resolvedLastReferencedFilePath() -> String? {
        if let lastReferencedFilePath { return lastReferencedFilePath }

        for entry in projectStore.commandHistory.reversed() where entry.role == .jarvis {
            if let fenceRange = entry.text.range(of: "```filelist"),
               let closeRange = entry.text.range(of: "```", range: fenceRange.upperBound..<entry.text.endIndex),
               let spec = FileListSpec.parse(from: String(entry.text[fenceRange.upperBound..<closeRange.lowerBound])),
               let first = spec.entries.first {
                return first.path
            }
            if let markerRange = entry.text.range(of: "Contenu de `") {
                let after = entry.text[markerRange.upperBound...]
                if let closingTick = after.firstIndex(of: "`") {
                    return String(after[..<closingTick])
                }
            }
        }
        return nil
    }

    /// Common conversational lead-ins ("je cherche", "peux-tu chercher")
    /// that would otherwise defeat every verb's `hasPrefix` check below --
    /// live testing showed "je Cherche X" falling all the way through to
    /// askLimule() since the message doesn't start with "cherche" itself.
    private static let leadingFillers = [
        "je ", "j'aimerais ", "j'aimerai ", "peux-tu ", "peux tu ",
        "pourrais-tu ", "pourrais tu ", "stp ", "s'il te plait "
    ]

    private func stripLeadingFiller(request: String, normalized: String) -> (request: String, normalized: String) {
        for filler in Self.leadingFillers where normalized.hasPrefix(filler) {
            return (String(request.dropFirst(filler.count)), String(normalized.dropFirst(filler.count)))
        }
        return (request, normalized)
    }

    private func fileArgument(from request: String, normalized: String, verbs: [String]) -> String? {
        let (request, normalized) = stripLeadingFiller(request: request, normalized: normalized)
        guard let verb = verbs.first(where: { normalized.hasPrefix($0) }) else { return nil }

        guard let fichierRange = request.range(of: "fichier", options: [.caseInsensitive, .diacriticInsensitive]) else {
            // No "fichier" word at all. Two cases still match: the rest of
            // the message is a bare pronoun ("lis-le", "supprime le"), or
            // it's a quoted argument ('Cherche "Dialogue satirique
            // Youlou-Ngouabi"' -- no "fichier", just the name in quotes,
            // a natural way to phrase a search without that keyword).
            // Anything else is a different kind of request entirely, not
            // something this trigger should guess at.
            let rest = String(request.dropFirst(verb.count))
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-'"))
            let foldedRest = rest.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if Self.referentialFileWords.contains(foldedRest) {
                return resolvedLastReferencedFilePath()
            }
            if let quoted = Self.unquoted(rest), !quoted.isEmpty {
                return quoted
            }
            return nil
        }
        var remainder = String(request[fichierRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if remainder.hasPrefix("s") {
            remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for filler in ["nomme ", "appele ", "appelé ", "qui s'appelle "] {
            if let fillerRange = remainder.range(of: filler, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) {
                remainder = String(remainder[fillerRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Trailing location filler ("... dans mon ordinateur", "... sur le
        // Mac") is not part of the filename -- live testing showed it was
        // being kept as part of the query, so "Dialogue satirique
        // Youlou-Ngouabi dans mon ordinateur" matched nothing even though
        // the actual file existed.
        let foldedRemainder = remainder.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        for filler in [
            "dans mon ordinateur", "dans le mac", "dans mon mac",
            "sur mon ordinateur", "sur cet ordinateur", "sur le mac", "sur mon mac",
            "sur mon disque", "sur le disque", "sur mon dd", "sur le dd",
            "dans le chat", "dans la conversation", "dans la reponse", "dans ta reponse"
        ] {
            if foldedRemainder.hasSuffix(filler) {
                remainder = String(remainder.dropLast(filler.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if remainder.isEmpty { return resolvedLastReferencedFilePath() }
        let foldedFinal = remainder.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if Self.referentialFileWords.contains(foldedFinal) { return resolvedLastReferencedFilePath() }
        return remainder
    }

    /// Strips a matching pair of straight (`"..."`) or typographic
    /// (macOS auto-substitutes `"`/`"` -> curly quotes as you type)
    /// quotes wrapping the entire string, or `nil` if it isn't quoted.
    private static func unquoted(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first, let last = text.last else { return nil }
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}")]
        guard pairs.contains(where: { $0.0 == first && $0.1 == last }) else { return nil }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private func fileSearchQuery(from request: String, normalized: String) -> String? {
        fileArgument(from: request, normalized: normalized, verbs: ["cherche", "recherche", "trouve"])
    }

    private func filePathToRead(from request: String, normalized: String) -> String? {
        fileArgument(from: request, normalized: normalized, verbs: ["lis", "montre", "affiche"])
    }

    /// "ouvre" alone is the existing project-opening trigger (open the
    /// focused project in the Finder) -- this only fires when "fichier" is
    /// present or the rest is a bare pronoun ("ouvre-le"), which a project
    /// name never is, so the two never collide.
    private func filePathToOpen(from request: String, normalized: String) -> String? {
        fileArgument(from: request, normalized: normalized, verbs: ["ouvre"])
    }

    private func filePathToDuplicate(from request: String, normalized: String) -> String? {
        fileArgument(from: request, normalized: normalized, verbs: ["duplique", "copie"])
    }

    private func filePathToDelete(from request: String, normalized: String) -> String? {
        fileArgument(from: request, normalized: normalized, verbs: ["supprime", "efface", "elimine"])
    }

    /// Requires "fichier <path> : <content>" -- a colon separator rather
    /// than trying to guess where a path ends and free-text content
    /// begins.
    private func fileWriteRequest(from request: String, normalized: String) -> (path: String, content: String)? {
        guard normalized.hasPrefix("ecris") || normalized.hasPrefix("modifie") else { return nil }
        guard let fichierRange = request.range(of: "fichier", options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let remainder = String(request[fichierRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard let separatorRange = remainder.range(of: " : ") ?? remainder.range(of: ":") else { return nil }
        let path = String(remainder[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let content = String(remainder[separatorRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !content.isEmpty else { return nil }
        return (path, content)
    }

    /// "renomme ... en <name>" resolves a bare new name (no "/") next to
    /// the source file rather than requiring the full destination path --
    /// matches how a user actually thinks about renaming.
    private func fileMoveRequest(from request: String, normalized: String) -> (from: String, to: String)? {
        let combinations: [(verb: String, separator: String)] = [
            ("deplace", " vers "), ("deplace", " en "), ("renomme", " en "), ("renomme", " vers ")
        ]
        for (verb, separator) in combinations where normalized.hasPrefix(verb) {
            guard let fichierRange = request.range(of: "fichier", options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let remainder = String(request[fichierRange.upperBound...])
            guard let separatorRange = remainder.range(of: separator, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let rawFrom = String(remainder[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            var to = String(remainder[separatorRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !rawFrom.isEmpty, !to.isEmpty else { continue }
            // Resolved before computing `to`'s implicit directory below --
            // a bare name from search results has no path component of its
            // own to derive that directory from.
            let from = resolveFilePath(rawFrom)
            if !to.contains("/") {
                let directory = (from as NSString).deletingLastPathComponent
                to = directory.isEmpty ? to : "\(directory)/\(to)"
            }
            return (from, to)
        }
        return nil
    }

    /// A file-action argument is only ever a real path if it starts with
    /// "/" or "~" -- anything else is treated as a bare name and matched
    /// (substring, case/diacritic-insensitive, either direction) against
    /// whatever `lastSearchResults` a prior search just showed, so a
    /// follow-up like "lis le fichier X" works with the same name the user
    /// just saw in the results instead of requiring a copy-pasted path.
    /// Falls back to the argument itself, unresolved, when nothing matches
    /// -- the downstream action's own "not found" error is clearer than
    /// silently guessing.
    private func resolveFilePath(_ argument: String) -> String {
        guard !argument.hasPrefix("/"), !argument.hasPrefix("~") else { return argument }
        let folded = argument.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        if let match = lastSearchResults.first(where: { fileNameMatches($0.name, folded) }) {
            return match.path
        }

        // lastSearchResults is plain @State -- empty after a relaunch or
        // navigating away and back. Re-derive candidates from every
        // ```filelist fence still in the persisted history so a bare name
        // resolves across a long working session, not just within the
        // current live run.
        for entry in projectStore.commandHistory.reversed() where entry.role == .jarvis {
            guard let fenceRange = entry.text.range(of: "```filelist"),
                  let closeRange = entry.text.range(of: "```", range: fenceRange.upperBound..<entry.text.endIndex),
                  let spec = FileListSpec.parse(from: String(entry.text[fenceRange.upperBound..<closeRange.lowerBound])) else { continue }
            if let match = spec.entries.first(where: { fileNameMatches(($0.path as NSString).lastPathComponent, folded) }) {
                return match.path
            }
        }
        return argument
    }

    private func fileNameMatches(_ name: String, _ foldedArgument: String) -> Bool {
        let foldedName = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return foldedName.contains(foldedArgument) || foldedArgument.contains(foldedName)
    }

    // MARK: - LIMULE Bridge triggers

    private static let timerPrefixes = [
        "lance un minuteur de ", "demarre un minuteur de ",
        "lance un minuteur pour ", "demarre un minuteur pour "
    ]

    private func bridgeTimerSeconds(from request: String, normalized: String) -> Int? {
        guard let prefix = Self.timerPrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let remainder = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return Self.parseDurationInSeconds(remainder)
    }

    private static func parseDurationInSeconds(_ text: String) -> Int? {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let digits = folded.prefix(while: { $0.isNumber })
        guard let value = Int(digits), value > 0 else { return nil }
        if folded.contains("heure") { return value * 3600 }
        if folded.contains("minute") { return value * 60 }
        return value
    }

    private static let alarmPrefixes = [
        "regle une alarme a ", "programme une alarme a ",
        "regle une alarme pour ", "programme une alarme pour "
    ]

    /// "regle une alarme a HH:MM" (+ optional " : LABEL"). The label
    /// separator requires spaces (" : ") specifically so it's never
    /// confused with the bare ":" inside "HH:MM" itself.
    private func bridgeAlarmRequest(from request: String, normalized: String) -> (hour: Int, minute: Int, label: String?)? {
        guard let prefix = Self.alarmPrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        var remainder = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        var label: String?
        if let sepRange = remainder.range(of: " : ") {
            let trailing = String(remainder[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            label = trailing.isEmpty ? nil : trailing
            remainder = String(remainder[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let timeParts = remainder.split(separator: ":", maxSplits: 1)
        guard timeParts.count == 2,
              let hour = Int(timeParts[0].trimmingCharacters(in: .whitespaces)),
              let minute = Int(timeParts[1].trimmingCharacters(in: .whitespaces)),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute, label)
    }

    private static let reminderPrefixes = [
        "cree un rappel dans rappels : ", "cree un rappel dans les rappels : ",
        "ajoute un rappel dans rappels : ", "ajoute un rappel dans les rappels : "
    ]

    /// Explicit "dans Rappels" -- distinct from the local "rappelle-moi de
    /// X" trigger (a project NOTES.md entry, not a real Reminders.app
    /// item) handled by `noteTriggers` just below in `send()`.
    private func bridgeReminderTitle(from request: String, normalized: String) -> String? {
        guard let prefix = Self.reminderPrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let title = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static let notePrefixes = ["cree une note dans notes : ", "ajoute une note dans notes : "]

    /// Explicit "dans Notes" -- distinct from the local note-taking
    /// triggers (project NOTES.md, not a real Notes.app item).
    private func bridgeNoteRequest(from request: String, normalized: String) -> (title: String, body: String)? {
        guard let prefix = Self.notePrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let remainder = String(request.dropFirst(prefix.count))
        guard let sepRange = remainder.range(of: " : ") else { return nil }
        let title = String(remainder[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let body = String(remainder[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !body.isEmpty else { return nil }
        return (title, body)
    }

    private static let documentPrefixes = ["cree un document dans "]

    private func bridgeDocumentRequest(from request: String, normalized: String) -> (app: String, title: String, body: String)? {
        guard let prefix = Self.documentPrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let remainder = String(request.dropFirst(prefix.count))
        let parts = remainder.components(separatedBy: " : ")
        guard parts.count >= 3 else { return nil }
        let app = parts[0].trimmingCharacters(in: .whitespaces)
        let title = parts[1].trimmingCharacters(in: .whitespaces)
        let body = parts[2...].joined(separator: " : ").trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !title.isEmpty, !body.isEmpty else { return nil }
        return (app, title, body)
    }

    /// Phrases that mean "the content of your own last reply", not
    /// literal text to save -- lets "avec le poeme que tu viens de
    /// rediger" resolve without the user re-pasting what Jarvis just
    /// wrote.
    private static let referentialContentPhrases = [
        "que tu viens de rediger", "que tu viens d'ecrire", "que tu viens de composer",
        "que tu viens de faire", "que tu as ecrit", "que tu as redige", "ci-dessus", "precedent"
    ]

    /// A message that itself asks to save/reuse Jarvis's last reply as a
    /// note/document/reminder -- used below to recognize, and skip past,
    /// a Jarvis reply that is really just commentary about a PRIOR such
    /// request (e.g. an earlier failed attempt at this very trigger)
    /// rather than the actual authored content the user wants saved.
    private static let saveRequestPrefixes = [
        "cree un document", "cree une note", "ajoute une note", "cree un rappel", "ajoute un rappel"
    ]

    /// The content of Jarvis's own last reply that actually looks like
    /// authored content -- walks backward past any Jarvis reply that was
    /// itself answering an earlier "cree un document/note avec..."
    /// attempt (live testing showed one of these landing in history right
    /// before a retry, and naively taking "the last reply" resolved to
    /// that meta-commentary -- "Je ne peux pas creer le document
    /// moi-meme..." -- instead of the poem it was talking about). Trims
    /// at the first markdown horizontal rule if present, since a reply
    /// that writes creative content often follows it with a usage
    /// suggestion paragraph that shouldn't end up saved alongside it.
    private func resolvedLastJarvisReplyContent() -> String? {
        let history = projectStore.commandHistory
        for index in history.indices.reversed() {
            let entry = history[index]
            guard entry.role == .jarvis else { continue }
            if index > 0 {
                let precedingFolded = history[index - 1].text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                if Self.saveRequestPrefixes.contains(where: { precedingFolded.hasPrefix($0) }) {
                    continue
                }
            }
            let text = entry.text
            // Live testing showed the model formatting a reply as intro
            // -- --- -- actual content -- --- -- trailing suggestion (two
            // rules, not one): taking everything before the FIRST rule
            // cut the reply off right after the intro sentence, before
            // the real content ever appeared. The trailing suggestion is
            // always the LAST section, so search backwards instead --
            // that keeps any rule the model used to structure the actual
            // content and only strips the final one.
            if let ruleRange = text.range(of: "\n---\n", options: .backwards) {
                let head = String(text[..<ruleRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return head.isEmpty ? text : head
            }
            return text
        }
        return nil
    }

    private static func isIntroLine(_ line: String) -> Bool {
        let folded = line.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.hasPrefix("voici") || folded.hasPrefix("voila")
            || folded.contains("j'ai compose") || folded.contains("j'ai redige") || folded.contains("j'ai ecrit")
    }

    /// Splits resolved content into a short title (its first real line,
    /// after dropping a leading intro sentence like "Voici un poeme que
    /// j'ai compose pour vous :", and any blank/"---" divider line left
    /// over from that intro) and the rest as the body.
    private static func deriveTitleAndBody(from text: String) -> (title: String, body: String) {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, isIntroLine(first) {
            lines.removeFirst()
        }
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed == "---" else { break }
            lines.removeFirst()
        }
        let title = lines.first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.count > 60 ? nil : $0 } ?? "Document"
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body.isEmpty ? text : body)
    }

    /// Resolves `descriptor` (whatever follows "avec ") either as a
    /// referential phrase, a quoted literal, or a bare literal.
    private func resolvedContent(from descriptor: String) -> String? {
        let folded = descriptor.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if Self.referentialContentPhrases.contains(where: { folded.contains($0) }) {
            return resolvedLastJarvisReplyContent()
        }
        return Self.unquoted(descriptor) ?? descriptor
    }

    private static let notePrefixesWithContent = ["cree une note dans notes avec ", "ajoute une note dans notes avec "]

    private func bridgeNoteWithContentRequest(from request: String, normalized: String) -> (title: String, body: String)? {
        guard let prefix = Self.notePrefixesWithContent.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let descriptor = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !descriptor.isEmpty, let content = resolvedContent(from: descriptor) else { return nil }
        let (title, body) = Self.deriveTitleAndBody(from: content)
        return (title, body)
    }

    /// "cree un document APP avec CONTENU" -- app is everything before
    /// " avec ", content after. Distinct discriminator from
    /// `bridgeDocumentRequest` above (which needs " : " twice and no
    /// "avec"), so the two never both match the same message.
    private func bridgeDocumentWithContentRequest(from request: String, normalized: String) -> (app: String, title: String, body: String)? {
        guard normalized.hasPrefix("cree un document ") else { return nil }
        let remainder = String(request.dropFirst("cree un document ".count))
        guard let avecRange = remainder.range(of: " avec ", options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let app = String(remainder[..<avecRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let descriptor = String(remainder[avecRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !descriptor.isEmpty, let content = resolvedContent(from: descriptor) else { return nil }
        let (title, body) = Self.deriveTitleAndBody(from: content)
        return (app, title, body)
    }

    private static let sendMessagePrefixes = ["envoie un message a ", "envoie un sms a ", "envoie un imessage a "]

    private func bridgeSendMessageRequest(from request: String, normalized: String) -> (recipient: String, text: String)? {
        guard let prefix = Self.sendMessagePrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let remainder = String(request.dropFirst(prefix.count))
        guard let sepRange = remainder.range(of: " : ") else { return nil }
        let recipient = String(remainder[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let text = String(remainder[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty, !text.isEmpty else { return nil }
        return (recipient, text)
    }

    /// "mets X dans le presse-papiers" / "copie X dans le presse-papiers".
    /// Distinct suffix from `bridgeActivateAppName`'s "mets X au premier
    /// plan" (both share the "mets " prefix) -- mutually exclusive by the
    /// required suffix, so the two never collide regardless of check order.
    private func bridgeClipboardWriteText(from request: String, normalized: String) -> String? {
        let suffixes = [" dans le presse-papiers", " dans le presse papiers"]
        guard let suffix = suffixes.first(where: { normalized.hasSuffix($0) }) else { return nil }
        let prefixes = ["mets ", "copie "]
        guard let prefix = prefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let start = request.index(request.startIndex, offsetBy: prefix.count)
        let end = request.index(request.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let text = String(request[start..<end]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static let launchAppPrefixes = ["lance l'application ", "lance l'appli ", "ouvre l'application ", "ouvre l'appli "]

    private func bridgeLaunchAppName(from request: String, normalized: String) -> String? {
        guard let prefix = Self.launchAppPrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let name = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "passe sur X" is ambiguous between activating a macOS app (Bridge)
    /// and focusing a Jarvis project -- when X names an existing project,
    /// this defers (returns nil) so the project-focus trigger further down
    /// in `send()` handles it instead. Project focus is this app's own,
    /// more central feature; Bridge app activation only applies to real
    /// Mac apps, which a project never is.
    private func bridgeActivateAppName(from request: String, normalized: String) -> String? {
        func deferringToProject(_ name: String) -> String? {
            let foldedName = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let matchesProject = projectStore.projects.contains {
                $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == foldedName
            }
            return matchesProject ? nil : name
        }

        if normalized.hasPrefix("passe sur ") {
            let name = String(request.dropFirst("passe sur ".count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : deferringToProject(name)
        }
        let suffix = " au premier plan"
        if normalized.hasPrefix("mets ") && normalized.hasSuffix(suffix) {
            let start = request.index(request.startIndex, offsetBy: "mets ".count)
            let end = request.index(request.endIndex, offsetBy: -suffix.count)
            guard start < end else { return nil }
            let name = String(request[start..<end]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : deferringToProject(name)
        }
        return nil
    }

    /// Resolves a plain app name ("Safari", "Notes") to its bundle
    /// identifier by locating `<name>.app` in the two standard app
    /// directories -- LIMULE Bridge's `launchApp`/`activateApp` routes
    /// need a bundle ID, not a display name, and there's no public API to
    /// go the other direction without a deprecated call.
    private func resolveBundleID(forAppName name: String) -> String? {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        for directory in ["/Applications", "/System/Applications"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for item in items where item.hasSuffix(".app") {
                let appName = (item as NSString).deletingPathExtension
                if appName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == folded {
                    return Bundle(path: "\(directory)/\(item)")?.bundleIdentifier
                }
            }
        }
        return nil
    }

    /// Parses "X,Y" / "X, Y" / "X Y" into two `Double`s -- commas and
    /// semicolons are just normalized to spaces before splitting, so any
    /// of those separator styles works the same way.
    private func bridgeNumberPair(from text: String) -> (Double, Double)? {
        let normalized = text.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ";", with: " ")
        let parts = normalized.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return (x, y)
    }

    private static let clickPrefixes = ["clique en ", "clique aux coordonnees "]
    private static let doubleClickPrefixes = ["double-clique en ", "double clique en ", "double-clique aux coordonnees "]
    private static let rightClickPrefixes = ["clique droit en ", "clic droit en "]

    private func bridgeCoordinates(from request: String, normalized: String, prefixes: [String]) -> (Double, Double)? {
        guard let prefix = prefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        return bridgeNumberPair(from: String(request.dropFirst(prefix.count)))
    }

    /// "glisse de X,Y vers X2,Y2".
    private func bridgeDragCoordinates(from request: String, normalized: String) -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        guard normalized.hasPrefix("glisse de ") else { return nil }
        let remainder = String(request.dropFirst("glisse de ".count))
        guard let sepRange = remainder.range(of: " vers ", options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let fromText = String(remainder[..<sepRange.lowerBound])
        let toText = String(remainder[sepRange.upperBound...])
        guard let from = bridgeNumberPair(from: fromText), let to = bridgeNumberPair(from: toText) else { return nil }
        return (from.0, from.1, to.0, to.1)
    }

    private static let keyPrefixes = ["raccourci ", "appuie sur "]

    private func bridgeKeyCombo(from request: String, normalized: String) -> String? {
        guard let prefix = Self.keyPrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let combo = String(request.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return combo.isEmpty ? nil : combo
    }

    /// "defile de DX,DY".
    private func bridgeScrollDelta(from request: String, normalized: String) -> (Int, Int)? {
        guard normalized.hasPrefix("defile de ") else { return nil }
        guard let pair = bridgeNumberPair(from: String(request.dropFirst("defile de ".count))) else { return nil }
        return (Int(pair.0), Int(pair.1))
    }

    /// Generic "tape TEXTE" -- deliberately the last "tape "-prefixed
    /// trigger checked in `send()` (see the call site).
    private func bridgeRawTypeText(from request: String, normalized: String) -> String? {
        guard normalized.hasPrefix("tape ") else { return nil }
        let text = String(request.dropFirst("tape ".count)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// "va sur URL" or "ouvre URL dans le navigateur".
    private func bridgeBrowserNavigateURL(from request: String, normalized: String) -> String? {
        if normalized.hasPrefix("va sur ") {
            let url = String(request.dropFirst("va sur ".count)).trimmingCharacters(in: .whitespaces)
            return url.isEmpty ? nil : url
        }
        let suffix = " dans le navigateur"
        if normalized.hasPrefix("ouvre ") && normalized.hasSuffix(suffix) {
            let start = request.index(request.startIndex, offsetBy: "ouvre ".count)
            let end = request.index(request.endIndex, offsetBy: -suffix.count)
            guard start < end else { return nil }
            let url = String(request[start..<end]).trimmingCharacters(in: .whitespaces)
            return url.isEmpty ? nil : url
        }
        return nil
    }

    /// "clique sur CIBLE dans le navigateur" -- the required suffix is
    /// what distinguishes this from the generic `bridgePressTarget`.
    private func bridgeBrowserClickTarget(from request: String, normalized: String) -> String? {
        let suffix = " dans le navigateur"
        guard normalized.hasPrefix("clique sur "), normalized.hasSuffix(suffix) else { return nil }
        let start = request.index(request.startIndex, offsetBy: "clique sur ".count)
        let end = request.index(request.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let target = String(request[start..<end]).trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? nil : target
    }

    /// "tape TEXTE dans CIBLE du navigateur".
    private func bridgeBrowserTypeRequest(from request: String, normalized: String) -> (target: String, text: String)? {
        let suffix = " du navigateur"
        guard normalized.hasPrefix("tape "), normalized.hasSuffix(suffix) else { return nil }
        let start = request.index(request.startIndex, offsetBy: "tape ".count)
        let end = request.index(request.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let middle = String(request[start..<end])
        guard let sepRange = middle.range(of: " dans ", options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let text = String(middle[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let target = String(middle[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !target.isEmpty else { return nil }
        return (target, text)
    }

    private static let projectFocusPrefixes = [
        "passe sur ", "concentre-toi sur ", "concentre toi sur ", "focus sur ", "regarde le projet ", "ouvre "
    ]

    /// Requires an explicit focus-intent prefix before matching a project
    /// name -- returns the (normalized) remainder to search a project name
    /// within, or nil if the message doesn't start with one of these
    /// phrases at all.
    private func projectFocusRemainder(from normalized: String) -> String? {
        guard let prefix = Self.projectFocusPrefixes.first(where: { normalized.hasPrefix($0) }) else { return nil }
        let remainder = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? nil : remainder
    }

    /// "clique sur NOM" (+ optional " dans APP"). Distinct prefix from the
    /// existing "clique sur build" trigger (checked earlier in `send()`,
    /// so it's never reached here) and from jalon 5's coordinate click
    /// ("clique en X,Y").
    private func bridgePressTarget(from request: String, normalized: String) -> (title: String, app: String?)? {
        guard normalized.hasPrefix("clique sur ") else { return nil }
        var remainder = String(request.dropFirst("clique sur ".count)).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        var app: String?
        if let range = remainder.range(of: " dans ", options: [.caseInsensitive, .diacriticInsensitive]) {
            let trailing = String(remainder[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            app = trailing.isEmpty ? nil : trailing
            remainder = String(remainder[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !remainder.isEmpty else { return nil }
        return (remainder, app)
    }

    /// Always sent, independent of `focusedProject` (unlike the project-
    /// context system message below) so the chart capability never
    /// silently disappears when no project is focused.
    private static let chartCapabilityPrompt = """
    Quand ta reponse contient des donnees chiffrees comparables (plusieurs valeurs, une evolution, une repartition, un tableau), tu peux les visualiser avec un bloc ```chart contenant du JSON strict (pas de virgule finale, pas de commentaire). Format commun : {"type": "...", "style": "mono"|"dither", "title": "..." (optionnel), "data": ...}. Quinze types disponibles, chacun avec sa propre forme de "data" :

    - "bar", "line", "pie" : data est une liste de points {"label": "...", "value": nombre, "series": "..." (optionnel, pour grouper plusieurs series en line/bar)}.
    - "table" : data est {"columns": [...], "rows": [[...], ...]}.
    - "radar" : meme forme que bar/line (liste de points label/value/series) -- un axe par label distinct, un polygone par serie distincte ; ideal pour comparer plusieurs dimensions d'une meme chose (vitesse/memoire/latence...) ou plusieurs choses sur les memes dimensions.
    - "radial" : liste de points {"label": "...", "value": 0-100} -- un anneau concentrique par point, value = pourcentage. Ideal pour 2-4 metriques de progression/utilisation.
    - "funnel" : liste de points {"label": "...", "value": nombre}, ordonnee du plus grand au plus petit -- barres horizontales arrondies, largeur proportionnelle. Ideal pour un entonnoir de conversion (visites -> inscriptions -> actifs...).
    - "heatmap" : data est {"rows": [...], "columns": [...], "values": [[nombre, ...], ...]} -- une grille de cellules, intensite proportionnelle a la valeur. "values" doit avoir exactement rows.count lignes de columns.count nombres chacune.
    - "sparkline" : data est une liste de {"label": "...", "value": "texte affiche (ex: '42C', '1.2k RPM')", "trend": [nombre, ...]} -- une mini courbe de tendance par ligne. Ideal pour plusieurs metriques suivies dans le temps (temperatures, charges...).
    - "bubble" : data est une liste de {"label": "...", "x": nombre, "y": nombre, "size": nombre} -- nuage de points, taille du cercle proportionnelle a "size". Ideal pour une relation entre deux variables numeriques plus une troisieme (grandeur).
    - "treemap" : liste de points {"label": "...", "value": nombre} -- rectangles dont la surface est proportionnelle a value. Ideal pour une repartition de parts (allocation de budget/ressources).
    - "stream" : meme forme que bar/line (liste de points label/value/series) -- aires lissees superposees par serie. Ideal pour comparer l'evolution de plusieurs series avec un rendu plus expressif qu'un line chart classique.
    - "gauge" : liste de points {"label": "...", "value": 0-100} -- un demi-cercle (jauge/speedometre) par point. Ideal pour 1-3 indicateurs de charge/niveau isoles (pas une serie, juste l'etat actuel).
    - "waterfall" : liste de points {"label": "...", "value": nombre} -- le premier et le dernier point sont des totaux absolus (barre depuis zero), les points intermediaires sont des deltas (barres flottantes, cumulatives). Ideal pour un solde/bilan (depart, entrees, sorties, solde final).
    - "polar" : liste de points {"label": "...", "value": nombre} -- comme "radial" mais value est une grandeur brute normalisee par rapport au maximum du groupe, pas un pourcentage 0-100. Ideal pour comparer plusieurs grandeurs de meme nature en anneaux concentriques.
    - "range" : liste de {"label": "...", "min": nombre, "max": nombre} -- bande grisee entre deux courbes lissees (min et max). Ideal pour une fourchette/incertitude dans le temps (min-max journalier, intervalle de confiance).

    N'utilise jamais un chart pour un seul chiffre isole ou une reponse purement qualitative sans donnees a comparer, et ne mets pas plus d'un chart par reponse. Choisis le type le plus adapte a la forme reelle des donnees (ne force pas un bar chart la ou un radar/funnel/heatmap/treemap/waterfall serait plus lisible). Choisis le style selon la situation : "mono" pour des donnees precises et analytiques a comparer serieusement, "dither" pour un resume plus expressif ou une tendance qualitative. En cas de doute, prefere "mono".
    """

    /// Tells the model this capability exists AND that it can trigger it
    /// itself via `search_files`/`read_file`/`open_file`/`write_file`/
    /// `duplicate_file`/`delete_file`/`move_file` (see `toolCatalogJSON`).
    /// Before real function-calling existed, this deliberately withheld
    /// any way to trigger or see results, and the anti-hallucination rule
    /// only trusted content already verbatim in history -- both are
    /// updated for the fact that a genuine tool call now really does
    /// happen, which is the actual mechanism the rule is protecting.
    private static let fileCapabilityPrompt = """
    Jarvis a une capacite de gestion de fichiers locaux sur le Mac de l'utilisateur (n'importe ou, par nom ou par contenu) : chercher des fichiers, lire leur contenu texte, les ouvrir dans leur app par defaut, en ecrire/modifier, en dupliquer, en supprimer (vers la Corbeille) ou en deplacer/renommer. Une phrase directe de l'utilisateur declenche ces actions avant meme de t'atteindre (ex: "cherche un fichier X", "lis le fichier X") -- mais TU disposes aussi des memes actions comme outils (search_files, read_file, open_file, write_file, duplicate_file, delete_file, move_file) : utilise-les directement des que c'est pertinent, plutot que d'expliquer a l'utilisateur comment formuler sa demande. Ne dis donc jamais que Jarvis ne peut pas chercher, lire ou gerer de fichiers. La lecture de contenu couvre aussi les fichiers texte, .pages, .numbers, .docx/.doc/.rtf (conversion automatique en coulisses, Pages/Numbers peuvent brievement s'ouvrir pour l'export) -- mais cette conversion .pages/.numbers echoue parfois a cause d'un bug connu d'Apple dans l'automatisation de Pages/Numbers (rien a voir avec le fichier ni avec Jarvis) ; si ca arrive, le message d'erreur explique deja l'export manuel a faire (Fichier > Exporter vers > Texte/CSV dans l'app), ne le presente jamais comme une limite permanente de Jarvis. Keynote (.key) et les fichiers non textuels (images, videos, archives...) n'ont eux aucune conversion en texte disponible.

    Regle absolue, plus importante que tout le reste de ce paragraphe : tu n'as JAMAIS lu, vu ou recu le contenu d'un fichier, ni de resultat de recherche reel, sauf s'il provient d'un vrai appel a `read_file`/`search_files` (dans ce tour, ou deja verbatim dans une reponse precedente de Jarvis). Un message d'erreur ou d'echec dans l'historique n'est PAS un contenu ou un resultat -- ne le reinterprete jamais comme si l'action avait reussi. Si tu n'as pas ce contenu sous les yeux, appelle l'outil correspondant au lieu de deviner ou d'inventer -- n'affirme jamais qu'un fichier existe a tel chemin ou contient tel texte sans un vrai resultat d'outil ou un historique verbatim. Inventer un contenu, une citation ou un chemin est une erreur grave, pas une approximation acceptable.
    """

    /// Same shape as `fileCapabilityPrompt`, for LIMULE Bridge (mouse/
    /// keyboard/apps/clipboard/reminders/notes/messages/browser) -- the
    /// model can now trigger and observe these itself via the `bridge_*`
    /// tools in `toolCatalogJSON`. Computed (not a stored constant)
    /// because it appends a short digest of the most recent Bridge
    /// failures pulled from the Suivi, so a tool call doesn't blindly
    /// repeat something that just failed.
    private static func bridgeCapabilityPrompt() -> String {
        var prompt = """
        Jarvis peut piloter ce Mac via LIMULE Bridge (quand active et disponible) : cliquer/double-cliquer/clic droit/glisser a des coordonnees precises, taper du texte, appuyer sur un raccourci clavier, faire defiler, cliquer sur un element nomme, lire ou ecrire le presse-papiers, lister les ecrans et les fenetres ouvertes, inspecter l'arbre d'accessibilite d'une application, verifier la disponibilite de Bridge, annuler la derniere action, lancer ou activer une application, programmer un minuteur ou une alarme, creer un rappel (app Rappels), une note (app Notes) ou un document (uniquement dans TextEdit, Pages, Word ou Numbers -- pas Keynote, pas d'autre app : ne suggere et n'accepte jamais un autre nom d'app pour la creation de document), envoyer un message, prendre une capture d'ecran, et piloter un navigateur (naviguer vers une URL, lire le texte d'une page, cliquer, taper). TU disposes de ces memes actions comme outils (prefixes `bridge_*` dans le catalogue d'outils) : appelle-les directement des que c'est pertinent, y compris les actions destructrices ou irreversibles si l'utilisateur le demande clairement -- ne dis jamais que Jarvis ne peut pas faire ca.

        Regle absolue pour toute observation Bridge (presse-papiers, liste de fenetres ou d'ecrans, arbre d'accessibilite d'une application, texte d'une page web, capture d'ecran) : tu n'as JAMAIS vu cet ecran, ce presse-papiers ou cette page, sauf via un vrai appel a l'outil `bridge_*` correspondant (dans ce tour, ou deja verbatim dans une reponse precedente de Jarvis). N'invente jamais ce que contient le presse-papiers, une fenetre ou une page -- appelle l'outil au lieu de deviner.

        Quand tu rediges toi-meme un contenu (un poeme, un texte, une liste...) que l'utilisateur pourrait vouloir sauvegarder, tu peux directement appeler `bridge_create_note`/`bridge_create_document` avec ce texte comme corps -- pas besoin de demander a l'utilisateur de le reformuler dans une nouvelle commande.
        """

        let recentFailures = LocalDatabase.shared.loadLimuleBridgeAudit(limit: 30)
            .filter { $0.outcome == .failure }
            .prefix(5)
        if !recentFailures.isEmpty {
            let lines = recentFailures.map { "- \($0.summary) : \($0.detail)" }.joined(separator: "\n")
            prompt += "\n\nEchecs Bridge recents (tiens-en compte, ne suggere pas de repeter aveuglement une action qui vient d'echouer sans en tenir compte) :\n\(lines)"
        }
        return prompt
    }

    /// Real function-calling now covers most uncertainty (see
    /// `toolCatalogJSON`/`executeTool` below) -- this ```quiz block remains
    /// for the residual case a tool call can't resolve on its own: either a
    /// requested quiz (graded, "correct" set) or a disambiguation question
    /// (no right answer -- picking an option submits its literal text as
    /// the next message, so each option must be phrased as a complete,
    /// self-sufficient command exactly as the user would type it).
    private static let quizCapabilityPrompt = """
    Quand c'est utile, tu peux poser une question a choix multiples avec un bloc ```quiz contenant du JSON strict (pas de virgule finale, pas de commentaire) : {"title": "..." (optionnel), "questions": [{"prompt": "...", "options": ["...", "..."], "correct": 0 (optionnel), "explanation": "..." (optionnel)}]}. Deux usages distincts, jamais melanges dans le meme bloc :

    - Quiz a la demande sur un sujet ou un projet precis (l'utilisateur demande explicitement un quiz) : plusieurs questions possibles, avec "correct" (index de la bonne reponse, 0 = premiere option) rempli pour que Jarvis affiche juste/faux et un score.
    - Question de clarification quand TU n'es pas sur de ce que l'utilisateur veut dire (plusieurs fichiers, actions ou interpretations possibles) : une seule question, omets completement "correct", et redige chaque option comme une phrase de commande complete et litterale, exactement comme l'utilisateur la taperait lui-meme (ex: "Lis le fichier Rapport.pages" / "Lis le fichier Rapport.docx") -- des qu'une option est choisie, elle est envoyee telle quelle comme prochain message, donc elle doit se suffire entierement a elle-meme, sans dependre du contexte de la question.

    N'utilise ce bloc que quand une vraie ambiguite existe ou qu'un quiz est explicitement demande -- jamais pour une reponse ordinaire, et jamais plus d'un bloc ```quiz par reponse.
    """

    // MARK: - Function-calling: tool catalog + dispatcher

    /// One entry per `JarvisBridge.FileAction` case (8) and per
    /// non-file-route `LimuleBridgeAction` case (28) -- the 5 Bridge file
    /// routes stay excluded here too, same reason as the chat triggers:
    /// `LocalFileService` already covers the same ground with content
    /// search, tilde expansion, and Pages/Numbers conversion those Bridge
    /// routes lack. Every tool here calls the exact same `JarvisBridge`
    /// entry point a typed trigger would -- same permission/confirmation
    /// gate for the four destructive file actions, same Bridge audit --
    /// so "the AI can choose any action, including destructive ones" never
    /// bypasses a safety net already built for a human-typed trigger.
    private static let toolCatalogJSON = """
    [
      {"type":"function","function":{"name":"search_files","description":"Cherche des fichiers sur le Mac par nom ou par contenu.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
      {"type":"function","function":{"name":"list_directory","description":"Liste le contenu d'un dossier.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
      {"type":"function","function":{"name":"read_file","description":"Lit le contenu texte d'un fichier (txt, pages, numbers, docx, doc, rtf...).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
      {"type":"function","function":{"name":"open_file","description":"Ouvre un fichier dans son application par defaut.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
      {"type":"function","function":{"name":"write_file","description":"Ecrit ou remplace le contenu d'un fichier texte. Necessite l'activation de cette capacite (Connections > Actions fichiers) -- une alerte de confirmation apparait une seule fois.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
      {"type":"function","function":{"name":"duplicate_file","description":"Duplique un fichier. Necessite l'activation de cette capacite -- confirmation unique.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
      {"type":"function","function":{"name":"delete_file","description":"Envoie un fichier a la Corbeille. Necessite l'activation de cette capacite -- confirmation unique.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
      {"type":"function","function":{"name":"move_file","description":"Deplace ou renomme un fichier. Necessite l'activation de cette capacite -- confirmation unique.","parameters":{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"}},"required":["from","to"]}}},
      {"type":"function","function":{"name":"bridge_health","description":"Verifie si LIMULE Bridge est disponible.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"bridge_displays","description":"Liste les ecrans connectes.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"bridge_snapshot","description":"Inspecte l'arbre d'accessibilite de l'application au premier plan, ou d'une app nommee.","parameters":{"type":"object","properties":{"app":{"type":"string"}}}}},
      {"type":"function","function":{"name":"bridge_get_clipboard","description":"Lit le texte actuellement dans le presse-papiers.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"bridge_set_clipboard","description":"Ecrit du texte dans le presse-papiers.","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}},
      {"type":"function","function":{"name":"bridge_windows","description":"Liste les fenetres ouvertes.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"bridge_screenshot","description":"Prend une capture d'ecran.","parameters":{"type":"object","properties":{"display_id":{"type":"integer"}}}}},
      {"type":"function","function":{"name":"bridge_undo","description":"Annule la derniere action LIMULE Bridge.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"bridge_click","description":"Clique a des coordonnees d'ecran precises.","parameters":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}}},
      {"type":"function","function":{"name":"bridge_double_click","description":"Double-clique a des coordonnees d'ecran precises.","parameters":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}}},
      {"type":"function","function":{"name":"bridge_right_click","description":"Clic droit a des coordonnees d'ecran precises.","parameters":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}}},
      {"type":"function","function":{"name":"bridge_drag","description":"Glisser-deposer entre deux points d'ecran.","parameters":{"type":"object","properties":{"from_x":{"type":"number"},"from_y":{"type":"number"},"to_x":{"type":"number"},"to_y":{"type":"number"}},"required":["from_x","from_y","to_x","to_y"]}}},
      {"type":"function","function":{"name":"bridge_type","description":"Tape du texte dans le champ actuellement au premier plan.","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}},
      {"type":"function","function":{"name":"bridge_key","description":"Appuie sur un raccourci clavier, ex: cmd+s.","parameters":{"type":"object","properties":{"combo":{"type":"string"}},"required":["combo"]}}},
      {"type":"function","function":{"name":"bridge_scroll","description":"Fait defiler la vue au premier plan.","parameters":{"type":"object","properties":{"dx":{"type":"integer"},"dy":{"type":"integer"}},"required":["dx","dy"]}}},
      {"type":"function","function":{"name":"bridge_launch_app","description":"Lance une application macOS par son nom.","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}},
      {"type":"function","function":{"name":"bridge_activate_app","description":"Met une application macOS au premier plan par son nom.","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}},
      {"type":"function","function":{"name":"bridge_press","description":"Clique sur un element d'interface nomme (bouton, lien...) dans une application.","parameters":{"type":"object","properties":{"title":{"type":"string"},"app":{"type":"string"}},"required":["title"]}}},
      {"type":"function","function":{"name":"bridge_start_timer","description":"Lance un minuteur dans l'app Horloge.","parameters":{"type":"object","properties":{"seconds":{"type":"integer"}},"required":["seconds"]}}},
      {"type":"function","function":{"name":"bridge_start_alarm","description":"Programme une alarme dans l'app Horloge.","parameters":{"type":"object","properties":{"hour":{"type":"integer"},"minute":{"type":"integer"},"label":{"type":"string"}},"required":["hour","minute"]}}},
      {"type":"function","function":{"name":"bridge_create_reminder","description":"Cree un rappel dans l'app Rappels.","parameters":{"type":"object","properties":{"title":{"type":"string"},"list":{"type":"string"}},"required":["title"]}}},
      {"type":"function","function":{"name":"bridge_create_note","description":"Cree une note dans l'app Notes.","parameters":{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"}},"required":["title","body"]}}},
      {"type":"function","function":{"name":"bridge_create_document","description":"Cree un document. Uniquement dans TextEdit, Pages, Word ou Numbers -- jamais Keynote, jamais une autre app.","parameters":{"type":"object","properties":{"app":{"type":"string"},"title":{"type":"string"},"body":{"type":"string"}},"required":["app","title","body"]}}},
      {"type":"function","function":{"name":"bridge_send_message","description":"Envoie un message (SMS/iMessage) a un destinataire.","parameters":{"type":"object","properties":{"recipient":{"type":"string"},"text":{"type":"string"}},"required":["recipient","text"]}}},
      {"type":"function","function":{"name":"bridge_browser_navigate","description":"Navigue vers une URL dans le navigateur.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
      {"type":"function","function":{"name":"bridge_browser_text","description":"Lit le texte de la page web actuelle.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"bridge_browser_click","description":"Clique sur un element nomme dans la page web.","parameters":{"type":"object","properties":{"target":{"type":"string"}},"required":["target"]}}},
      {"type":"function","function":{"name":"bridge_browser_type","description":"Tape du texte dans un champ nomme de la page web.","parameters":{"type":"object","properties":{"target":{"type":"string"},"text":{"type":"string"}},"required":["target","text"]}}},
      {"type":"function","function":{"name":"github_repositories","description":"Liste les depots GitHub accessibles au compte connecte.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"git_status","description":"Lit l'etat Git du projet actif : branche et fichiers modifies.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"git_commit","description":"Commit tous les changements du projet actif avec le message indique. A appeler uniquement quand l'utilisateur demande explicitement un commit.","parameters":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}}},
      {"type":"function","function":{"name":"git_push","description":"Pousse la branche active du projet sur son remote. A appeler uniquement quand l'utilisateur demande explicitement un push.","parameters":{"type":"object","properties":{}}}},
      {"type":"function","function":{"name":"github_create_pull_request","description":"Cree une pull request de la branche active via GitHub CLI. A appeler uniquement lorsque l'utilisateur demande explicitement une PR.","parameters":{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"base":{"type":"string"}},"required":["title"]}}}
    ]
    """

    private func toolResultJSON(succeeded: Bool, message: String, content: String? = nil) -> String {
        var object: [String: Any] = ["succeeded": succeeded, "message": message]
        if let content { object["content"] = content }
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else {
            return "{\"succeeded\":false,\"message\":\"Erreur interne.\"}"
        }
        return json
    }

    private func numberArg(_ key: String, in args: [String: Any]) -> Double? {
        if let number = args[key] as? NSNumber { return number.doubleValue }
        if let double = args[key] as? Double { return double }
        if let int = args[key] as? Int { return Double(int) }
        return nil
    }

    private func intArg(_ key: String, in args: [String: Any]) -> Int? {
        numberArg(key, in: args).map { Int($0) }
    }

    /// Dispatches one function-calling request (a tool name + its raw JSON
    /// arguments string) to the exact same `JarvisBridge` entry point a
    /// typed trigger in `send()` would call -- same permission gate for
    /// file actions, same LIMULE Bridge audit, same `resolveFilePath`
    /// bare-name resolution. Returns a JSON string: for `search_files`/
    /// `bridge_screenshot` this is literally `FileListSpec`/`ScreenshotSpec`'s
    /// own `toJSON()`, reused as-is so `askLimule()` can re-parse the exact
    /// same payload afterward to splice in a rich chat block, without a
    /// second, separate result schema to keep in sync.
    @MainActor
    private func executeTool(name: String, argumentsJSON: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        func stringArg(_ key: String) -> String? { args[key] as? String }

        switch name {
        case "github_repositories":
            do {
                let repositories = try await GitHubService.repositories()
                let content = repositories.map { repository in
                    "\(repository.full_name) | \(repository.private ? "prive" : "public") | \(repository.html_url.absoluteString)"
                }.joined(separator: "\n")
                return toolResultJSON(succeeded: true, message: "\(repositories.count) depot(s) GitHub accessible(s).", content: content)
            } catch {
                return toolResultJSON(succeeded: false, message: error.localizedDescription)
            }

        case "git_status":
            guard let project = projectStore.focusedProject else { return toolResultJSON(succeeded: false, message: "Aucun projet actif.") }
            let result = GitCommandRunner.status(projectPath: project.rootPath)
            return toolResultJSON(succeeded: result.succeeded, message: result.succeeded ? "Etat Git de \(project.name)." : result.output, content: result.output)

        case "git_commit":
            guard let project = projectStore.focusedProject, let message = stringArg("message"), !message.isEmpty else {
                return toolResultJSON(succeeded: false, message: "Projet actif ou message de commit manquant.")
            }
            let result = GitCommandRunner.commitAll(projectPath: project.rootPath, message: message)
            return toolResultJSON(succeeded: result.succeeded, message: result.succeeded ? "Commit cree sur \(project.name)." : result.output, content: result.output)

        case "git_push":
            guard let project = projectStore.focusedProject else { return toolResultJSON(succeeded: false, message: "Aucun projet actif.") }
            let result = GitCommandRunner.push(projectPath: project.rootPath)
            return toolResultJSON(succeeded: result.succeeded, message: result.succeeded ? "Branche poussee pour \(project.name)." : result.output, content: result.output)

        case "github_create_pull_request":
            guard let project = projectStore.focusedProject, let title = stringArg("title"), !title.isEmpty else {
                return toolResultJSON(succeeded: false, message: "Projet actif ou titre de PR manquant.")
            }
            let result = GitCommandRunner.createPullRequest(
                projectPath: project.rootPath,
                title: title,
                body: stringArg("body"),
                base: stringArg("base")
            )
            return toolResultJSON(succeeded: result.succeeded, message: result.succeeded ? "Pull request creee pour \(project.name)." : result.output, content: result.output)

        case "search_files":
            guard let query = stringArg("query"), !query.isEmpty else { return toolResultJSON(succeeded: false, message: "query manquant.") }
            let searchLimit = 30
            let workspaceFolders = projectStore.workspaceItems
                .filter { $0.kind == .folder }
                .map { URL(fileURLWithPath: $0.path) }

            var entries: [LocalFileService.FileEntry] = []
            var truncated = false
            // Search the connected workspace's folders first, capped to the
            // full limit on its own -- a match there must never be crowded
            // out by unrelated results from the rest of the Mac. Only once
            // that's exhausted does the global scan fill whatever room is
            // left, skipping anything already found.
            if !workspaceFolders.isEmpty {
                let workspaceResult = await JarvisBridge.performFileAction(.search(query: query, roots: workspaceFolders, limit: searchLimit))
                entries = workspaceResult.entries ?? []
                truncated = workspaceResult.truncated
            }
            if entries.count < searchLimit {
                let globalResult = await JarvisBridge.performFileAction(.search(query: query, limit: searchLimit - entries.count))
                let alreadyFound = Set(entries.map(\.path))
                entries.append(contentsOf: (globalResult.entries ?? []).filter { !alreadyFound.contains($0.path) })
                truncated = truncated || globalResult.truncated
            }

            guard !entries.isEmpty else {
                return toolResultJSON(succeeded: true, message: "0 resultat(s)")
            }
            if let json = FileListSpec(
                query: query,
                entries: entries.map { .init(path: $0.path, isDirectory: $0.isDirectory, modifiedAt: $0.modifiedAt) },
                truncated: truncated
            ).toJSON() {
                lastSearchResults = entries
                lastReferencedFilePath = entries.first?.path
                return json
            }
            return toolResultJSON(succeeded: true, message: "\(entries.count) resultat(s)")

        case "list_directory":
            guard let path = stringArg("path") else { return toolResultJSON(succeeded: false, message: "path manquant.") }
            let result = await JarvisBridge.performFileAction(.list(path: resolveFilePath(path)))
            let names = (result.entries ?? []).map(\.path).joined(separator: "\n")
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: names.isEmpty ? nil : names)

        case "read_file":
            guard let path = stringArg("path") else { return toolResultJSON(succeeded: false, message: "path manquant.") }
            let resolved = resolveFilePath(path)
            lastReferencedFilePath = resolved
            let result = await JarvisBridge.performFileAction(.readText(path: resolved))
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: result.content)

        case "open_file":
            guard let path = stringArg("path") else { return toolResultJSON(succeeded: false, message: "path manquant.") }
            let resolved = resolveFilePath(path)
            lastReferencedFilePath = resolved
            let result = await JarvisBridge.performFileAction(.open(path: resolved))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "write_file":
            guard let path = stringArg("path"), let content = stringArg("content") else {
                return toolResultJSON(succeeded: false, message: "path/content manquant.")
            }
            let resolved = resolveFilePath(path)
            lastReferencedFilePath = resolved
            let result = await JarvisBridge.performFileAction(.write(path: resolved, content: content))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "duplicate_file":
            guard let path = stringArg("path") else { return toolResultJSON(succeeded: false, message: "path manquant.") }
            let result = await JarvisBridge.performFileAction(.duplicate(path: resolveFilePath(path)))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "delete_file":
            guard let path = stringArg("path") else { return toolResultJSON(succeeded: false, message: "path manquant.") }
            let result = await JarvisBridge.performFileAction(.delete(path: resolveFilePath(path)))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "move_file":
            guard let from = stringArg("from"), let to = stringArg("to") else {
                return toolResultJSON(succeeded: false, message: "from/to manquant.")
            }
            let resolvedFrom = resolveFilePath(from)
            let result = await JarvisBridge.performFileAction(.move(from: resolvedFrom, to: to))
            if result.succeeded { lastReferencedFilePath = to }
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_health":
            let result = await JarvisBridge.performLimuleObservation(.health)
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: result.content)

        case "bridge_displays":
            let result = await JarvisBridge.performLimuleObservation(.displays)
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: result.content)

        case "bridge_snapshot":
            let result = await JarvisBridge.performLimuleObservation(.snapshot(app: stringArg("app")))
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: result.content)

        case "bridge_get_clipboard":
            let result = await JarvisBridge.performLimuleObservation(.getClipboard)
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: result.content)

        case "bridge_set_clipboard":
            guard let text = stringArg("text") else { return toolResultJSON(succeeded: false, message: "text manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.setClipboard(text: text))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_windows":
            let result = await JarvisBridge.performLimuleObservation(.windows)
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: result.content)

        case "bridge_screenshot":
            let displayID = intArg("display_id", in: args)
            let result = await JarvisBridge.performScreenshotBridgeAction(displayID: displayID)
            if let path = result.localPath, let width = result.width, let height = result.height,
               let json = ScreenshotSpec(path: path, width: width, height: height, capturedAt: .now, displayID: displayID).toJSON() {
                return json
            }
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_undo":
            let result = await JarvisBridge.performLimuleBridgeAction(.undo)
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_click":
            guard let x = numberArg("x", in: args), let y = numberArg("y", in: args) else { return toolResultJSON(succeeded: false, message: "x/y manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.click(x: x, y: y))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_double_click":
            guard let x = numberArg("x", in: args), let y = numberArg("y", in: args) else { return toolResultJSON(succeeded: false, message: "x/y manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.doubleClick(x: x, y: y))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_right_click":
            guard let x = numberArg("x", in: args), let y = numberArg("y", in: args) else { return toolResultJSON(succeeded: false, message: "x/y manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.rightClick(x: x, y: y))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_drag":
            guard let fromX = numberArg("from_x", in: args), let fromY = numberArg("from_y", in: args),
                  let toX = numberArg("to_x", in: args), let toY = numberArg("to_y", in: args) else {
                return toolResultJSON(succeeded: false, message: "from_x/from_y/to_x/to_y manquant.")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_type":
            guard let text = stringArg("text") else { return toolResultJSON(succeeded: false, message: "text manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.type(text: text))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_key":
            guard let combo = stringArg("combo") else { return toolResultJSON(succeeded: false, message: "combo manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.key(combo: combo))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_scroll":
            guard let dx = intArg("dx", in: args), let dy = intArg("dy", in: args) else { return toolResultJSON(succeeded: false, message: "dx/dy manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.scroll(dx: dx, dy: dy))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_launch_app":
            guard let name = stringArg("name") else { return toolResultJSON(succeeded: false, message: "name manquant.") }
            guard let bundleID = resolveBundleID(forAppName: name) else {
                return toolResultJSON(succeeded: false, message: "Application introuvable : \(name).")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.launchApp(bundleID: bundleID))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_activate_app":
            guard let name = stringArg("name") else { return toolResultJSON(succeeded: false, message: "name manquant.") }
            guard let bundleID = resolveBundleID(forAppName: name) else {
                return toolResultJSON(succeeded: false, message: "Application introuvable : \(name).")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.activateApp(bundleID: bundleID))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_press":
            guard let title = stringArg("title") else { return toolResultJSON(succeeded: false, message: "title manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.press(title: title, app: stringArg("app")))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_start_timer":
            guard let seconds = intArg("seconds", in: args) else { return toolResultJSON(succeeded: false, message: "seconds manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.startTimer(seconds: seconds))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_start_alarm":
            guard let hour = intArg("hour", in: args), let minute = intArg("minute", in: args) else {
                return toolResultJSON(succeeded: false, message: "hour/minute manquant.")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.startAlarm(hour: hour, minute: minute, label: stringArg("label")))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_create_reminder":
            guard let title = stringArg("title") else { return toolResultJSON(succeeded: false, message: "title manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.createReminder(title: title, list: stringArg("list")))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_create_note":
            guard let title = stringArg("title"), let body = stringArg("body") else {
                return toolResultJSON(succeeded: false, message: "title/body manquant.")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.createNote(title: title, body: body))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_create_document":
            guard let app = stringArg("app"), let title = stringArg("title"), let body = stringArg("body") else {
                return toolResultJSON(succeeded: false, message: "app/title/body manquant.")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.createDocument(app: app, title: title, body: body))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_send_message":
            guard let recipient = stringArg("recipient"), let text = stringArg("text") else {
                return toolResultJSON(succeeded: false, message: "recipient/text manquant.")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.sendMessage(recipient: recipient, text: text))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_browser_navigate":
            guard let url = stringArg("url") else { return toolResultJSON(succeeded: false, message: "url manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.browserNavigate(url: url))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_browser_text":
            let result = await JarvisBridge.performLimuleObservation(.browserText)
            return toolResultJSON(succeeded: result.succeeded, message: result.message, content: result.content)

        case "bridge_browser_click":
            guard let target = stringArg("target") else { return toolResultJSON(succeeded: false, message: "target manquant.") }
            let result = await JarvisBridge.performLimuleBridgeAction(.browserClick(target: target))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        case "bridge_browser_type":
            guard let target = stringArg("target"), let text = stringArg("text") else {
                return toolResultJSON(succeeded: false, message: "target/text manquant.")
            }
            let result = await JarvisBridge.performLimuleBridgeAction(.browserType(target: target, text: text))
            return toolResultJSON(succeeded: result.succeeded, message: result.message)

        default:
            return toolResultJSON(succeeded: false, message: "Outil inconnu : \(name).")
        }
    }

    @MainActor
    private func askLimule() async {
        guard LimuleAPIService.hasKey else {
            reply(
                "Je peux traiter cette demande des que ma cle API Limule est connectee.",
                detail: "Ouvre Connexions > Limule API"
            )
            return
        }

        isThinking = true
        defer { isThinking = false }
        do {
            var messages: [LimuleAPIService.Message] = [
                .init(role: "system", content: Self.chartCapabilityPrompt),
                .init(role: "system", content: Self.fileCapabilityPrompt),
                .init(role: "system", content: Self.bridgeCapabilityPrompt()),
                .init(role: "system", content: Self.quizCapabilityPrompt)
            ]
            if let project = projectStore.focusedProject {
                let snapshot = projectStore.snapshot(for: project)
                let changedFilesSummary: String = {
                    guard snapshot.changedFileCount > 0 else { return "aucun" }
                    let preview = snapshot.changedFiles.joined(separator: ", ")
                    let remaining = snapshot.changedFileCount - snapshot.changedFiles.count
                    return remaining > 0 ? "\(preview) (et \(remaining) de plus)" : preview
                }()
                messages.append(.init(
                    role: "system",
                    content: "Tu es le cerveau de Jarvis, compagnon developpeur. Projet actif: \(project.name). Chemin: \(project.rootPath). Branche: \(snapshot.branch). Fichiers modifies (\(snapshot.changedFileCount)) : \(changedFilesSummary). Reponds en francais, clairement et sans pretendre avoir execute une action que tu n'as pas les moyens de faire. Actions reellement disponibles via Bridge, deja executees automatiquement quand l'utilisateur les demande directement (pas besoin de les proposer en option) : ouvrir le projet dans le Finder ou l'editeur, creer une branche git, ajouter une note horodatee dans NOTES.md (rappels de projet, choses a ne pas oublier). Un vrai rappel dans l'app Rappels macOS est aussi disponible via l'outil bridge_create_reminder (voir plus bas) -- ne dis jamais que Jarvis ne peut pas creer de rappel. Tu n'as en revanche aucun acces au calendrier ni aux notifications macOS natives. Formate ta reponse avec discernement : titres '## ', gras '**...**', italique '*...*', listes et separateur '---' quand cela rend une analyse plus agreable a lire. Tu peux employer un emoji pertinent en tete d'une section, avec retenue. Ne force jamais cette structure sur une confirmation courte.\n\nCalibre la longueur de ta reponse a la question : une question fermee ou une confirmation appelle 1 a 3 phrases directes, sans reformuler ce que Davy vient de dire ; une demande d'analyse, de plan ou de comparaison appelle un developpement structure ; par defaut reste concis. Face a un choix technique (quel fichier, quelle branche, quel outil, quelle approche), propose directement LA meilleure option avec sa raison en une phrase, plutot que de renvoyer la question a Davy -- il te corrigera si besoin. Ne pose une question ouverte que si l'ambiguite est reelle et qu'aucune option n'est clairement meilleure. Ne commence jamais une reponse par une salutation, sauf si Davy te salue explicitement. N'envoie jamais une formule ou une reponse proche de l'une de tes reponses recentes sans apporter une information nouvelle."
                ))
                if !UserPreferencesStore.notes.isEmpty {
                    messages.append(.init(
                        role: "system",
                        content: "Preferences durables notees par Davy sur la maniere de travailler avec lui (a respecter tant qu'elles ne sont pas explicitement changees) :\n\(UserPreferencesStore.notes)"
                    ))
                }
                if let memory = ProjectMemoryStore.context(for: project) {
                    messages.append(.init(role: "system", content: memory))
                }
            }
            if !projectStore.workspaceItems.isEmpty {
                let entries = projectStore.workspaceItems.map { item -> String in
                    let kind = item.kind == .folder ? "Dossier" : "Fichier"
                    return "- \(kind) : \(item.path)\n  Apercu : \(WorkspacePreviewComposer.preview(for: item))"
                }.joined(separator: "\n")
                messages.append(.init(
                    role: "system",
                    content: "Workspace connecte par Davy (glisse-depose, independant du projet focus) -- ces elements sont explicitement pertinents pour la demande en cours. Un apercu court de chacun suit ; pour le contenu complet d'un fichier ou explorer un dossier en detail, utilise tes outils read_file/search_files sur le chemin indique.\n\(entries)"
                ))
            }
            if let failures = AuditTrailEntry.recentFailuresDigest() {
                messages.append(.init(
                    role: "system",
                    content: "Journal automatique des echec recents. Ne repete pas aveuglement ces actions ; explique le blocage ou choisis une autre voie :\n\(failures)"
                ))
            }
            messages.append(contentsOf: projectStore.contextWindow().map {
                .init(role: $0.role == .jarvis ? "assistant" : "user", content: $0.text)
            })
            let (responseText, toolResults) = try await LimuleAPIService.completeWithTools(
                messages: messages,
                toolsJSON: Self.toolCatalogJSON,
                execute: { [self] name, argumentsJSON in
                    await executeTool(name: name, argumentsJSON: argumentsJSON)
                }
            )
            // search_files/bridge_screenshot's tool result IS the exact
            // FileListSpec/ScreenshotSpec JSON already shown to the model
            // (see `executeTool`) -- reparsed here only to confirm it's
            // well-formed before splicing it in as a rich chat block, so
            // the model never needs to know that format exists.
            var fullReply = responseText
            if projectStore.resemblesRecentJarvisReply(responseText) {
                let repairMessages = messages + [
                    .init(role: "assistant", content: responseText),
                    .init(role: "user", content: "Ta reponse vient de repeter une formulation recente. Reponds a nouveau, directement, sans salutation et avec une information ou une recommandation nouvelle.")
                ]
                fullReply = try await LimuleAPIService.complete(messages: repairMessages)
            }
            for result in toolResults {
                switch result.name {
                case "search_files" where FileListSpec.parse(from: result.resultJSON) != nil:
                    fullReply += "\n\n```filelist\n\(result.resultJSON)\n```"
                case "bridge_screenshot" where ScreenshotSpec.parse(from: result.resultJSON) != nil:
                    fullReply += "\n\n```screenshot\n\(result.resultJSON)\n```"
                default:
                    break
                }
            }
            reply(fullReply, detail: "Reponse du cerveau Limule")
        } catch {
            reply("Je n'ai pas pu joindre Limule : \(error.localizedDescription)", detail: "Connexion API")
        }
    }

    @MainActor
    private func resumeSummary(for project: JarvisProject) async {
        let snapshot = projectStore.snapshot(for: project)
        let build = projectStore.buildSnapshot(for: project)
        let recentFiles = projectStore.recentFiles(for: project)
        let facts = ResumeComposer.summary(project: project, git: snapshot, build: build, recentFiles: recentFiles, workspaceItems: projectStore.workspaceItems)

        guard LimuleAPIService.hasKey else {
            reply(facts, detail: "Resume local (Git + build)")
            return
        }

        isThinking = true
        defer { isThinking = false }
        do {
            let messages: [LimuleAPIService.Message] = [
                .init(
                    role: "system",
                    content: "Tu es Jarvis. Compose un court paragraphe en francais qui aide l'utilisateur a reprendre son travail, en te basant strictement sur les faits fournis, sans en inventer d'autres."
                ),
                .init(role: "user", content: facts)
            ]
            let response = try await LimuleAPIService.complete(messages: messages)
            reply(response, detail: "Reprise de travail - \(project.name)")
        } catch {
            reply(facts, detail: "Resume local (Limule indisponible)")
        }
    }

    @MainActor
    private func runBuildCheck(project: JarvisProject) async {
        await projectStore.checkBuild(project)
        switch projectStore.buildSnapshot(for: project).state {
        case .success:
            reply("Build de \(project.name) : succes.", detail: "Verifie a l'instant")
        case .failed(let detail):
            reply("Build de \(project.name) : echec.", detail: detail)
        case .notDetected:
            reply(
                "Je n'ai pas trouve d'outil de build pour \(project.name).",
                detail: "Aucun projet Xcode, package.json, Cargo.toml ou Makefile detecte"
            )
        case .running, .unknown:
            reply("La verification est toujours en cours pour \(project.name).", detail: nil)
        }
    }

    /// Every reply in the app funnels through here, so this is the single
    /// hook for "speak Jarvis's reply aloud" -- gated on
    /// `pendingReplyIsVoiceOrigin`, which is only true for the current turn
    /// when it started from a voice-filled prompt (never from typing).
    private func reply(_ text: String, detail: String?) {
        projectStore.appendCommandEntry(CommandEntry(role: .jarvis, text: text, detail: detail))
        guard pendingReplyIsVoiceOrigin else { return }
        Task { await projectStore.speak(text) }
    }
}

private struct CommandEntryView: View {
    @Environment(ProjectStore.self) private var projectStore
    let entry: CommandEntry
    var onSelectQuizOption: (String) -> Void = { _ in }
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(entry.role == .jarvis ? "JARVIS" : "YOU")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(entry.role == .jarvis ? .cyan : .secondary)
                Spacer()
                if entry.role == .jarvis {
                    Button {
                        if projectStore.voiceSessionState == .speaking {
                            projectStore.stopSpeaking()
                        } else {
                            Task { await projectStore.speak(entry.text) }
                        }
                    } label: {
                        Image(systemName: projectStore.voiceSessionState == .speaking ? "stop.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(projectStore.voiceSessionState == .speaking ? .red : .secondary)
                    .disabled(
                        (projectStore.voiceSessionState != .idle && projectStore.voiceSessionState != .speaking)
                            || !ElevenLabsService.hasKey
                            || ElevenLabsService.selectedVoiceID == nil
                    )
                    .help(projectStore.voiceSessionState == .speaking ? "Arreter la lecture" : "Ecouter")
                }
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
                .help(copied ? "Copie" : "Copier")
            }
            MarkdownMessageContent(
                text: entry.text,
                baseFont: entry.role == .jarvis ? .body.weight(.medium) : .body,
                onSelectQuizOption: onSelectQuizOption
            )
            if let detail = entry.detail {
                Label(detail, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.leading, entry.role == .user ? 52 : 0)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct CommandSuggestion: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

private struct WorkspaceItemChip: View {
    let item: WorkspaceItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.kind == .folder ? "folder" : "doc.text")
                .font(.caption2)
            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Retirer du workspace")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.08), in: Capsule())
        .help(item.path)
    }
}
