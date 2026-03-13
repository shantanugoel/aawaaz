import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelSettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
        }
        .frame(width: 500, height: 420)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Activation") {
                ShortcutRecorderView(
                    configuration: Binding(
                        get: { appState.hotkeyConfig },
                        set: { appState.hotkeyConfig = $0 }
                    ),
                    onUpdate: { newConfig in
                        appState.updateHotkeyConfig(newConfig)
                    }
                )

                Picker("Mode", selection: Binding(
                    get: { appState.hotkeyConfig.mode },
                    set: { newMode in
                        var config = appState.hotkeyConfig
                        config.mode = newMode
                        appState.updateHotkeyConfig(config)
                    }
                )) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Text(appState.hotkeyConfig.mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Language", selection: $state.selectedLanguage) {
                    ForEach(LanguageMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            Section("Audio") {
                Picker("Input Device", selection: $state.selectedAudioDeviceUID) {
                    Text("System Default").tag(nil as String?)
                    ForEach(appState.availableAudioDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            if appState.modelManager.downloadedModels.isEmpty {
                Section {
                    Label("No models downloaded yet. Download one below.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Section("Active Model") {
                    Picker("Model", selection: $state.selectedModel) {
                        ForEach(WhisperModel.allCases.filter { appState.modelManager.isDownloaded($0) }) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                }
            }

            Section("Available Models") {
                ModelDownloadView()
            }
        }
        .formStyle(.grouped)
    }
}
