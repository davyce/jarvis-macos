🇬🇧 **English** · [🇫🇷 Français](README.fr.md)

# Jarvis

A native macOS AI assistant with persistent project memory, voice interaction, and contextual workspace tools — built as a local development companion, not a chatbot bolted onto an editor.

## What it does

- **Project context, not a blank prompt** — Jarvis tracks Git state (branch, last commit, changed files, recent activity), recently edited files, and build status (Xcode/npm/cargo/swift build/make) for whichever project has focus, updated live via FSEvents.
- **Persistent, multi-thread memory** — conversations are stored in a local SQLite database and survive an app restart; each call to the AI backend sends a bounded context window from the active thread instead of a memoryless single message.
- **Voice, hands-free** — a full speak → transcribe → respond → speak loop (ElevenLabs STT/TTS), with adaptive voice-activity detection so a pause mid-sentence doesn't cut the turn short. A double-clap gesture (local RMS heuristic, nothing recorded) brings Jarvis forward and starts a spoken greeting.
- **Git & GitHub from the assistant** — list accessible repos, inspect local Git state, commit and push the active project, or open a PR via `gh pr create` on request.
- **Scoped, permissioned system actions** — a small, named catalog of macOS Accessibility-API actions (e.g. "click Build in Xcode," "focus the editor") rather than an open-ended click/type primitive. Each capability is off by default, requires explicit confirmation on first use, and every execution — successful, failed, or declined — is written to a persistent audit log.
- **Workspace files** — drag files or folders onto the window to keep them attached to the conversation; only short previews are sent to the model by default, full content is read on demand through existing file tools.
- **Resilient credential storage** — API keys live in the macOS Keychain and self-repair if the app's Keychain authorization goes stale after a rebuild.
- **Cross-machine sync** — conversation history and project list stay consistent across machines via a small sync API; messages merge by ID so a late sync never drops history.

## Architecture

```
apps/jarvis-macos   Native SwiftUI app — the actual V1 implementation
services/*          Reserved structure for a future multi-process architecture
packages/           Shared protocols and event schemas
database/           Local SQLite migrations and schemas (chat history)
docs/                Architecture, API, security and protocol notes
tests/               Unit tests, integration tests, fixtures
```

V1 lives entirely inside `apps/jarvis-macos`: orchestration, file observation, and system actions are implemented directly there (`ProjectStore`, `ProjectWatcher`, `JarvisBridge`) rather than split into separate services yet.

## Stack

Swift, SwiftUI, Metal (particle/liquid-orb rendering), SQLite, macOS Accessibility API, ElevenLabs (speech-to-text / text-to-speech), Keychain Services.

## Testing

176 automated tests covering UI concurrency, microphone lifecycle, and Metal rendering stability.

## Status

This is a showcase snapshot of an active local-first macOS project, published for portfolio purposes. See [README.fr.md](README.fr.md) for the full, more detailed original documentation (French).

---

Built by [Davy Okemba](https://github.com/davyce).
