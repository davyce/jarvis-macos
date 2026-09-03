<p align="center"><img src="docs/assets/logo.png" width="112" alt="Jarvis logo" /></p>

<p align="center">🇬🇧 **English** · [🇫🇷 Français](README.fr.md)</p>

# Jarvis

Jarvis is the local development companion of the Adansonia ecosystem.
It perceives the authorized work context, Limule reasons, and Limule Bridge
executes explicitly authorized actions.

## Architecture

```text
LIMULE  : intelligence, reasoning and durable memory
JARVIS  : local context, interaction, orchestration and presence
BRIDGE  : authorized system actions and connectors
```

## Organization

```text
apps/jarvis-macos  Native SwiftUI application for the first macOS version
services/core      Sessions, context, orchestration and project state
services/observer  File, Git, log and authorized process events
services/voice     Audio capture, STT, TTS and voice interruption
services/bridge    Limule Bridge client, permissions and actions
packages/          Protocols, event schemas and shared clients
database/          Local SQLite migrations and schemas (chat history)
docs/              Architecture, API, security and protocols
tests/             Unit tests, integration tests and fixtures
```

`services/*` and `packages/*` remain reserved locations for a future
multi-process architecture. V1 lives entirely inside `apps/jarvis-macos`:
orchestration, observation, and Bridge-action logic are implemented directly
there (`ProjectStore`, `ProjectWatcher`, `JarvisBridge`) rather than in
separate services.

## First product promise

> "Jarvis, where am I on this project, and help me pick the work back up."

V1 is deliberately centered on the authorized Adansonia projects, in this
order: Limule, ZOLA, then KOMPTA.

### What works today

- **Git context** — branch, last commit, changed files, activity over the
  last 7 days.
- **Recent files** — the most recently modified files of the focused
  project (excluding `.git`, `node_modules`, `build`, etc.).
- **Live observation** — the focused project is watched via FSEvents; the
  dashboard updates itself when a file changes, with no need to click
  Refresh.
- **Build status** — tool detection (Xcode, npm, cargo, swift build, make),
  on-demand execution, macOS notifications on success/failure transitions.
- **Contextualized Limule conversations** — several distinct discussion
  threads (persisted in local SQLite, surviving a full app restart), with a
  "new conversation" button and history to go back to a previous thread.
  Each call to the Limule API sends a bounded context window (the latest
  exchanges of the active thread) rather than an isolated, memoryless
  message. Real markdown rendering (bold, italics, headings, copyable code
  blocks) instead of raw asterisks. The renderer also recognizes lists,
  quotes, and separators, with a clear visual hierarchy for longer analyses.
- **Per-project working memory** — `ProjectMemoryStore` writes explicit
  local context to `Application Support/Jarvis/project-memory.json`: the
  last request, last response, and recent decisions for each project. This
  memory is visible and erasable from Connections, then sent to the Limule
  brain during subsequent conversations.
- **Durable preferences** — a "Preferences" section at the top of
  Connections: free-form notes (`UserPreferencesStore`, persisted locally)
  on how to work with Jarvis, injected into every call to the Limule brain
  as long as they remain written — no automatic extraction, Davy writes
  them himself. The system prompt also calibrates response length to the
  question (short for a confirmation, developed for an analysis) and
  favors a direct recommendation over an open question when one option is
  clearly better.
- **Learning from real failures** — failures of system, file, and LIMULE
  Bridge actions were already audited; Jarvis now builds a digest from them
  that is automatically added to the brain's context. It can therefore
  avoid proposing again an action that just genuinely failed, without
  inventing a false memory.
- **Robust project context** — a request that clearly targets a known
  project (for example "for ZOLA" or "in Limule") switches the focus before
  being sent to the brain. Simple comparisons don't change the focus by
  accident. An anti-loop safeguard detects a long response too similar to a
  recent one and asks the brain to rephrase.
- **Git and GitHub from the brain** — the tools exposed to Limule cover
  listing the GitHub repositories accessible with the connected token, the
  local Git state, and committing and pushing the active project. An
  explicit PR request can call `gh pr create` on the active branch; GitHub
  CLI must be installed and authenticated on the Mac for this last
  operation.
- **Controlled Bridge actions** — opening Finder/editor, creating a git
  branch, centralized in `JarvisBridge` rather than scattered across the
  UI.
- **Presence** — the Jarvis icon always stays visible in the menu bar, with
  a status badge (build failure, active listening) instead of being
  replaced. Optional double-clap listening (local RMS heuristic, several
  accepted rhythm tolerances, nothing is recorded) to bring Jarvis to the
  foreground even when minimized or closed and trigger a spoken greeting
  (`ProjectStore.greetFromClap`); the greeting flows directly into
  hands-free conversation mode (below), with no extra click.
- **Thinking animation** — a particle orb (Canvas/SwiftUI rendering) with a
  "solving" state (active ripple) while Jarvis composes its response. A
  second liquid-glass orb (Metal rendering, `LiquidOrbView`) reacts in real
  time to the level/timbre/rhythm of the voice while a spoken response is
  played back.
- **Resilient keychain** — API key storage (Limule, GitHub) repairs itself
  automatically if its macOS authorization goes stale after a rebuild,
  instead of repeatedly asking for confirmation.
- **Cloud sync (Limule)** — conversation history and the project list stay
  identical across multiple machines via Limule's `/api/v1/state/*` API
  (same `lim_...` key as chat, `state` scope). Last-write-wins for projects
  and conversation metadata, but messages merge by id (never deleted) so a
  late sync never loses history. Settings and Bridge permissions stay local
  to each machine. See `WorkspaceSyncService`, "Synchronization" section of
  Connections.

### System actions (Bridge)

A separate effort from the four historical Bridge actions (Finder, editor,
git branch, note): those remain direct file/process operations, with no
particular risk. The system actions below, on the other hand, actually
drive the Mac (click, keyboard input, bringing to foreground) via the
macOS Accessibility API (`AXUIElement` to find/click a control and bring a
window to the foreground, `CGEvent` to simulate keyboard input) — hence a
much stricter framework.

- **Scope closed from the start** — no "click anywhere" or "type anything
  anywhere." The catalog (`SystemActionCapability`) fixes named, concrete
  targets: Xcode's *Build* button, the VS Code/Xcode window, the currently
  focused field of either. Adding a capability means adding a case to the
  catalog, not exposing a generic primitive (coordinates, arbitrary bundle
  ID) to the caller.
- **macOS Accessibility permission** — checked via `AXIsProcessTrusted` on
  first use; if missing, Jarvis triggers the system prompt and can then
  directly reopen System Settings > Privacy & Security > Accessibility
  (`AccessibilityPermission`).
- **Per-action permission** — each capability is disabled by default and is
  activated individually in Connections > "System actions (Bridge)"
  (`SystemActionPermissionStore`, persisted in `UserDefaults`).
- **Explicit confirmation before first execution** — a capability that is
  enabled but never yet used triggers a macOS alert ("Allow <action>?",
  with the exact target) before acting; never silent like the four
  historical actions. Disabling an action clears its confirmation:
  re-enabling it asks again.
- **Persistent audit log** — every execution (successful, failed, or
  declined at confirmation) is recorded in the same local SQLite database
  as chat history (`system_action_audit_log` in
  `LocalDatabase`/`jarvis.sqlite3`): timestamp, capability, target, result.
  Viewable in Connections > "Activity log" (merged with the LIMULE Bridge
  log below).

Capabilities available today:

| Capability | What it does | Trigger in Jarvis |
| --- | --- | --- |
| Click Build in Xcode | Looks for the "Build" button in the foreground Xcode window and clicks it | "click build" |
| Bring the editor to the foreground | Activates VS Code or Xcode (whichever is running) | "focus editor" / "editor to foreground" |
| Type into the editor's active field | Simulates keyboard input into the focused field of VS Code/Xcode, already in the foreground | "type in the editor \<text\>" |

### LIMULE Bridge

A separate effort from the AXUIElement system actions above: a client for
**LIMULE Bridge**, the local HTTP server (`http://127.0.0.1:8765`) that the
LIMULE app already runs on this Mac for its own machine control (click,
keyboard, clipboard, windows, files, browser, messages, reminders...).
Jarvis doesn't build it, it connects to it.

- **Shared auth, never generated** — the local token comes from a Keychain
  item shared between Jarvis and LIMULE via a Keychain Access Group
  (`264EZSM3VZ.com.adansonia.limule.shared`, same Apple Developer Team ID).
  `LimuleBridgeAuthentication` only *reads* it (`SecItemCopyMatching`);
  only the LIMULE app itself creates it. If LIMULE has never run on this
  machine, the token is simply not found and Bridge is unavailable — never
  a blocking error. Requires that Jarvis be signed with the real Team ID
  (`project.yml`, `Jarvis.entitlements`) rather than ad-hoc.
- **Full coverage, not a subset** — `LimuleBridgeAction` covers the ~31
  documented routes (click, keyboard, files, browser, messages, reminders,
  timers...), each with a hand-written audit summary (never the full
  content of a file or message).
- **No per-action confirmation — a deliberate decision.** Unlike the
  AXUIElement system actions, LIMULE Bridge itself has no built-in
  safeguard: it executes whatever it is asked as soon as it receives the
  right token. Adding a blocking confirmation on Jarvis's side was
  considered and explicitly set aside for now: the **activity log** (audit
  log) serves that purpose instead — every call, successful or not, is
  recorded there before the result is returned. A single master switch
  (`LimuleBridgeSettings`, disabled by default, "LIMULE Bridge" section of
  Connections) remains the only brake on Jarvis's side.
- **Unified activity log** — the LIMULE Bridge log
  (`limule_bridge_audit_log`) and the AXUIElement system-action log are
  merged into a single chronological list (`AuditTrailEntry`) in
  Connections > "Activity log," with a badge distinguishing the origin of
  each entry. Collapsible: 10 entries shown by default, "Show more" button
  to reveal further ones rather than an always-expanded full history.

### Workspace (connected files and folders)

Dragging and dropping multiple files and/or folders onto the Jarvis window
connects them to the conversation persistently — independent of the
focused project, until explicitly removed.

- **Removable chips** — each connected item appears as a chip above the
  input field (`WorkspaceItemChip`), with a button to remove it. The list
  is persisted locally (`WorkspaceItem`, same `UserDefaults` mechanism as
  the project list).
- **Multi-drop and image/document separation** — a single drag-and-drop can
  contain several files and folders at once. An image continues to be
  displayed directly in the chat (```screenshot``` fence, as before);
  everything else (documents, folders) joins the workspace instead of
  being printed as a one-off message.
- **Preview instead of full content** — on every call to the Limule brain,
  a short preview of each connected item (start of the file, or list of
  top-level entries of a folder — `WorkspacePreviewComposer`) is included
  in the system prompt, never the full content. The model reads the detail
  on demand via its existing `read_file`/`search_files` tools — a hybrid
  approach chosen over full preloading (doesn't scale) or purely on-demand
  access (the model "sees" nothing without explicitly knowing what to look
  for).
- **Workspace-prioritized search** — `search_files` searches the connected
  folders first (up to the full result limit on that single pass), then
  fills in with the rest of the Mac only if there's room left — a relevant
  workspace result can no longer be pushed out by the truncation of a
  global search.
- **Also visible outside the chat** — the connected workspace appears in
  the "Where am I" summary (`ResumeComposer`), not just in the composer's
  chips.

### Voice pipeline (ElevenLabs)

Voice commands and spoken responses, via the ElevenLabs REST API
(`ElevenLabsService`, auth via `xi-api-key` header, distinct from the
Bearer auth used by Limule/GitHub).

- **Hands-free conversation mode** — a click on the microphone (or a clap
  greeting that ends) starts a loop
  (`JarvisCommandView.runConversationLoop`): listening with automatic stop
  on silence, sending the transcribed text as if it had been typed,
  waiting for the spoken response to finish, then listening again — until
  an explicit click on the microphone to stop. No need to restart
  recording on every turn.
- **End-of-sentence detection (VAD)** — `VoiceRecorder.recordUntilSilence`
  relies on a dedicated `VoiceActivityDetector` (adaptive RMS/noise floor,
  same principle as clap detection but inverted: sustained silence rather
  than a brief peak), with distinct thresholds for starting and for
  continuing a sentence — a weaker syllable at the end of a sentence
  doesn't cut the turn. Silence must last 3.2s to close a turn, so as to
  survive natural thinking pauses in a long sentence.
- **Capture and transcription** — `VoiceRecorder` (a dedicated
  `AVAudioEngine`, distinct from the one used for clap detection, paused
  during recording then resumed if it was active) captures in native CAF
  then converts to 16 kHz mono PCM before sending to
  `POST /v1/speech-to-text` (`file_format=pcm_s16le_16`, `scribe_v2`
  model) — more reliable than letting format inference guess the
  container.
- **Spoken response only if the question was spoken** — `ProjectStore`
  tracks a separate voice session state (`VoiceSessionState`: idle,
  recording, transcribing, speaking). A message typed on the keyboard
  never triggers audio playback. When the question came from the
  microphone, Jarvis's response is sent to
  `POST /v1/text-to-speech/{voice_id}/stream` (low-latency
  `eleven_flash_v2_5` model) and played via `VoicePlayback`
  (`AVAudioPlayer`, with a fallback timer if CoreAudio never fires the
  end-of-playback event), with the `LiquidOrbView` orb displayed during
  playback.
- **Key and voice in Connections** — "ElevenLabs (voice)" section: API key
  (Keychain, same service as Limule/GitHub/Google), voice picker populated
  via `GET /v1/voices`, disconnect.

### Not yet done

- `services/*` and `packages/*` as actually separate processes/packages.
