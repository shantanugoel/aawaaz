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
        .frame(width: 450, height: 250)
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

        Form {
            Picker("Whisper Model", selection: $state.selectedModel) {
                ForEach(WhisperModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
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
