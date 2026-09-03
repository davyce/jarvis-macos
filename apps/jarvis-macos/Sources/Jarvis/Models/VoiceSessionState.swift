import Foundation

/// State of an active voice interaction (recording a spoken command,
/// transcribing it, or speaking a reply aloud). Deliberately separate from
/// `ProjectStore.isListening` (which only ever means "is ClapDetector
/// running") -- a voice session has its own lifecycle, triggered by the mic
/// button rather than the Presence toggle, and only shares the microphone
/// permission dependency with clap detection, not its start/stop calls.
enum VoiceSessionState: Equatable {
    case idle
    case recording
    case transcribing
    case speaking
}
