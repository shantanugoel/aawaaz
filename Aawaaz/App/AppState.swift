import SwiftUI

enum TranscriptionStatus: String {
    case idle = "Idle"
    case listening = "Listening"
    case processing = "Processing"

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .listening: return .red
        case .processing: return .orange
        }
    }

    var iconName: String {
        switch self {
        case .idle: return "mic"
        case .listening: return "waveform"
        case .processing: return "ellipsis.circle"
        }
    }
}

enum LanguageMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case english = "English"
    case hindi = "Hindi"
    case hinglish = "Hinglish"

    var id: String { rawValue }
}

enum HinglishScript: String, CaseIterable, Identifiable {
    case romanized = "Romanized"
    case devanagari = "Devanagari"
    case mixed = "Mixed"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .romanized: return "\"mujhe meeting schedule karni hai\""
        case .devanagari: return "\"मुझे meeting schedule करनी है\""
        case .mixed: return "Let Whisper decide per word"
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case small = "small"
    case turbo = "turbo"
    case largeV3 = "large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small (~181 MB)"
        case .turbo: return "Turbo (~600 MB)"
        case .largeV3: return "Large v3 (~1.1 GB)"
        }
    }
}


@Observable
final class AppState {
    var status: TranscriptionStatus = .idle
    var currentTranscription: String = ""

    var selectedModel: WhisperModel {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedModel")
        }
    }
    var selectedLanguage: LanguageMode {
        didSet { UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "selectedLanguage") }
    }
    var selectedHinglishScript: HinglishScript {
        didSet { UserDefaults.standard.set(selectedHinglishScript.rawValue, forKey: "selectedHinglishScript") }
    }

    // Model management
    var modelManager = ModelManager()

    // Transcription pipeline
    @ObservationIgnored
    private(set) lazy var pipeline = TranscriptionPipeline(appState: self)
    var pipelineError: String?

    // Audio device state
    var availableAudioDevices: [AudioDevice] = []
    var selectedAudioDeviceUID: String? {
        didSet {
            if let uid = selectedAudioDeviceUID {
                UserDefaults.standard.set(uid, forKey: "selectedAudioDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedAudioDeviceUID")
            }
        }
    }

    @ObservationIgnored
    private var deviceObserver: AudioDeviceObserver?

    // Overlay
    @ObservationIgnored
    let overlayController = OverlayWindowController()

    // Text processing
    var textProcessingConfig: TextProcessingConfig = .load() {
        didSet { textProcessingConfig.save() }
    }

    // LLM post-processing
    var postProcessingMode: PostProcessingMode = .load() {
        didSet { postProcessingMode.save() }
    }
    var cleanupLevel: CleanupLevel = .load() {
        didSet { cleanupLevel.save() }
    }
    var selectedLLMModel: LLMModel {
        didSet { UserDefaults.standard.set(selectedLLMModel.rawValue, forKey: "selectedLLMModel") }
    }

    // LLM model management
    var llmModelManager = LLMModelManager()

    /// Last raw transcription (before any processing) — used for settings preview.
    var lastRawTranscription: String = ""

    /// Last processed transcription (after all processing) — used for settings preview.
    var lastProcessedTranscription: String = ""

    // Hotkey
    @ObservationIgnored
    let hotkeyManager = HotkeyManager()
    var hotkeyConfig: HotkeyConfiguration = .load()

    // Accessibility polling — retry event tap once permission is granted at runtime.
    @ObservationIgnored
    private var accessibilityTimer: Timer?

    // Onboarding
    var showOnboarding: Bool = PermissionsManager.shouldShowOnboarding

    var menuBarIconName: String {
        status.iconName
    }

    var selectedAudioDevice: AudioDevice? {
        if let uid = selectedAudioDeviceUID {
            return availableAudioDevices.first { $0.uid == uid }
        }
        return AudioDevice.defaultInputDevice()
    }

    init() {
        // Load persisted preferences
        if let raw = UserDefaults.standard.string(forKey: "selectedModel"),
           let model = WhisperModel(rawValue: raw) {
            self.selectedModel = model
        } else {
            self.selectedModel = .turbo
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedLanguage"),
           let lang = LanguageMode(rawValue: raw) {
            self.selectedLanguage = lang
        } else {
            self.selectedLanguage = .auto
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedHinglishScript"),
           let script = HinglishScript(rawValue: raw) {
            self.selectedHinglishScript = script
        } else {
            self.selectedHinglishScript = .romanized
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedLLMModel"),
           let model = LLMModel(rawValue: raw) {
            self.selectedLLMModel = model
        } else {
            self.selectedLLMModel = LLMModelCatalog.recommendedModel()
        }

        // Restore persisted audio device selection before refreshing so
        // refreshAudioDevices() can clear a stale UID for a disconnected device.
        self.selectedAudioDeviceUID = UserDefaults.standard.string(forKey: "selectedAudioDeviceUID")

        // Clean up defunct punctuation model preferences from prior versions
        UserDefaults.standard.removeObject(forKey: "punctuationModelEnabled")
        UserDefaults.standard.removeObject(forKey: "punctuationModelUseANE")

        refreshAudioDevices()
        deviceObserver = AudioDeviceObserver { [weak self] in
            self?.refreshAudioDevices()
        }

        // Ensure selected model is actually downloaded; fall back to first downloaded.
        reconcileSelectedModel()

        // Keep selectedModel in sync whenever models are downloaded or deleted.
        modelManager.onModelsChanged = { [weak self] in
            self?.reconcileSelectedModel()
        }

        // Ensure selected LLM model is downloaded; fall back to first downloaded.
        reconcileSelectedLLMModel()

        // Keep selectedLLMModel in sync whenever LLM models are downloaded or deleted.
        llmModelManager.onModelsChanged = { [weak self] in
            self?.reconcileSelectedLLMModel()
        }

        // Defer hotkey setup so it doesn't interfere with SwiftUI's initial
        // scene and window setup (event monitors registered too early can
        // block the run loop during launch).
        DispatchQueue.main.async { [weak self] in
            self?.setupHotkey()
        }

        // Pre-load the LLM model in the background so it's ready for the
        // first dictation. Uses low priority to avoid competing with UI setup.
        // Force-initialize `pipeline` here (main thread) to avoid a lazy-var
        // race with the detached task.
        if postProcessingMode == .local {
            let pipeline = self.pipeline
            Task.detached(priority: .background) {
                try? await pipeline.preloadLLMIfNeeded()
            }
        }
    }

    /// Path to the currently selected model, or nil if not yet downloaded.
    var selectedModelPath: String? {
        modelManager.modelPath(for: selectedModel)
    }

    /// Ensure `selectedModel` points to a downloaded model; fall back to the first available.
    func reconcileSelectedModel() {
        if !modelManager.isDownloaded(selectedModel),
           let first = WhisperModel.allCases.first(where: { modelManager.isDownloaded($0) }) {
            selectedModel = first
        }
    }

    /// Ensure `selectedLLMModel` points to a downloaded model; fall back to the first available.
    func reconcileSelectedLLMModel() {
        if !llmModelManager.isDownloaded(selectedLLMModel),
           let first = LLMModel.allCases.first(where: { llmModelManager.isDownloaded($0) }) {
            selectedLLMModel = first
        }
    }

    func refreshAudioDevices() {
        availableAudioDevices = AudioDevice.allInputDevices()
        if let uid = selectedAudioDeviceUID,
           !availableAudioDevices.contains(where: { $0.uid == uid }) {
            selectedAudioDeviceUID = nil
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager.onActivate = { [weak self] in
            DispatchQueue.main.async {
                self?.startListening()
            }
        }
        hotkeyManager.onDeactivate = { [weak self] in
            DispatchQueue.main.async {
                self?.stopListening()
            }
        }
        hotkeyManager.startMonitoring()

        // If the event tap couldn't be installed (Accessibility not yet granted),
        // poll periodically and upgrade once permission appears.
        if !hotkeyManager.isEventTapActive {
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if PermissionsManager.isAccessibilityGranted {
                    self.hotkeyManager.upgradeToEventTapIfPossible()
                    if self.hotkeyManager.isEventTapActive {
                        timer.invalidate()
                        self.accessibilityTimer = nil
                    }
                }
            }
        }
    }

    /// Update the hotkey configuration.
    func updateHotkeyConfig(_ config: HotkeyConfiguration) {
        hotkeyConfig = config
        hotkeyManager.updateConfiguration(config)
    }

    // MARK: - Listening Control

    /// Start the transcription pipeline and show the overlay.
    func startListening() {
        guard !pipeline.isBusy else { return }
        pipelineError = nil
        overlayController.showListening()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.pipeline.startListening()
            } catch {
                self.pipelineError = error.localizedDescription
                self.status = .idle
                self.overlayController.dismiss()
                self.hotkeyManager.resetState()
            }
        }
    }

    /// Stop the transcription pipeline and let it finalize (post-process + insert).
    ///
    /// The pipeline handles the full lifecycle after stop:
    /// listening → processing (post-processing) → result → auto-dismiss.
    /// If nothing was transcribed, the pipeline dismisses the overlay directly.
    func stopListening() {
        guard pipeline.isListening else { return }
        pipeline.stopListening()
        hotkeyManager.resetState()
    }

    /// Toggle the transcription pipeline on or off.
    func toggleListening() {
        if pipeline.isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    // MARK: - Overlay Updates (called by TranscriptionPipeline)

    /// Show the processing indicator in the overlay.
    func showOverlayProcessing() {
        overlayController.showProcessing()
    }

    /// Show interim transcription text in the overlay while still listening.
    func showOverlayInterimText(_ text: String) {
        overlayController.updateInterimText(text)
    }

    /// Show the transcription result in the overlay, then auto-dismiss.
    func showOverlayResult(_ text: String) {
        overlayController.showResult(text)
    }
}
