import Foundation

/// Current phase of the voice activity state machine.
enum VADActivity {
    case idle
    case speechStarted
    case speechOngoing
    case speechEnded
}

/// State machine that tracks speech boundaries using VAD probability output.
///
/// Buffers audio samples while speech is detected and emits complete speech
/// segments once silence padding has elapsed. Enforces minimum speech duration
/// to discard spurious clicks and pops.
final class VADState {
    // MARK: - Configuration

    /// Probability above which a frame is considered speech.
    let speechThreshold: Float
    /// Probability below which a frame is considered silence (hysteresis).
    let silenceThreshold: Float
    /// How long silence must persist after speech before we emit the segment (ms).
    let speechPaddingMs: Int
    /// Segments shorter than this are discarded (ms).
    let minimumSpeechDurationMs: Int
    /// Maximum segment duration before forced emission (ms). Prevents unbounded buffering.
    let maximumSpeechDurationMs: Int
    /// Audio sample rate used for duration calculations.
    let sampleRate: Int

    // MARK: - State

    private(set) var activity: VADActivity = .idle
    private var speechBuffer: [Float] = []
    private var consecutiveSilenceMs: Int = 0
    private var speechDurationMs: Int = 0

    /// Called when a complete speech segment is available.
    var onSpeechSegment: (([Float]) -> Void)?

    // MARK: - Init

    init(
        speechThreshold: Float = 0.5,
        silenceThreshold: Float = 0.35,
        speechPaddingMs: Int = 300,
        minimumSpeechDurationMs: Int = 250,
        maximumSpeechDurationMs: Int = 15_000,
        sampleRate: Int = 16_000
    ) {
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
        self.speechPaddingMs = speechPaddingMs
        self.minimumSpeechDurationMs = minimumSpeechDurationMs
        self.maximumSpeechDurationMs = maximumSpeechDurationMs
        self.sampleRate = sampleRate
    }

    // MARK: - Processing

    /// Feed a VAD probability together with the audio chunk it was computed from.
    ///
    /// When the state machine detects that a speech segment has ended (silence
    /// exceeds padding), or the maximum duration is reached, it calls
    /// `onSpeechSegment` with the buffered audio.
    func process(probability: Float, audioChunk: [Float]) {
        let chunkDurationMs = Int(Double(audioChunk.count) / Double(sampleRate) * 1000.0)

        switch activity {
        case .idle:
            if probability >= speechThreshold {
                activity = .speechStarted
                speechBuffer.append(contentsOf: audioChunk)
                speechDurationMs = chunkDurationMs
                consecutiveSilenceMs = 0
            }
            // If below threshold while idle, discard — nothing to do.

        case .speechStarted, .speechOngoing:
            activity = .speechOngoing
            speechBuffer.append(contentsOf: audioChunk)
            speechDurationMs += chunkDurationMs

            if probability >= speechThreshold {
                // Speech continues — reset silence counter.
                consecutiveSilenceMs = 0
            } else if probability < silenceThreshold {
                consecutiveSilenceMs += chunkDurationMs
            }

            // Emit if silence padding exceeded or max duration reached.
            let silenceExceeded = consecutiveSilenceMs >= speechPaddingMs
            let maxDurationReached = speechDurationMs >= maximumSpeechDurationMs

            if silenceExceeded || maxDurationReached {
                emitAndReset()
            }

        case .speechEnded:
            // Transient state — reset was expected.
            reset()
        }
    }

    /// Force-emit whatever is currently buffered (e.g. when the user releases
    /// the hotkey mid-speech).
    func flush() {
        if !speechBuffer.isEmpty && speechDurationMs >= minimumSpeechDurationMs {
            let segment = speechBuffer
            onSpeechSegment?(segment)
        }
        reset()
    }

    /// Discard all buffered audio and return to idle.
    func reset() {
        activity = .idle
        speechBuffer = []
        consecutiveSilenceMs = 0
        speechDurationMs = 0
    }

    // MARK: - Private

    private func emitAndReset() {
        activity = .speechEnded
        if speechDurationMs >= minimumSpeechDurationMs {
            let segment = speechBuffer
            onSpeechSegment?(segment)
        }
        reset()
    }
}
