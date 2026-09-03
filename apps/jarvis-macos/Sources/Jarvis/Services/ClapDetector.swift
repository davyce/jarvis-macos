import AVFoundation
import AppKit
import Foundation
import os

/// Listens to the default microphone and detects a double clap (two loud, close
/// transients) to bring Jarvis to the foreground. Ported from the RMS/noise-floor
/// heuristic in https://github.com/hectorg2211/jarvis (jarvis.py).
///
/// Only amplitude (RMS) is analyzed in-memory, in 40ms blocks; no audio is ever
/// recorded or leaves the device.
final class ClapDetector: @unchecked Sendable {
    static let shared = ClapDetector()
    static let enabledDefaultsKey = "jarvis.clapToLaunch.enabled"
    private static let logger = Logger(subsystem: "com.adansonia.jarvis", category: "clap")

    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var isRunning = false

    // Tuning ported from the reference implementation.
    private let spikeRatio: Float = 7.0
    private let cooldown: TimeInterval = 0.45
    /// Multiple acceptable gaps between the two claps, since people don't all
    /// clap at the same rhythm: a quick double-tap, a normal pace, or a
    /// slower, deliberate one. The gap only has to land in ONE of these.
    private let doubleClapGapRanges: [ClosedRange<TimeInterval>] = [
        0.05...0.18, // rapid
        0.15...0.35, // normal
        0.30...0.55  // slow, deliberate
    ]
    private let retriggerRatio: Float = 0.55
    /// The tracked noise floor always moves toward the current level, but
    /// asymmetrically: it rises slowly (~2s to settle) so a single clap
    /// transient barely nudges it, yet it still climbs to match genuinely
    /// louder, sustained ambient noise (music, conversation, TV); it falls
    /// quickly (~0.3s) so the floor -- and so the re-arm gate below -- snaps
    /// back down as soon as the room quiets down again.
    private let noiseFloorRiseAlpha: Float = 0.98
    private let noiseFloorFallAlpha: Float = 0.85
    private let minRMS: Float = 0.012
    /// A real clap is a sharp, broadband, percussive transient: loud for
    /// one block, then gone. Voice (syllable by syllable) and phone sounds
    /// (ringtones, notification chimes, vibration buzz) stay loud for much
    /// longer, but land in the same 50-550ms cadence as a deliberate double
    /// clap -- amplitude and timing alone can't tell them apart. A spike
    /// that's still above `threshold` this long after it started is treated
    /// as sustained background noise, not a clap.
    private let maxClapDuration: TimeInterval = 0.15

    private var noiseFloor: Float = 1e-4
    private var lastDoubleClapAt: TimeInterval = 0
    private var firstClapAt: TimeInterval?
    private var spikeArmed = true
    /// Timestamp of a spike that crossed `threshold` and is still waiting to
    /// see whether it decays back below `retriggerLevel` quickly enough to
    /// count as clap-like, per `maxClapDuration`.
    private var pendingSpikeAt: TimeInterval?

    /// Injection points for testing; production code keeps the defaults.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var onDoubleClap: () -> Void = { ClapDetector.bringJarvisToFront() }

    init() {}

    var isListening: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    static func requestAccessIfNeeded() async -> Bool {
        await MicrophonePermission.requestAccessIfNeeded()
    }

    static func bootstrapIfEnabled() {
        guard UserDefaults.standard.bool(forKey: enabledDefaultsKey) else { return }
        guard MicrophonePermission.isAuthorized else { return }
        try? shared.start()
    }

    func start() throws {
        stateLock.lock()
        if isRunning {
            stateLock.unlock()
            return
        }
        noiseFloor = 1e-4
        lastDoubleClapAt = 0
        firstClapAt = nil
        spikeArmed = true
        pendingSpikeAt = nil
        isRunning = true
        stateLock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Self.logger.notice("Starting mic tap: sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            var sumSquares: Float = 0
            for i in 0..<frameCount {
                let sample = channel[i]
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(frameCount))
            self.process(level: rms)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            stateLock.lock()
            isRunning = false
            stateLock.unlock()
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        if !isRunning {
            stateLock.unlock()
            return
        }
        isRunning = false
        stateLock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func process(level: Float) {
        stateLock.lock()
        defer { stateLock.unlock() }

        // `threshold` is computed from the floor as of *before* this sample,
        // so folding `level` into `noiseFloor` right after can't circularly
        // affect the decision below.
        let threshold = max(noiseFloor * spikeRatio, minRMS)

        // The floor previously only updated when `level` was below a gate
        // derived from itself (`noiseFloor * 2.2`, later `threshold`). Since
        // `noiseFloor` bootstraps at 1e-4, that gate started far below real
        // mic self-noise in almost any room, so once ambient noise exceeded
        // it the floor could never move again: `threshold` stayed pinned at
        // its fixed `minRMS` floor, `retriggerLevel` (0.55x of that) sat
        // below the room's actual noise level, and the detector -- armed by
        // the first clap -- never saw the level dip back below
        // `retriggerLevel` between the two claps, so it stayed permanently
        // disarmed until the room went truly silent again.
        //
        // Tracking unconditionally, but asymmetrically (slow rise, fast
        // fall), removes that circularity: a brief clap barely moves a
        // floor that only rises slowly, but sustained louder ambient noise
        // pulls the floor -- and so the re-arm gate -- up to match within a
        // couple of seconds, the same way it snaps back down once the room
        // quiets again.
        if level > noiseFloor {
            noiseFloor = noiseFloorRiseAlpha * noiseFloor + (1 - noiseFloorRiseAlpha) * level
        } else {
            noiseFloor = noiseFloorFallAlpha * noiseFloor + (1 - noiseFloorFallAlpha) * level
        }
        noiseFloor = max(noiseFloor, 1e-7)

        let timestamp = now()
        let retriggerLevel = threshold * retriggerRatio

        if level < retriggerLevel {
            spikeArmed = true
            if let spikeAt = pendingSpikeAt {
                pendingSpikeAt = nil
                if timestamp - spikeAt <= maxClapDuration {
                    resolveClapEvent(at: spikeAt)
                } else {
                    // Stayed loud too long to be a clap (voice, a phone
                    // tone/buzz) -- not clap-like, and not a safe partner
                    // for whatever clap may have come before it either.
                    firstClapAt = nil
                }
            }
            return
        }

        guard spikeArmed, level >= threshold, (timestamp - lastDoubleClapAt) >= cooldown else { return }
        spikeArmed = false
        pendingSpikeAt = timestamp
        Self.logger.notice("Spike: level=\(level, privacy: .public) threshold=\(threshold, privacy: .public) noiseFloor=\(self.noiseFloor, privacy: .public)")
    }

    /// Called once a spike has decayed back below `retriggerLevel` quickly
    /// enough to be clap-like, with `timestamp` being when it started.
    private func resolveClapEvent(at timestamp: TimeInterval) {
        guard let firstClap = firstClapAt else {
            firstClapAt = timestamp
            return
        }

        let gap = timestamp - firstClap
        let overallMinGap = doubleClapGapRanges.map(\.lowerBound).min() ?? 0.05

        if gap < overallMinGap {
            // Too fast to be a real second clap (likely the same clap's own
            // echo/ringing) -- ignore it and keep waiting for the real one.
            return
        }

        if doubleClapGapRanges.contains(where: { $0.contains(gap) }) {
            firstClapAt = nil
            lastDoubleClapAt = timestamp
            Self.logger.notice("Double clap confirmed: gap=\(gap, privacy: .public)s")
            onDoubleClap()
        } else {
            // Outside every tier (too slow, or landed in a gap between
            // tiers) -- treat this spike as a fresh first clap.
            firstClapAt = timestamp
        }
    }

    private static func bringJarvisToFront() {
        DispatchQueue.main.async {
            WindowPresenter.presentMainWindow()
        }
    }
}
