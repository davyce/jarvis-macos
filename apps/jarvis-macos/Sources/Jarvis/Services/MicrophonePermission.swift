import AVFoundation
import Foundation

/// macOS's microphone authorization is a single, system-wide, per-app
/// grant -- it isn't scoped per `AVAudioEngine` instance, so `ClapDetector`
/// and `VoiceRecorder` share this one request path rather than each
/// prompting independently.
enum MicrophonePermission {
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}
