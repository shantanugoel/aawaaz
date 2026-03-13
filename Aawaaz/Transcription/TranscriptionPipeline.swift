import AppKit
import Foundation

// MARK: - Errors

enum PipelineError: Error, LocalizedError {
    case noModelAvailable
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .noModelAvailable:
            return "No transcription model available. Please download a model first."
        case .microphonePermissionDenied:
            return "Microphone permission is required for transcription."
        }
    }
}

// MARK: - TranscriptionPipeline

/// Orchestrates the full transcription pipeline: AudioCapture → VAD → Whisper → clipboard.
///
/// Create one instance per app lifetime. Call ``startListening()`` to begin capturing and
/// transcribing, and ``stopListening()`` to stop. Transcription results are published to
/// the provided ``AppState`` and automatically copied to the system clipboard.
final class TranscriptionPipeline {

    // MARK: - Components

    private let audioCapture = AudioCaptureManager()
    private let whisperManager = WhisperManager()
    private var vadProcessor: VADProcessor?
    private var vadState: VADState?

    /// Serial queue for VAD processing (VADProcessor and VADState are not thread-safe).
    private let vadQueue = DispatchQueue(label: "com.aawaaz.vad", qos: .userInteractive)

    // MARK: - State

    private weak var appState: AppState?
    /// Path of the currently loaded Whisper model, used to detect model changes.
    private var loadedModelPath: String?

    /// Whether the pipeline is currently capturing and processing audio.
    var isListening: Bool { audioCapture.isCapturing }

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Public API

    /// Start the transcription pipeline.
    ///
    /// Loads the Whisper model if not already loaded (or if the selected model changed).
    /// Initializes VAD, begins audio capture, and wires the full pipeline.
    ///
    /// - Throws: ``PipelineError`` if no model is downloaded or microphone permission is denied.
    func startListening() async throws {
        guard !isListening else { return }

        // Ensure microphone permission
        if !AudioCaptureManager.microphonePermissionGranted {
            let granted = await AudioCaptureManager.requestMicrophonePermission()
            guard granted else { throw PipelineError.microphonePermissionDenied }
        }

        // Resolve the model path for the currently selected model
        guard let modelPath = appState?.selectedModelPath else {
            throw PipelineError.noModelAvailable
        }

        // Load or reload the Whisper model if needed
        if await !whisperManager.isModelLoaded || loadedModelPath != modelPath {
            await MainActor.run { appState?.status = .processing }
            try await whisperManager.loadModel(path: modelPath)
            loadedModelPath = modelPath
        }

        // Initialize VAD components
        let vad = try VADProcessor()
        let state = VADState()

        // Wire: speech segment → Whisper transcription
        state.onSpeechSegment = { [weak self] samples in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                await self?.processSpeechSegment(samples)
            }
        }

        // Wire: VAD probability → state machine (runs on vadQueue, no dispatch needed)
        vad.onProbability = { probability, chunk in
            state.process(probability: probability, audioChunk: chunk)
        }

        self.vadProcessor = vad
        self.vadState = state

        // Wire: audio samples → VAD (dispatched to serial queue for thread safety)
        audioCapture.onSamplesReceived = { [weak self] samples in
            guard let self else { return }
            let vadQueue = self.vadQueue
            let vadProcessor = self.vadProcessor
            vadQueue.async {
                try? vadProcessor?.feed(samples: samples)
            }
        }

        // Start audio capture with the user's selected device
        let deviceUID = appState?.selectedAudioDeviceUID
        try audioCapture.startCapture(deviceUID: deviceUID)

        await MainActor.run { [weak self] in
            self?.appState?.status = .listening
        }
    }

    /// Stop the transcription pipeline.
    ///
    /// Flushes any buffered speech through the VAD (which may trigger a final
    /// transcription) and resets all VAD state for the next session.
    func stopListening() {
        guard isListening else { return }

        audioCapture.stopCapture()
        audioCapture.onSamplesReceived = nil

        // Capture current VAD objects so the flush operates on the correct
        // instances even if startListening() is called again immediately.
        let processor = vadProcessor
        let state = vadState

        // Flush remaining VAD buffer — may trigger a final onSpeechSegment callback.
        // Serial queue ensures this runs after any in-flight audio processing.
        vadQueue.async {
            state?.flush()
            processor?.resetState()
        }
    }

    // MARK: - Private

    /// Process a completed speech segment: run Whisper inference, update AppState,
    /// and copy the result to the clipboard.
    @MainActor
    private func processSpeechSegment(_ samples: [Float]) async {
        guard let appState else { return }

        appState.status = .processing
        appState.showOverlayProcessing()

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await whisperManager.transcribe(
                samples: samples,
                language: appState.selectedLanguage
            )

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                appState.status = isListening ? .listening : .idle
                appState.overlayController.dismiss()
                return
            }

            appState.currentTranscription = text
            copyToClipboard(text)
            appState.showOverlayResult(text)

            let audioDuration = Double(samples.count) / 16_000.0
            print("[Pipeline] Transcribed \(String(format: "%.1f", audioDuration))s audio "
                  + "in \(String(format: "%.2f", elapsed))s: \(text)")

        } catch {
            print("[Pipeline] Transcription error: \(error.localizedDescription)")
            appState.overlayController.dismiss()
        }

        appState.status = isListening ? .listening : .idle
    }

    /// Copy text to the system clipboard.
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
