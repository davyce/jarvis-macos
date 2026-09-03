import AVFoundation
import Foundation

/// Thin wrapper around `AVAudioPlayer` for playing back ElevenLabs
/// text-to-speech audio.
final class VoicePlayback: NSObject, @unchecked Sendable {
    static let shared = VoicePlayback()

    enum PlaybackError: LocalizedError {
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .couldNotStart:
                return "macOS n'a pas pu demarrer la sortie audio de Jarvis. Verifie le peripherique de sortie dans Reglages Systeme > Son."
            }
        }
    }

    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private var meteringTimer: Timer?
    private var completionTimer: Timer?
    private var analysis: VoiceAudioAnalysis?

    /// Normalized (0...1) current playback loudness, refreshed ~30x/sec
    /// while speaking. Read from the Metal render thread (`LiquidOrbView`'s
    /// renderer, driving the orb's brightness in real time) as well as the
    /// main thread -- deliberately not actor-isolated since a torn/stale
    /// read of a single Float has no meaningful consequence for a purely
    /// visual value. Backed by `analysis` (an offline RMS pass over the
    /// decoded audio, time-indexed by playback position) when available,
    /// falling back to `AVAudioPlayer`'s own dB metering if decoding for
    /// analysis failed.
    nonisolated(unsafe) private(set) var currentLevel: Float = 0
    /// Zero-crossing-rate based brightness proxy for the audio currently
    /// under the playhead -- higher for sibilant/high-frequency-heavy
    /// sounds, lower for vowel/bass-heavy ones. A cheap, FFT-free stand-in
    /// for spectral centroid: distinct from loudness, so the orb can react
    /// to the voice's timbre and not just its volume. 0 when analysis is
    /// unavailable.
    nonisolated(unsafe) private(set) var currentTimbre: Float = 0
    /// Attack/release envelope over the level signal's onsets -- spikes on
    /// each syllable-like loudness jump and decays between them (see
    /// `VoiceAudioAnalyzer`), giving a pulse that tracks speech cadence
    /// rather than smoothed volume. 0 when analysis is unavailable.
    nonisolated(unsafe) private(set) var currentRhythm: Float = 0

    private override init() {
        super.init()
    }

    func play(_ data: Data, onFinish: @escaping () -> Void) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.volume = 1
        player.isMeteringEnabled = true
        guard player.prepareToPlay(), player.play() else {
            throw PlaybackError.couldNotStart
        }
        self.player = player
        self.onFinish = onFinish
        analysis = VoiceAudioAnalyzer.analyze(data: data)
        startMetering()
        scheduleCompletionFallback(for: player)
    }

    /// Stops playback and, unlike letting it finish naturally, must invoke
    /// `onFinish` itself -- `AVAudioPlayer` never calls
    /// `audioPlayerDidFinishPlaying` for an explicit `.stop()`, only for
    /// natural completion or a decode error. Without this, a caller
    /// awaiting playback (`ProjectStore.speak`'s continuation) would hang
    /// forever on a user-initiated stop.
    func stop() {
        completionTimer?.invalidate()
        completionTimer = nil
        stopMetering()
        player?.stop()
        player = nil
        analysis = nil
        let completion = onFinish
        onFinish = nil
        completion?()
    }

    private func startMetering() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            if let analysis = self.analysis,
               let level = analysis.level(at: player.currentTime),
               let timbre = analysis.timbre(at: player.currentTime),
               let rhythm = analysis.rhythm(at: player.currentTime) {
                self.currentLevel = level
                self.currentTimbre = timbre
                self.currentRhythm = rhythm
                return
            }
            // Analysis unavailable (e.g. an audio format `AVAudioFile`
            // couldn't decode) -- fall back to coarse dB-based loudness
            // only; timbre/rhythm just hold their last value.
            player.updateMeters()
            let power = player.averagePower(forChannel: 0)
            self.currentLevel = max(0, min(1, (power + 50) / 50))
        }
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        currentLevel = 0
        currentTimbre = 0
        currentRhythm = 0
    }

    /// AVAudioPlayer normally calls its delegate on completion. If the
    /// audio device disappears or CoreAudio fails to deliver that callback,
    /// the conversation must still recover instead of showing a permanent
    /// red stop button and never listening again.
    private func scheduleCompletionFallback(for player: AVAudioPlayer) {
        completionTimer?.invalidate()
        let timeout = max(3, player.duration + 2)
        completionTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self, weak player] _ in
            guard let self, let player, self.player === player else { return }
            self.stop()
        }
    }
}

extension VoicePlayback: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completionTimer?.invalidate()
        completionTimer = nil
        let completion = onFinish
        self.player = nil
        onFinish = nil
        DispatchQueue.main.async { [weak self] in
            self?.stopMetering()
            completion?()
        }
    }
}

/// Time-indexed audio features produced by `VoiceAudioAnalyzer`, sampled
/// during playback by `player.currentTime` rather than recomputed live --
/// a one-off offline pass over the whole (typically few-second) clip is
/// both cheaper and more accurate than trying to derive the same signals
/// from `AVAudioPlayer`'s coarse 30Hz dB metering.
private struct VoiceAudioAnalysis {
    let frameDuration: TimeInterval
    let level: [Float]
    let timbre: [Float]
    let rhythm: [Float]

    func level(at time: TimeInterval) -> Float? { sample(level, at: time) }
    func timbre(at time: TimeInterval) -> Float? { sample(timbre, at: time) }
    func rhythm(at time: TimeInterval) -> Float? { sample(rhythm, at: time) }

    private func sample(_ values: [Float], at time: TimeInterval) -> Float? {
        guard frameDuration > 0, !values.isEmpty else { return nil }
        let index = Int(time / frameDuration)
        return values[min(max(index, 0), values.count - 1)]
    }
}

/// Decodes a TTS clip to PCM and derives three per-frame features via
/// plain time-domain math (no FFT -- at a few hundred windows per clip,
/// a naive loop is already far faster than realtime, and it avoids an
/// entire class of Accelerate/FFT correctness pitfalls for a purely
/// cosmetic signal): loudness (RMS), a timbre proxy (zero-crossing rate),
/// and a rhythm/onset envelope (the positive derivative of loudness, with
/// an attack/release decay so each syllable reads as a distinct pulse).
private enum VoiceAudioAnalyzer {
    private static let windowSize = 1024
    private static let hopSize = 512
    private static let rhythmReleasePerHop: Float = 0.72

    static func analyze(data: Data) -> VoiceAudioAnalysis? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        do {
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let file = try AVAudioFile(forReading: tempURL)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0, file.length > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: AVAudioFrameCount(file.length)
                  )
            else { return nil }
            try file.read(into: buffer)
            guard let channelData = buffer.floatChannelData else { return nil }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > windowSize, channelCount > 0 else { return nil }

            var mono = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for i in 0..<frameCount { mono[i] += samples[i] }
            }
            if channelCount > 1 {
                let scale = Float(1) / Float(channelCount)
                for i in 0..<frameCount { mono[i] *= scale }
            }

            var rawLevel: [Float] = []
            var rawTimbre: [Float] = []
            var hopIndex = 0
            while hopIndex + windowSize <= frameCount {
                var sumSquares: Float = 0
                var crossings = 0
                var previousSample = mono[hopIndex]
                for offset in 0..<windowSize {
                    let sample = mono[hopIndex + offset]
                    sumSquares += sample * sample
                    if offset > 0, (sample >= 0) != (previousSample >= 0) {
                        crossings += 1
                    }
                    previousSample = sample
                }
                rawLevel.append(sqrt(sumSquares / Float(windowSize)))
                rawTimbre.append(Float(crossings) / Float(windowSize))
                hopIndex += hopSize
            }
            guard !rawLevel.isEmpty else { return nil }

            var rhythmEnvelope = [Float](repeating: 0, count: rawLevel.count)
            var previousLevel = rawLevel[0]
            var carry: Float = 0
            for i in 0..<rawLevel.count {
                let onset = max(0, rawLevel[i] - previousLevel)
                previousLevel = rawLevel[i]
                carry = max(onset, carry * rhythmReleasePerHop)
                rhythmEnvelope[i] = carry
            }

            return VoiceAudioAnalysis(
                frameDuration: Double(hopSize) / sampleRate,
                level: normalized(rawLevel),
                timbre: normalized(rawTimbre),
                rhythm: normalized(rhythmEnvelope)
            )
        } catch {
            return nil
        }
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        guard let maxValue = values.max(), maxValue > 0.0001 else {
            return values.map { _ in 0 }
        }
        return values.map { min(1, max(0, $0 / maxValue)) }
    }
}
