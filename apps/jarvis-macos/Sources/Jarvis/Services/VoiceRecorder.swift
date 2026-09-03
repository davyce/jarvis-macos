import AVFoundation
import Foundation

/// Records microphone input to a local WAV file for later ElevenLabs STT
/// upload. Uses its own `AVAudioEngine` instance, separate from
/// `ClapDetector`'s -- both can technically tap the default input
/// simultaneously on macOS, but `ClapDetector` is explicitly paused for the
/// duration of a recording (avoiding two consumers processing the same mic
/// stream at once) and resumed afterward if it was running.
final class VoiceRecorder: @unchecked Sendable {
    static let shared = VoiceRecorder()

    enum RecorderError: LocalizedError {
        case micPermissionDenied
        case alreadyRecording
        case setupFailed(String)

        var errorDescription: String? {
            switch self {
            case .micPermissionDenied:
                return "Acces micro refuse. Autorise Jarvis dans Reglages Systeme > Confidentialite et securite > Microphone."
            case .alreadyRecording:
                return "Un enregistrement est deja en cours."
            case .setupFailed(let message):
                return "Impossible de demarrer l'enregistrement : \(message)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private let audioWriteQueue = DispatchQueue(label: "com.adansonia.jarvis.voice-recorder.write")
    private var isRecording = false
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var wasClapListeningBeforeRecording = false
    /// Set only while a `recordUntilSilence` continuation is pending;
    /// invoking it force-resumes that call early. See `cancelListening()`.
    private var activeSilenceCancellation: (() -> Void)?
    private var pendingSilenceCancellation = false
    private var isPreparingSilenceRecording = false
    private var finalizationError: String?

    init() {}

    var isCurrentlyRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRecording
    }

    func start() async throws {
        stateLock.lock()
        if isRecording {
            stateLock.unlock()
            throw RecorderError.alreadyRecording
        }
        stateLock.unlock()

        guard await MicrophonePermission.requestAccessIfNeeded() else {
            throw RecorderError.micPermissionDenied
        }

        wasClapListeningBeforeRecording = ClapDetector.shared.isListening
        if wasClapListeningBeforeRecording {
            ClapDetector.shared.stop()
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-voice-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            audioWriteQueue.sync { audioFile = file }
            recordingURL = url
        } catch {
            resumeClapDetectorIfNeeded()
            throw RecorderError.setupFailed(error.localizedDescription)
        }

        // A cancelled silence turn can briefly leave its tap attached.
        // AVAudioEngine aborts the process if a second tap is installed first.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.audioWriteQueue.sync {
                try? self.audioFile?.write(from: buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioWriteQueue.sync { audioFile = nil }
            recordingURL = nil
            resumeClapDetectorIfNeeded()
            throw RecorderError.setupFailed(error.localizedDescription)
        }

        stateLock.lock()
        pendingSilenceCancellation = false
        finalizationError = nil
        isRecording = true
        stateLock.unlock()
    }

    /// Stops recording and returns the recorded WAV file's URL, or `nil` if
    /// nothing was actually recording. The caller owns cleaning up the file
    /// once it's done uploading it.
    func stop() -> URL? {
        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()

        // Do this before advertising the recorder as idle. CoreAudio aborts
        // the whole process if a new turn installs a second tap while the
        // old one is still attached.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stateLock.lock()
        isRecording = false
        stateLock.unlock()
        let nativeURL = recordingURL
        // `removeTap` does not guarantee that a callback already in flight
        // has returned. Waiting on the same serial queue closes AVAudioFile
        // only after its final write, allowing it to finalize the WAV header
        // before ElevenLabs reads the URL.
        audioWriteQueue.sync { audioFile = nil }
        recordingURL = nil

        resumeClapDetectorIfNeeded()
        guard let nativeURL else { return nil }
        do {
            let pcmURL = try Self.convertToStandardPCM(nativeURL)
            try? FileManager.default.removeItem(at: nativeURL)
            return pcmURL
        } catch {
            try? FileManager.default.removeItem(at: nativeURL)
            stateLock.lock()
            finalizationError = error.localizedDescription
            stateLock.unlock()
            return nil
        }
    }

    private func resumeClapDetectorIfNeeded() {
        guard wasClapListeningBeforeRecording else { return }
        wasClapListeningBeforeRecording = false
        try? ClapDetector.shared.start()
    }

    /// Records one utterance with silence-based auto-stop, for hands-free
    /// conversation mode -- unlike `start()`/`stop()` (a manual two-click
    /// toggle), the caller never has to click again to end the turn.
    /// Returns the recorded WAV file's URL, or `nil` if nothing was ever
    /// said (silence/room noise the whole time, so nothing worth
    /// transcribing).
    ///
    /// End-of-utterance detection reuses `ClapDetector`'s RMS-per-buffer /
    /// adaptive-noise-floor approach, but inverted: instead of firing on a
    /// brief loud transient, it fires once the level has stayed BELOW the
    /// speech threshold for `silenceTimeout` -- and only after real speech
    /// was actually detected at least once, gated by `minRecordingDuration`
    /// so it can never fire during the room-tone silence before the user
    /// has even started talking. `maxDuration` is a safety cap in case the
    /// room is noisy enough that silence is never detected.
    ///
    /// `silenceTimeout` started at 1.2s; live testing (31 août 2026) cut
    /// the user off mid-sentence on an ordinary breath/thinking pause
    /// inside a longer sentence -- natural conversational pauses (not
    /// "I'm done talking") can comfortably run past a second. Widened to
    /// 3.2s, trading a little extra latency after the user actually
    /// finishes for not truncating what they're still saying.
    func recordUntilSilence(
        silenceTimeout: TimeInterval = 3.2,
        minRecordingDuration: TimeInterval = 0.5,
        maxDuration: TimeInterval = 120,
        speechStartTimeout: TimeInterval = 15
    ) async throws -> URL? {
        stateLock.lock()
        if isRecording || isPreparingSilenceRecording {
            stateLock.unlock()
            throw RecorderError.alreadyRecording
        }
        isPreparingSilenceRecording = true
        pendingSilenceCancellation = false
        finalizationError = nil
        stateLock.unlock()

        guard await MicrophonePermission.requestAccessIfNeeded() else {
            stateLock.lock()
            isPreparingSilenceRecording = false
            stateLock.unlock()
            throw RecorderError.micPermissionDenied
        }

        wasClapListeningBeforeRecording = ClapDetector.shared.isListening
        if wasClapListeningBeforeRecording {
            ClapDetector.shared.stop()
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-voice-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            audioWriteQueue.sync { audioFile = file }
            recordingURL = url
        } catch {
            stateLock.lock()
            isPreparingSilenceRecording = false
            stateLock.unlock()
            resumeClapDetectorIfNeeded()
            throw RecorderError.setupFailed(error.localizedDescription)
        }

        stateLock.lock()
        isPreparingSilenceRecording = false
        isRecording = true
        stateLock.unlock()

        let startedAt = ProcessInfo.processInfo.systemUptime
        let silenceState = VoiceActivityDetector(
            startedAt: startedAt,
            silenceTimeout: silenceTimeout,
            minRecordingDuration: minRecordingDuration,
            maxDuration: maxDuration,
            speechStartTimeout: speechStartTimeout
        )
        // A cancelled turn can leave the previous tap attached for one
        // run-loop turn. Removing it defensively prevents `installTap` from
        // throwing an Objective-C exception, which cannot be caught by
        // Swift and used to terminate Jarvis outright.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.audioWriteQueue.sync {
                try? self.audioFile?.write(from: buffer)
            }
            silenceState.ingest(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            stateLock.lock()
            isPreparingSilenceRecording = false
            isRecording = false
            stateLock.unlock()
            audioWriteQueue.sync { audioFile = nil }
            recordingURL = nil
            resumeClapDetectorIfNeeded()
            throw RecorderError.setupFailed(error.localizedDescription)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            var resumed = false
            let resumeOnce: (URL?) -> Void = { [weak self] result in
                guard !resumed else { return }
                resumed = true
                self?.stateLock.lock()
                self?.activeSilenceCancellation = nil
                self?.pendingSilenceCancellation = false
                self?.stateLock.unlock()
                continuation.resume(returning: result)
            }
            silenceState.onSilenceDetected = { [weak self] in
                // Deferred off the audio thread the tap callback itself
                // runs on -- `stop()` removes this very tap, which the
                // engine doesn't support doing reentrantly from inside the
                // tap's own callback.
                DispatchQueue.main.async {
                    resumeOnce(self?.stop())
                }
            }
            silenceState.onNoSpeechDetected = { [weak self] in
                DispatchQueue.main.async {
                    self?.stateLock.lock()
                    self?.finalizationError = "Jarvis ne recoit aucun son du microphone. Verifie la source d'entree dans Reglages Systeme > Son."
                    self?.stateLock.unlock()
                    _ = self?.stop()
                    resumeOnce(nil)
                }
            }
            let cancellation: () -> Void = { [weak self] in
                DispatchQueue.main.async {
                    _ = self?.stop()
                    resumeOnce(nil)
                }
            }
            stateLock.lock()
            activeSilenceCancellation = cancellation
            let shouldCancelImmediately = pendingSilenceCancellation
            pendingSilenceCancellation = false
            stateLock.unlock()
            if shouldCancelImmediately {
                cancellation()
            }
        }
    }

    /// Cancels an in-progress `recordUntilSilence` call early, discarding
    /// whatever was recorded so far -- used when the user explicitly stops
    /// hands-free conversation mode mid-turn, since silence alone won't cut
    /// it if they're still actively talking (or the room is just noisy). A
    /// no-op if nothing is currently listening this way.
    func cancelListening() {
        stateLock.lock()
        let cancellation = activeSilenceCancellation
        if cancellation == nil, isRecording || isPreparingSilenceRecording {
            pendingSilenceCancellation = true
        }
        stateLock.unlock()
        cancellation?()
    }

    func consumeFinalizationError() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let error = finalizationError
        finalizationError = nil
        return error
    }

    /// Rewrites the engine-native CAF capture as raw little-endian, mono,
    /// 16-bit PCM at 16 kHz. ElevenLabs accepts this format explicitly via
    /// `file_format=pcm_s16le_16`, avoiding container/header interpretation.
    private static func convertToStandardPCM(_ sourceURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        guard source.length > 0 else {
            throw RecorderError.setupFailed("aucun echantillon audio n'a ete enregistre")
        }

        let sourceFormat = source.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw RecorderError.setupFailed("impossible de preparer la conversion mono 16 kHz")
        }
        let pcmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-voice-standard-\(UUID().uuidString)")
            .appendingPathExtension("pcm")

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(source.length)
        ) else {
            throw RecorderError.setupFailed("impossible de creer le tampon audio source")
        }
        try source.read(into: inputBuffer)

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw RecorderError.setupFailed("impossible de creer le tampon audio mono")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error {
            throw conversionError ?? RecorderError.setupFailed("conversion audio echouee")
        }
        guard outputBuffer.frameLength >= 1_600 else {
            throw RecorderError.setupFailed("moins de 100 ms de son ont ete enregistrees")
        }
        guard let samples = outputBuffer.int16ChannelData?[0] else {
            throw RecorderError.setupFailed("les echantillons PCM sont illisibles")
        }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let pcmData = Data(bytes: samples, count: byteCount)
        guard pcmData.count >= 3_200, pcmData.count.isMultiple(of: 2) else {
            throw RecorderError.setupFailed("le flux PCM final ne contient aucun son")
        }
        try pcmData.write(to: pcmURL, options: .atomic)
        return pcmURL
    }
}

/// End-of-utterance detector shared by live recording and deterministic
/// tests. It uses separate thresholds for starting and continuing speech:
/// once a person starts talking, quieter syllables and breaths should keep
/// the turn alive without allowing room noise to start a turn by itself.
final class VoiceActivityDetector {
    private let startedAt: TimeInterval
    private let silenceTimeout: TimeInterval
    private let minRecordingDuration: TimeInterval
    private let maxDuration: TimeInterval
    private let minimumSpeechDuration: TimeInterval
    private let speechStartTimeout: TimeInterval

    private var noiseFloor: Float = 0.001
    private var speechCandidateStartedAt: TimeInterval?
    private var hasDetectedSpeech = false
    private var lastSpeechAt: TimeInterval
    private var speechPeak: Float = 0
    private var fired = false

    var onSpeechStarted: (() -> Void)?
    var onSilenceDetected: (() -> Void)?
    var onNoSpeechDetected: (() -> Void)?

    init(
        startedAt: TimeInterval,
        silenceTimeout: TimeInterval = 3.2,
        minRecordingDuration: TimeInterval = 0.5,
        maxDuration: TimeInterval = 120,
        minimumSpeechDuration: TimeInterval = 0.18,
        speechStartTimeout: TimeInterval = 15
    ) {
        self.startedAt = startedAt
        self.silenceTimeout = silenceTimeout
        self.minRecordingDuration = minRecordingDuration
        self.maxDuration = maxDuration
        self.minimumSpeechDuration = minimumSpeechDuration
        self.speechStartTimeout = speechStartTimeout
        lastSpeechAt = startedAt
    }

    func ingest(buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var loudestChannelRMS: Float = 0
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            var sumSquares: Float = 0
            for frameIndex in 0..<frameCount {
                sumSquares += channel[frameIndex] * channel[frameIndex]
            }
            loudestChannelRMS = max(
                loudestChannelRMS,
                sqrtf(sumSquares / Float(frameCount))
            )
        }
        ingest(level: loudestChannelRMS)
    }

    func ingest(level: Float, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !fired else { return }

        let elapsed = now - startedAt
        if !hasDetectedSpeech, elapsed >= speechStartTimeout {
            finishWithoutSpeech()
            return
        }
        if elapsed >= maxDuration {
            hasDetectedSpeech ? finish() : finishWithoutSpeech()
            return
        }

        if hasDetectedSpeech {
            speechPeak = max(speechPeak * 0.995, level)
            // Once the level falls clearly below an established voice peak,
            // it is safe to relearn the room floor quickly. This prevents a
            // fan, external microphone hiss, or voice-processing residue
            // from being counted as speech forever after the user stops.
            if speechPeak >= 0.015, level < speechPeak * 0.65 {
                noiseFloor = max(1e-7, 0.82 * noiseFloor + 0.18 * level)
            }
            // The previous 0.0025 absolute floor was below the idle level
            // of common Mac microphones. Room tone then refreshed
            // `lastSpeechAt` forever, so a completed turn was never sent.
            // Tie the threshold to both calibrated ambience and the actual
            // voice peak, while capping the latter so softer final words
            // still count as speech.
            let voiceRelativeThreshold = min(speechPeak * 0.14, 0.012)
            let continuationThreshold = max(noiseFloor * 1.45, voiceRelativeThreshold, 0.0045)
            if level >= continuationThreshold {
                lastSpeechAt = now
            }
            if elapsed >= minRecordingDuration,
               now - lastSpeechAt >= silenceTimeout {
                finish()
            }
            return
        }

        // Voice processing and some external microphones produce a much
        // quieter normalized signal than the built-in Mac microphone. The
        // former 0.006 floor made normal speech invisible on those inputs.
        // Requiring a sustained candidate still rejects short clicks.
        let startThreshold = max(noiseFloor * 1.8, 0.002)
        if level >= startThreshold {
            if let candidateStart = speechCandidateStartedAt {
                if now - candidateStart >= minimumSpeechDuration {
                    hasDetectedSpeech = true
                    speechPeak = level
                    lastSpeechAt = now
                    onSpeechStarted?()
                }
            } else {
                speechCandidateStartedAt = now
            }
            return
        }

        speechCandidateStartedAt = nil
        // Adapt only while waiting for speech. Faster downward adaptation
        // follows a room becoming quieter; upward adaptation stays slow so
        // the beginning of a quiet sentence is not absorbed as room tone.
        let alpha: Float = level > noiseFloor ? 0.02 : 0.12
        noiseFloor = max(1e-7, (1 - alpha) * noiseFloor + alpha * level)
    }

    private func finish() {
        guard !fired else { return }
        fired = true
        onSilenceDetected?()
    }

    private func finishWithoutSpeech() {
        guard !fired else { return }
        fired = true
        onNoSpeechDetected?()
    }
}
