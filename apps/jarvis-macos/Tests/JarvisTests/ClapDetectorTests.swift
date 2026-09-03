import XCTest
@testable import Jarvis

final class ClapDetectorTests: XCTestCase {
    func testDoubleClapWithinWindowTriggersCallback() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        detector.process(level: 0.5) // first clap
        t += 0.03
        detector.process(level: 0.001) // silence, re-arms the detector
        t += 0.10
        detector.process(level: 0.5) // second clap, 0.13s later
        t += 0.03
        detector.process(level: 0.001) // decays right back down -- confirms it was clap-like

        XCTAssertTrue(triggered)
    }

    func testSlowDeliberateDoubleClapStillTriggers() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        detector.process(level: 0.5) // first clap
        t += 0.03
        detector.process(level: 0.001) // silence, re-arms the detector
        t += 0.42
        detector.process(level: 0.5) // second clap, 0.45s later: a slower rhythm
        t += 0.03
        detector.process(level: 0.001) // decays right back down -- confirms it was clap-like

        XCTAssertTrue(triggered)
    }

    func testClapsTooFarApartDoNotTrigger() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        detector.process(level: 0.5)
        t += 0.03
        detector.process(level: 0.001)
        t += 1.0
        detector.process(level: 0.5)

        XCTAssertFalse(triggered)
    }

    func testSingleClapDoesNotTrigger() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        detector.now = { 100 }

        detector.process(level: 0.5)

        XCTAssertFalse(triggered)
    }

    func testQuietRoomNoiseNeverTriggers() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        for _ in 0..<200 {
            detector.process(level: 0.0008)
            t += 0.04
        }

        XCTAssertFalse(triggered)
    }

    /// Regression test: a room that is not silent -- background conversation,
    /// music, a TV -- must not make the detector permanently deaf. Before the
    /// noise-floor fix, any sustained ambient level above ~0.012 RMS latched
    /// the detector disarmed forever (see `ClapDetector.process`'s doc
    /// comment), because the re-arm threshold never adapted to the room's
    /// real noise level.
    func testDoubleClapStillTriggersOverSustainedBackgroundNoise() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        // A few seconds of fluctuating background noise loud enough to be a
        // real "there's sound around" room -- well above the detector's old
        // fixed minRMS floor -- so the noise floor has time to adapt.
        var generator = SplitMix64(seed: 7)
        for _ in 0..<125 {
            detector.process(level: Float.random(in: 0.02...0.05, using: &generator))
            t += 0.04
        }

        // A real double clap doesn't happen in silence -- the background
        // noise keeps going in the gap between the two claps too.
        detector.process(level: 0.5)
        t += 0.03
        detector.process(level: 0.03)
        t += 0.10
        detector.process(level: 0.5)
        t += 0.03
        detector.process(level: 0.03) // decays right back down -- confirms it was clap-like

        XCTAssertTrue(triggered, "a clear double clap must still register once the room isn't silent")
    }

    /// Regression test for the flip side of the noise-floor fix above: once
    /// the detector could hear again over background noise, plain talking
    /// near the mic -- syllable after syllable, each loud enough and each
    /// gap short enough to coincidentally land in an acceptable clap window
    /// -- started firing false double claps. A real clap decays back to
    /// ambient almost immediately; a spoken syllable stays loud for well
    /// over `maxClapDuration`, so it must never complete a clap pairing.
    func testContinuousSpeechDoesNotTrigger() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        var generator = SplitMix64(seed: 3)
        for _ in 0..<6 {
            let burstBlocks = Int.random(in: 4...6, using: &generator) // ~160-240ms sustained syllable
            for _ in 0..<burstBlocks {
                detector.process(level: Float.random(in: 0.05...0.15, using: &generator))
                t += 0.04
            }
            let pauseBlocks = Int.random(in: 2...5, using: &generator) // ~80-200ms pause between syllables
            for _ in 0..<pauseBlocks {
                detector.process(level: Float.random(in: 0.01...0.02, using: &generator))
                t += 0.04
            }
        }

        XCTAssertFalse(triggered, "sustained speech syllables must not be mistaken for a clap")
    }

    /// Same idea as the speech test, for a phone: notification chimes,
    /// ringtone tones, and vibration buzz are all sustained sounds, often in
    /// pairs (two-tone chimes), not sharp impulsive transients.
    func testPhoneNotificationToneDoesNotTrigger() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        for _ in 0..<2 {
            for _ in 0..<6 { // ~240ms tone
                detector.process(level: 0.3)
                t += 0.04
            }
            for _ in 0..<4 { // ~160ms gap between the two tones
                detector.process(level: 0.01)
                t += 0.04
            }
        }

        XCTAssertFalse(triggered, "a sustained notification tone must not be mistaken for a clap")
    }

    /// A single loud, isolated noise (a door slam, something dropped) is not
    /// a double clap and must not be treated as one just because it crosses
    /// the spike threshold once.
    func testIsolatedLoudNoiseDoesNotTrigger() {
        let detector = ClapDetector()
        var triggered = false
        detector.onDoubleClap = { triggered = true }
        var t: TimeInterval = 100
        detector.now = { t }

        for _ in 0..<20 {
            detector.process(level: 0.01)
            t += 0.04
        }
        detector.process(level: 0.6)
        t += 0.04
        for _ in 0..<20 {
            detector.process(level: 0.01)
            t += 0.04
        }

        XCTAssertFalse(triggered)
    }
}

final class VoiceActivityDetectorTests: XCTestCase {
    func testLongPhraseSurvivesNaturalThinkingPauses() {
        let detector = VoiceActivityDetector(startedAt: 0)
        var ended = false
        detector.onSilenceDetected = { ended = true }

        feed(detector, level: 0.012, from: 0, through: 1.0)
        feed(detector, level: 0.0008, from: 1.1, through: 3.5)
        XCTAssertFalse(ended, "a pause inside a long sentence must not end the turn")

        feed(detector, level: 0.010, from: 3.6, through: 5.0)
        feed(detector, level: 0.0008, from: 5.1, through: 7.9)
        XCTAssertFalse(ended, "a second thinking pause must still keep the same turn alive")

        detector.ingest(level: 0.0008, at: 8.3)
        XCTAssertTrue(ended, "the turn should end only after the full silence window")
    }

    func testQuietSpeechStartsAndKeepsTheTurnAlive() {
        let detector = VoiceActivityDetector(startedAt: 0)
        var started = false
        var ended = false
        detector.onSpeechStarted = { started = true }
        detector.onSilenceDetected = { ended = true }

        feed(detector, level: 0.007, from: 0, through: 0.5)
        XCTAssertTrue(started)

        feed(detector, level: 0.0065, from: 0.6, through: 4.0)
        XCTAssertFalse(ended, "quiet trailing syllables should not be mistaken for silence")
    }

    func testTypicalMacRoomToneEndsTheTurn() {
        let detector = VoiceActivityDetector(startedAt: 0)
        var ended = false
        detector.onSilenceDetected = { ended = true }

        feed(detector, level: 0.02, from: 0, through: 1.0)
        feed(detector, level: 0.0035, from: 1.1, through: 4.1)
        XCTAssertFalse(ended)

        detector.ingest(level: 0.0035, at: 4.3)
        XCTAssertTrue(ended, "steady microphone room tone must not keep listening forever")
    }

    func testBriefNoiseSpikeDoesNotInterruptJarvis() {
        let detector = VoiceActivityDetector(startedAt: 0)
        var started = false
        detector.onSpeechStarted = { started = true }

        detector.ingest(level: 0.02, at: 0.10)
        detector.ingest(level: 0.0008, at: 0.14)

        XCTAssertFalse(started, "a click or playback leak must not count as user speech")
    }

    func testContinuousSpeechCanExceedOldFortyFiveSecondLimit() {
        let detector = VoiceActivityDetector(startedAt: 0)
        var ended = false
        detector.onSilenceDetected = { ended = true }

        feed(detector, level: 0.012, from: 0, through: 70, step: 0.1)

        XCTAssertFalse(ended, "long dictation must not be cut at the former 45-second cap")
    }

    func testQuietProcessedMicrophoneSpeechStarts() {
        let detector = VoiceActivityDetector(startedAt: 0)
        var started = false
        detector.onSpeechStarted = { started = true }

        feed(detector, level: 0.0025, from: 0, through: 0.5, step: 0.05)

        XCTAssertTrue(started, "quiet but sustained microphone input must start a turn")
    }

    func testNoSpeechTimesOutInsteadOfListeningForever() {
        let detector = VoiceActivityDetector(startedAt: 0, speechStartTimeout: 2)
        var noSpeech = false
        detector.onNoSpeechDetected = { noSpeech = true }

        feed(detector, level: 0.0002, from: 0, through: 2.1)

        XCTAssertTrue(noSpeech)
    }

    private func feed(
        _ detector: VoiceActivityDetector,
        level: Float,
        from start: TimeInterval,
        through end: TimeInterval,
        step: TimeInterval = 0.1
    ) {
        var time = start
        while time <= end {
            detector.ingest(level: level, at: time)
            time += step
        }
    }
}

/// Deterministic, seedable PRNG so the noisy-background regression test is
/// reproducible across runs instead of depending on the system RNG.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
