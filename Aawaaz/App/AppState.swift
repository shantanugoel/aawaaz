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

@Observable
final class AppState {
    var status: TranscriptionStatus = .idle
    var currentTranscription: String = ""
    var selectedModel: WhisperModel = .turbo
    var selectedLanguage: LanguageMode = .auto

    // Model management
    var modelManager = ModelManager()

    // Audio device state
    var availableAudioDevices: [AudioDevice] = []
    var selectedAudioDeviceUID: String? // nil = system default

    @ObservationIgnored
    private var deviceObserver: AudioDeviceObserver?

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
        refreshAudioDevices()
        deviceObserver = AudioDeviceObserver { [weak self] in
            self?.refreshAudioDevices()
        }

        // Ensure selected model is actually downloaded; fall back to first downloaded.
        if !modelManager.isDownloaded(selectedModel),
           let first = WhisperModel.allCases.first(where: { modelManager.isDownloaded($0) }) {
            selectedModel = first
        }
    }

    /// Path to the currently selected model, or nil if not yet downloaded.
    var selectedModelPath: String? {
        modelManager.modelPath(for: selectedModel)
    }

    func refreshAudioDevices() {
        availableAudioDevices = AudioDevice.allInputDevices()
        if let uid = selectedAudioDeviceUID,
           !availableAudioDevices.contains(where: { $0.uid == uid }) {
            selectedAudioDeviceUID = nil
        }
    }
}
