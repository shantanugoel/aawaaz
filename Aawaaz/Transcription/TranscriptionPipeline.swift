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

    /// App category captured at session start for Whisper prompt conditioning.
    /// Stable across all segments in one recording session.
    private var sessionAppCategory: InsertionContext.AppCategory?

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

        // Capture app category at session start for Whisper prompt conditioning.
        // This stays stable across all segments in one dictation session.
        sessionAppCategory = InsertionContext.current()?.appCategory

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
                hinglishScript: appState.selectedHinglishScript,
                appCategory: sessionAppCategory
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
    ///
    /// Uses a `defer` block to guarantee status returns to `.idle` and session state
    /// is cleaned up, even if an unexpected error or early return occurs.
    @MainActor
    private func finalize(session: UUID) async {
        guard sessionID == session, awaitingFinalization, let appState else { return }

        cancelFinalizationTimeout()

        // Safety net: always reset status and clean up, no matter how we exit.
        var didShowResult = false
        defer {
            if !didShowResult {
                appState.status = .idle
                appState.overlayController.dismiss()
            }
            cleanUpSession()
        }

        let rawText = accumulatedSegments.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawText.isEmpty else { return }

        // Store raw transcription for settings preview (Step 3.6)
        appState.lastRawTranscription = rawText

        // Show processing state while post-processing runs
        appState.status = .processing
        appState.showOverlayProcessing()

        // Snapshot the insertion context early — before any async model work —
        // so context doesn't drift if the user switches apps during LLM loading.
        // Opt in to surrounding text capture for LLM context injection.
        let insertionContext = InsertionContext.current(captureSurrounding: true) ?? .unknown

        // Run the post-processing chain
        let processedText = await postProcess(rawText, context: insertionContext)

        guard sessionID == session else { return }

        // Store processed transcription for settings preview (Step 3.6)
        appState.lastProcessedTranscription = processedText

        guard !processedText.isEmpty else { return }

        appState.currentTranscription = processedText

        // Insert the fully processed text into the focused app
        let context = await textInsertionManager.insertText(processedText)

        guard sessionID == session else { return }

        let methodLabel = context.insertionMethod.rawValue
        appState.showOverlayResult(processedText)
        didShowResult = true

        print("[Pipeline] Final text inserted via \(methodLabel): \(processedText)")

        appState.status = .idle
    }

    // MARK: - Private — Session Management

    /// Reset all session-specific state after finalization completes or is aborted.
    private func cleanUpSession() {
        accumulatedSegments = []
        pendingTranscriptionCount = 0
        awaitingFinalization = false
        sessionAppCategory = nil
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

    // MARK: - LLM Model Management

    private let textProcessor = TextProcessor()
    private let llmProcessor = LocalLLMProcessor()
    private let noOpProcessor = NoOpProcessor()
    private let transliterator = DevanagariTransliterator()
    private let punctuationRunner = PunctuationModelRunner()

    /// Switch the LLM processor to a different model.
    ///
    /// Called from settings when the user selects a different model.
    /// No-op if the requested model is already selected and loaded.
    func switchLLMModel(to model: LLMModel) async throws {
        try await llmProcessor.switchModel(to: model)
    }

    /// Unload the punctuation model to free memory.
    ///
    /// Called when the user disables the punctuation model in settings.
    func unloadPunctuationModel() async {
        await punctuationRunner.unload()
    }

    /// Pre-load the LLM model so it's ready for the first dictation.
    ///
    /// Called on app launch when local post-processing is enabled and
    /// the selected model is downloaded. Eliminates the cold-start delay
    /// on the first dictation. Uses ``LocalLLMProcessor/prepare(model:)``
    /// to sync the actor's selected model with AppState.
    func preloadLLMIfNeeded() async throws {
        guard let appState,
              appState.postProcessingMode == .local,
              appState.llmModelManager.isDownloaded(appState.selectedLLMModel) else { return }
        let model = appState.selectedLLMModel
        try await llmProcessor.prepare(model: model)
    }

    // MARK: - Private — Post-Processing

    /// Run the post-processing chain on accumulated text.
    ///
    /// Chain:
    /// 1. Self-correction detection + filler removal + spoken-form normalization
    /// 2. Punctuation model (punct + truecasing) — skipped for code/terminal
    /// 3. LLM cleanup when ``PostProcessingMode`` is `.local` and model is downloaded
    /// 4. Devanagari → Roman transliteration when LLM is off and Romanized script is selected
    ///
    /// If LLM processing fails or model is not downloaded, the pre-LLM result is used as fallback.
    private func postProcess(_ text: String, context: InsertionContext) async -> String {
        let config = appState?.textProcessingConfig ?? .default
        let mode = appState?.postProcessingMode ?? .off
        let cleanupLevel = appState?.cleanupLevel ?? .medium
        let language = appState?.selectedLanguage ?? .auto
        let hinglishScript = appState?.selectedHinglishScript ?? .romanized
        let llmAvailable = mode == .local
            && (appState?.llmModelManager.isDownloaded(appState?.selectedLLMModel ?? LLMModelCatalog.defaultModel) ?? false)
        let punctEnabled = appState?.punctuationModelEnabled ?? true
        let punctUseANE = appState?.punctuationModelUseANE ?? true

        // Determine script preference for Hinglish language only (Step 3.7)
        let scriptPreference: HinglishScript? = (language == .hinglish) ? hinglishScript : nil

        let isCodeTerminal = context.appCategory == .code || context.appCategory == .terminal

        print("[Pipeline] ── Post-processing start ──")
        print("[Pipeline]   Input: \"\(text)\"")
        print("[Pipeline]   Context: app=\(context.appCategory) mode=\(mode) punct=\(punctEnabled) ANE=\(punctUseANE) llm=\(llmAvailable) codeCtx=\(isCodeTerminal)")

        // Step 1: Deterministic text processing (self-correction → fillers → spoken forms)
        let deterministicResult = textProcessor.processWithDetails(text, config: config, context: context)
        let preLLMText = deterministicResult.output
        for stage in deterministicResult.stages {
            if !stage.enabled {
                print("[Pipeline]   Stage 1 (\(stage.name)): SKIPPED (disabled)")
            } else if stage.changed {
                print("[Pipeline]   Stage 1 (\(stage.name)): \"\(stage.input)\" → \"\(stage.output)\"")
            } else {
                print("[Pipeline]   Stage 1 (\(stage.name)): no changes")
            }
        }

        // Step 2: Punctuation model (punct + truecasing)
        // Skip for code/terminal contexts — the model over-capitalizes and adds unwanted periods.
        var afterPunct = preLLMText

        if punctEnabled && !isCodeTerminal && PunctuationModelRunner.isAvailable {
            let punctStart = CFAbsoluteTimeGetCurrent()
            do {
                try await punctuationRunner.loadModel(useANE: punctUseANE)
                afterPunct = try await punctuationRunner.predict(preLLMText)
                let punctLatency = (CFAbsoluteTimeGetCurrent() - punctStart) * 1000
                let epLabel = await punctuationRunner.usingCoreML ? "CoreML" : "CPU"
                if afterPunct != preLLMText {
                    print("[Pipeline]   Stage 2 (punct model): \"\(preLLMText)\" → \"\(afterPunct)\" [\(String(format: "%.1f", punctLatency))ms, \(epLabel)]")
                } else {
                    print("[Pipeline]   Stage 2 (punct model): no changes [\(String(format: "%.1f", punctLatency))ms, \(epLabel)]")
                }
            } catch {
                print("[Pipeline]   Stage 2 (punct model): FAILED — \(error.localizedDescription)")
            }
        } else {
            let reasons = [
                !punctEnabled ? "disabled" : nil,
                isCodeTerminal ? "code/terminal context" : nil,
                !PunctuationModelRunner.isAvailable ? "model not found" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            print("[Pipeline]   Stage 2 (punct model): SKIPPED (\(reasons))")
        }

        // Step 3: LLM post-processing (if enabled AND model is downloaded)
        let processor: PostProcessor = llmAvailable ? llmProcessor : noOpProcessor

        if mode == .local && !llmAvailable {
            print("[Pipeline]   Stage 3 (LLM): SKIPPED — model not downloaded")
            await MainActor.run { [weak self] in
                self?.appState?.pipelineError = "LLM model not downloaded. Download it in Settings → Post-Processing."
            }
        } else if mode == .off {
            print("[Pipeline]   Stage 3 (LLM): SKIPPED — mode is off")
        }

        var result: String
        var llmSucceeded = false
        do {
            result = try await processor.process(
                rawText: afterPunct,
                context: context,
                cleanupLevel: cleanupLevel,
                scriptPreference: scriptPreference
            )
            llmSucceeded = llmAvailable
            if llmAvailable {
                if result != afterPunct {
                    print("[Pipeline]   Stage 3 (LLM): \"\(afterPunct)\" → \"\(result)\"")
                } else {
                    print("[Pipeline]   Stage 3 (LLM): no changes")
                }
            }
        } catch {
            print("[Pipeline]   Stage 3 (LLM): FAILED — \(error.localizedDescription)")
            result = afterPunct
        }

        // Step 4: Devanagari → Roman transliteration when LLM did not handle it (Step 3.7)
        // When LLM succeeds, it handles script preference via the prompt.
        // When LLM is off or failed, run the deterministic transliterator as fallback.
        if !llmSucceeded, scriptPreference == .romanized, transliterator.containsDevanagari(result) {
            let before = result
            result = transliterator.transliterate(result)
            print("[Pipeline]   Stage 4 (transliteration): \"\(before)\" → \"\(result)\"")
        }

        print("[Pipeline]   Output: \"\(result)\"")
        print("[Pipeline] ── Post-processing end ──")

        return result
    }
}
