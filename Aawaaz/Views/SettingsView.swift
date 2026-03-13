import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelSettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "mic")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Picker("Language", selection: $state.selectedLanguage) {
                ForEach(LanguageMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        }
        .padding()
    }
}

struct ModelSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 16) {
            // Active model selector (only downloaded models selectable)
            if appState.modelManager.downloadedModels.isEmpty {
                Label("No models downloaded yet. Download one below.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Picker("Active Model", selection: $state.selectedModel) {
                    ForEach(WhisperModel.allCases.filter { appState.modelManager.isDownloaded($0) }) { model in
                        Text(model.displayName).tag(model)
                    }
                }
            }

            Divider()

            Text("Available Models")
                .font(.headline)

            ModelDownloadView()
        }
        .padding()
    }
}

struct AudioSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Picker("Input Device", selection: $state.selectedAudioDeviceUID) {
                Text("System Default").tag(nil as String?)
                ForEach(appState.availableAudioDevices) { device in
                    Text(device.name).tag(device.uid as String?)
                }
            }
        }
        .padding()
    }
}
