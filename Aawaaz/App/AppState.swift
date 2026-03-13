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
        case .listening: return "mic.fill"
        case .processing: return "waveform"
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

/// Latency preset that selects the trade-off between speed and transcription quality.
enum LatencyPreset: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case quality = "Quality"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .fast: return "Small model, lowest latency"
        case .balanced: return "Turbo model, best trade-off"
        case .quality: return "Large v3 model, highest accuracy"
        }
    }

    var recommendedModel: WhisperModel {
        switch self {
        case .fast: return .small
        case .balanced: return .turbo
        case .quality: return .largeV3
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
    var latencyPreset: LatencyPreset {
        didSet { UserDefaults.standard.set(latencyPreset.rawValue, forKey: "latencyPreset") }
    }

    // Model management
    var modelManager = ModelManager()

    // Transcription pipeline
    @ObservationIgnored
    private(set) lazy var pipeline = TranscriptionPipeline(appState: self)
    var pipelineError: String?

    // Audio device state
    var availableAudioDevices: [AudioDevice] = []
    var selectedAudioDeviceUID: String? // nil = system default

    @ObservationIgnored
    private var deviceObserver: AudioDeviceObserver?

    // Overlay
    @ObservationIgnored
    let overlayController = OverlayWindowController()

    // Hotkey
    @ObservationIgnored
    let hotkeyManager = HotkeyManager()
    var hotkeyConfig: HotkeyConfiguration = .load()

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
        if let raw = UserDefaults.standard.string(forKey: "latencyPreset"),
           let preset = LatencyPreset(rawValue: raw) {
            self.latencyPreset = preset
        } else {
            self.latencyPreset = .balanced
        }

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

        setupHotkey()
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
    }

    /// Update the hotkey configuration.
    func updateHotkeyConfig(_ config: HotkeyConfiguration) {
        hotkeyConfig = config
        hotkeyManager.updateConfiguration(config)
    }

    // MARK: - Listening Control

    /// Start the transcription pipeline and show the overlay.
    func startListening() {
        guard !pipeline.isListening else { return }
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

    /// Stop the transcription pipeline and let the overlay be managed by the pipeline.
    func stopListening() {
        guard pipeline.isListening else { return }
        pipeline.stopListening()
        hotkeyManager.resetState()
        // Don't dismiss the overlay here — the VAD flush may trigger a final
        // transcription that will show processing → result → auto-dismiss.
        // Schedule a fallback dismiss in case VAD flush produces nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.status = .idle
            if self.overlayController.isVisible {
                self.overlayController.dismiss()
            }
        }
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

    /// Show the transcription result in the overlay, then auto-dismiss.
    func showOverlayResult(_ text: String) {
        overlayController.showResult(text)
    }
}
