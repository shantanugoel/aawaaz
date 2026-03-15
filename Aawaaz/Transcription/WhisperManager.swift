import Foundation
import whisper

// MARK: - Result Types

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
}

struct TranscriptionSegment {
    let text: String
    /// Start time in centiseconds (whisper.cpp native unit; multiply by 10 for ms)
    let startTime: Int64
    /// End time in centiseconds
    let endTime: Int64
}

// MARK: - Errors

enum WhisperError: Error, LocalizedError {
    case modelLoadFailed
    case modelNotLoaded
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load Whisper model"
        case .modelNotLoaded: return "No Whisper model is loaded"
        case .transcriptionFailed: return "Whisper inference failed"
        }
    }
}

// MARK: - WhisperManager

/// Thread-safe wrapper around the whisper.cpp C library.
///
/// Uses Swift `actor` isolation because the underlying C context
/// is **not** thread-safe — all calls are serialized automatically.
actor WhisperManager {

    private var context: OpaquePointer?

    var isModelLoaded: Bool { context != nil }

    // MARK: - Model Lifecycle

    /// Load a GGML model file from disk.
    func loadModel(path: String) throws {
        unloadModel()

        let params = whisper_context_default_params()
        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw WhisperError.modelLoadFailed
        }
        context = ctx
    }

    /// Free the current model and release its memory.
    func unloadModel() {
        if let ctx = context {
            whisper_free(ctx)
            context = nil
        }
    }

    // MARK: - Transcription

    /// Run Whisper inference on 16 kHz mono Float32 audio samples.
    ///
    /// - Parameters:
    ///   - samples: PCM audio at 16 kHz, mono, Float32.
    ///   - language: Language mode controlling auto-detect vs forced language.
    ///   - hinglishScript: Script preference for Hinglish output (only used when language is `.hinglish`).
    /// - Returns: Transcription result with full text and per-segment detail.
    func transcribe(samples: [Float], language: LanguageMode = .auto, hinglishScript: HinglishScript = .romanized) throws -> TranscriptionResult {
        guard let ctx = context else {
            throw WhisperError.modelNotLoaded
        }

        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", segments: [])
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.single_segment = false

        // Never translate — always transcribe. Without this, Whisper may
        // translate Hindi words to English instead of preserving them.
        params.translate = false

        // Language: nil (NULL) triggers auto-detect in whisper.cpp.
        // Hinglish uses "hi" so Whisper expects Hindi and naturally picks up
        // embedded English words without translating.
        let languageCStr: UnsafeMutablePointer<CChar>?
        switch language {
        case .auto:
            languageCStr = nil
        case .english:
            languageCStr = strdup("en")
        case .hindi, .hinglish:
            languageCStr = strdup("hi")
        }
        defer { languageCStr.map { free($0) } }
        params.language = UnsafePointer(languageCStr)
        params.detect_language = (language == .auto)

        // Condition Whisper's decoder via initial_prompt to improve punctuation,
        // capitalization, and proper noun spelling. Zero latency cost.
        let initialPromptCStr: UnsafeMutablePointer<CChar>?
        let prompt: String
        switch language {
        case .hinglish:
            switch hinglishScript {
            case .romanized:
                prompt = "Yeh ek Hinglish example hai. Meeting schedule karna hai, please email bhej do."
            case .devanagari:
                prompt = "यह एक Hinglish example है। Meeting schedule करना है, please email भेज दो।"
            case .mixed:
                prompt = ""
            }
        case .english, .auto:
            prompt = "Hello, this is a properly formatted dictation with correct punctuation and capitalization."
        case .hindi:
            prompt = ""
        }
        initialPromptCStr = prompt.isEmpty ? nil : strdup(prompt)
        defer { initialPromptCStr.map { free($0) } }
        params.initial_prompt = UnsafePointer(initialPromptCStr)

        let status = samples.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }

        guard status == 0 else {
            throw WhisperError.transcriptionFailed
        }

        let nSegments = whisper_full_n_segments(ctx)
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                let text = String(cString: cStr)
                let t0 = whisper_full_get_segment_t0(ctx, i)
                let t1 = whisper_full_get_segment_t1(ctx, i)
                segments.append(TranscriptionSegment(text: text, startTime: t0, endTime: t1))
                fullText += text
            }
        }

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments
        )
    }

    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }
}
