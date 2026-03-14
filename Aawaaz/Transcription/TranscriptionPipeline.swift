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

/// Orchestrates the full transcription pipeline: AudioCapture → VAD → Whisper → post-processing → text insertion.
///
/// Create one instance per app lifetime. Call ``startListening()`` to begin capturing and
/// transcribing, and ``stopListening()`` to stop.
///
/// **Process-then-insert architecture**: During recording, speech segments are transcribed by
/// Whisper and accumulated in memory (shown as interim text in the overlay). On stop, the
/// accumulated text is run through the post-processing chain and only then inserted into the
/// focused text field. The user never sees unprocessed text in their document.
///
/// **Session isolation**: Each recording session is identified by a unique ``sessionID``.
/// All async callbacks (speech segments, finalization) check the session ID before mutating
/// shared state, preventing stale work from a previous session from corrupting the current one.
final class TranscriptionPipeline {

    // MARK: - Components

    private let audioCapture = AudioCaptureManager()
    private let whisperManager = WhisperManager()
    private let textInsertionManager = TextInsertionManager()
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

    /// Whether the pipeline is busy (recording, transcribing, or finalizing).
    /// Prevents overlapping sessions from ``startListening()``.
    var isBusy: Bool { isListening || awaitingFinalization }

    // MARK: - Session State

    /// Unique token for the current recording session. All async callbacks check this
    /// before mutating shared state to prevent stale work from corrupting a new session.
    private var sessionID: UUID?

    /// Raw transcription segments accumulated during a recording session.
    /// Each entry is the trimmed Whisper output for one VAD speech segment.
    private var accumulatedSegments: [String] = []

    /// Number of speech segments currently being transcribed by Whisper.
    /// Used to defer finalization until all in-flight transcriptions complete.
    private var pendingTranscriptionCount = 0

    /// Set to `true` after `stopListening()` to signal that finalization should
    /// run once all pending transcriptions complete.
    private var awaitingFinalization = false

    /// Timeout for finalization — if all pending transcriptions don't complete
    /// within this duration after stop, the overlay is dismissed as a safety net.
    private static let finalizationTimeoutSeconds: TimeInterval = 10.0
    private var finalizationTimeoutWork: DispatchWorkItem?

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
        guard !isBusy else { return }

        // Create a new session — invalidates any stale callbacks from a previous session
        let currentSession = UUID()
        sessionID = currentSession
        accumulatedSegments = []
        pendingTranscriptionCount = 0
        awaitingFinalization = false
        cancelFinalizationTimeout()

        // Ensure microphone permission
        if !AudioCaptureManager.microphonePermissionGranted {
            let granted = await AudioCaptureManager.requestMicrophonePermission()
            guard granted else { throw PipelineError.microphonePermissionDenied }
        }

        // Abort if a new session replaced us during the await
        guard sessionID == currentSession else { return }

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

        // Abort if a new session replaced us during model load
        guard sessionID == currentSession else { return }

        // Initialize VAD components
        let vad = try VADProcessor()
        let state = VADState()

        // Wire: speech segment → Whisper transcription (accumulate, don't insert)
        state.onSpeechSegment = { [weak self] samples in
            guard self != nil else { return }
            let durationMs = Int(Double(samples.count) / 16.0)
            print("[Pipeline] Speech segment detected: \(durationMs)ms of audio")
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == currentSession else { return }
                self.pendingTranscriptionCount += 1
                await self.processSpeechSegment(samples, session: currentSession)
                self.pendingTranscriptionCount -= 1
                if self.awaitingFinalization && self.pendingTranscriptionCount == 0 {
                    await self.finalize(session: currentSession)
                }
            }
        }

        // Wire: VAD probability → state machine (runs on vadQueue, no dispatch needed)
        vad.onProbability = { probability, chunk in
            state.process(probability: probability, audioChunk: chunk)
        }

        self.vadProcessor = vad
        self.vadState = state

        // Wire: audio samples → VAD (dispatched to serial queue for thread safety)
        var sampleCount = 0
        audioCapture.onSamplesReceived = { [weak self] samples in
            guard let self else { return }
            sampleCount += samples.count
            if sampleCount % 160_000 == 0 { // Log roughly every 10s of audio
                print("[Pipeline] Audio flowing: \(sampleCount) samples received so far")
            }
            let vadQueue = self.vadQueue
            let vadProcessor = self.vadProcessor
            vadQueue.async {
                try? vadProcessor?.feed(samples: samples)
            }
        }

        // Wire: audio amplitude → overlay (throttled to main thread)
        audioCapture.onAmplitude = { [weak self] amplitude in
            guard let self else { return }
            DispatchQueue.main.async {
                self.appState?.overlayController.updateAmplitude(amplitude)
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
    /// Stops audio capture, flushes any buffered speech through the VAD (which may trigger
    /// a final transcription), then waits for all pending transcriptions to complete before
    /// running post-processing and inserting the final result.
    func stopListening() {
        guard isListening, let currentSession = sessionID else { return }

        audioCapture.stopCapture()
        audioCapture.onSamplesReceived = nil
        audioCapture.onAmplitude = nil

        // Capture current VAD objects so the flush operates on the correct
        // instances even if startListening() is called again immediately.
        let processor = vadProcessor
        let state = vadState

        // Flush remaining VAD buffer — may trigger a final onSpeechSegment callback.
        // Serial queue ensures this runs after any in-flight audio processing.
        // After flush completes, signal finalization on the main actor.
        vadQueue.async { [weak self] in
            state?.flush()
            processor?.resetState()

            Task { @MainActor [weak self] in
                guard let self, self.sessionID == currentSession else { return }
                self.awaitingFinalization = true
                self.scheduleFinalizationTimeout(session: currentSession)
                if self.pendingTranscriptionCount == 0 {
                    await self.finalize(session: currentSession)
                }
                // else: the last processSpeechSegment to complete will trigger finalize()
            }
        }
    }

    // MARK: - Private — Segment Processing

    /// Transcribe a single speech segment and accumulate the result.
    ///
    /// Does **not** insert text. Accumulates the raw Whisper output and updates
    /// the overlay with interim text so the user sees their speech being captured.
    @MainActor
    private func processSpeechSegment(_ samples: [Float], session: UUID) async {
        guard let appState, sessionID == session else { return }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let result = try await whisperManager.transcribe(
                samples: samples,
                language: appState.selectedLanguage,
                hinglishScript: appState.selectedHinglishScript
            )

            // Check session validity after the await
            guard sessionID == session else { return }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { return }

            accumulatedSegments.append(text)
            let interimText = accumulatedSegments.joined(separator: " ")

            let audioDuration = Double(samples.count) / 16_000.0
            print("[Pipeline] Transcribed \(String(format: "%.1f", audioDuration))s audio "
                  + "in \(String(format: "%.2f", elapsed))s: \(text)")

            // Show interim transcription in overlay (waveform keeps animating)
            appState.showOverlayInterimText(interimText)

        } catch {
            print("[Pipeline] Transcription error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private — Finalization

    /// Join accumulated text, run the post-processing chain, insert into the focused
    /// text field, and show the final result in the overlay.
    ///
    /// Called once after `stopListening()` when all pending transcriptions have completed.
    @MainActor
    private func finalize(session: UUID) async {
        guard sessionID == session, awaitingFinalization, let appState else { return }

        cancelFinalizationTimeout()

        let rawText = accumulatedSegments.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawText.isEmpty else {
            appState.status = .idle
            appState.overlayController.dismiss()
            cleanUpSession()
            return
        }

        // Show processing state while post-processing runs
        appState.status = .processing
        appState.showOverlayProcessing()

        // Run the post-processing chain (currently a pass-through; steps 3.1+
        // will add filler word removal, self-correction detection, LLM cleanup, etc.)
        let processedText = await postProcess(rawText)

        guard sessionID == session else { return }

        guard !processedText.isEmpty else {
            appState.status = .idle
            appState.overlayController.dismiss()
            cleanUpSession()
            return
        }

        appState.currentTranscription = processedText

        // Insert the fully processed text into the focused app
        let context = await textInsertionManager.insertText(processedText)

        guard sessionID == session else { return }

        let methodLabel = context.insertionMethod.rawValue
        appState.showOverlayResult(processedText)

        print("[Pipeline] Final text inserted via \(methodLabel): \(processedText)")

        appState.status = .idle
        cleanUpSession()
    }

    // MARK: - Private — Session Management

    /// Reset all session-specific state after finalization completes or is aborted.
    private func cleanUpSession() {
        accumulatedSegments = []
        pendingTranscriptionCount = 0
        awaitingFinalization = false
        cancelFinalizationTimeout()
    }

    /// Schedule a watchdog that dismisses the overlay if finalization doesn't
    /// complete within the timeout. Guards against hung transcriptions.
    private func scheduleFinalizationTimeout(session: UUID) {
        cancelFinalizationTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == session, self.awaitingFinalization else { return }
            print("[Pipeline] Finalization timeout — dismissing overlay (session: \(session))")
            self.appState?.status = .idle
            self.appState?.overlayController.dismiss()
            self.cleanUpSession()
        }
        finalizationTimeoutWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.finalizationTimeoutSeconds,
            execute: work
        )
    }

    private func cancelFinalizationTimeout() {
        finalizationTimeoutWork?.cancel()
        finalizationTimeoutWork = nil
    }

    // MARK: - Private — Post-Processing

    private let textProcessor = TextProcessor()

    /// Run the post-processing chain on accumulated text.
    ///
    /// Current chain:
    /// 1. Self-correction detection (Step 3.1)
    /// 2. Filler word removal (Step 3.1)
    ///
    /// Future steps will add:
    /// 3. Dictionary correction (Phase 3.5)
    /// 4. Snippet expansion (Phase 3.5)
    /// 5. LLM cleanup (Steps 3.3–3.5)
    private func postProcess(_ text: String) async -> String {
        let config = appState?.textProcessingConfig ?? .default
        return textProcessor.process(text, config: config)
    }
}
