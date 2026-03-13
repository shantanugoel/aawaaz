import XCTest
@testable import Aawaaz

final class VADStateTests: XCTestCase {

    // MARK: - State Transitions

    func testInitialStateIsIdle() {
        let state = VADState()
        XCTAssertEqual(state.activity, .idle)
    }

    func testSpeechStartOnHighProbability() {
        let state = VADState()
        let chunk = [Float](repeating: 0.1, count: 512)

        state.process(probability: 0.8, audioChunk: chunk)
        XCTAssertEqual(state.activity, .speechStarted)
    }

    func testSpeechOngoingAfterContinuedHighProbability() {
        let state = VADState()
        let chunk = [Float](repeating: 0.1, count: 512)

        state.process(probability: 0.8, audioChunk: chunk) // → speechStarted
        state.process(probability: 0.7, audioChunk: chunk) // → speechOngoing
        XCTAssertEqual(state.activity, .speechOngoing)
    }

    func testBelowThresholdInIdleStaysIdle() {
        let state = VADState()
        let chunk = [Float](repeating: 0.0, count: 512)

        state.process(probability: 0.2, audioChunk: chunk)
        XCTAssertEqual(state.activity, .idle)
    }

    func testSpeechSegmentEmittedAfterSilencePadding() {
        let state = VADState()
        let chunk = [Float](repeating: 0.1, count: 512)

        var emittedSegments: [[Float]] = []
        state.onSpeechSegment = { samples in
            emittedSegments.append(samples)
        }

        // Start speech
        state.process(probability: 0.8, audioChunk: chunk)
        state.process(probability: 0.7, audioChunk: chunk)
        state.process(probability: 0.6, audioChunk: chunk)

        // Feed silence to exceed padding (300ms default = ~9.4 chunks of 512 @ 16kHz)
        for _ in 0..<15 {
            state.process(probability: 0.1, audioChunk: chunk)
        }

        XCTAssertEqual(emittedSegments.count, 1, "Should emit exactly one speech segment")
        XCTAssertEqual(state.activity, .idle, "Should return to idle after emission")
    }

    func testShortSpeechDiscarded() {
        // Use a smaller silence threshold so frames with probability 0.1
        // are definitively silence, and configure very tight padding so the
        // segment emits quickly, before speechDurationMs exceeds minimum.
        let state = VADState(
            speechThreshold: 0.5,
            silenceThreshold: 0.35,
            speechPaddingMs: 50,     // Very short padding
            minimumSpeechDurationMs: 500,  // Require at least 500ms
            maximumSpeechDurationMs: 15_000
        )
        let chunk = [Float](repeating: 0.1, count: 512)

        var emittedCount = 0
        state.onSpeechSegment = { _ in emittedCount += 1 }

        // 2 frames of speech (64ms) — well below 500ms minimum
        state.process(probability: 0.8, audioChunk: chunk)
        state.process(probability: 0.8, audioChunk: chunk)

        // Immediate silence to trigger padding expiry (50ms ≈ ~2 chunks)
        for _ in 0..<5 {
            state.process(probability: 0.1, audioChunk: chunk)
        }

        XCTAssertEqual(emittedCount, 0, "Speech shorter than minimum duration should be discarded")
    }

    func testFlushEmitsBufferedSpeech() {
        let state = VADState()
        let chunk = [Float](repeating: 0.5, count: 512)

        var emittedSegments: [[Float]] = []
        state.onSpeechSegment = { samples in
            emittedSegments.append(samples)
        }

        // Build up enough speech to exceed minimum duration
        for _ in 0..<15 {
            state.process(probability: 0.8, audioChunk: chunk)
        }

        // Flush without natural silence ending
        state.flush()

        XCTAssertEqual(emittedSegments.count, 1, "Flush should emit buffered speech")
    }

    func testFlushFromIdleDoesNothing() {
        let state = VADState()

        var emittedCount = 0
        state.onSpeechSegment = { _ in emittedCount += 1 }

        state.flush()
        XCTAssertEqual(emittedCount, 0, "Flush from idle should not emit")
    }

    func testResetClearsState() {
        let state = VADState()
        let chunk = [Float](repeating: 0.1, count: 512)

        state.process(probability: 0.8, audioChunk: chunk)
        XCTAssertNotEqual(state.activity, .idle)

        state.reset()
        XCTAssertEqual(state.activity, .idle)
    }

    func testMaximumDurationForcesEmission() {
        let state = VADState()
        let chunk = [Float](repeating: 0.1, count: 512)

        var emittedCount = 0
        state.onSpeechSegment = { _ in emittedCount += 1 }

        // 15s max = 15000ms / 32ms per chunk ≈ 469 chunks
        // Feed continuous speech exceeding max duration
        for _ in 0..<500 {
            state.process(probability: 0.8, audioChunk: chunk)
        }

        XCTAssertGreaterThanOrEqual(emittedCount, 1, "Should force-emit at max duration")
    }
}
