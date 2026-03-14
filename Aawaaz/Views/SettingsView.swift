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
        .frame(width: 500, height: 480)
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

                if appState.hotkeyConfig.keyCode == 63 {
                    Label("Set System Settings → Keyboard → \"Press 🌐 to\" → \"Do Nothing\" to avoid conflicts.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                if appState.selectedLanguage == .hinglish {
                    Picker("Hinglish Script", selection: $state.selectedHinglishScript) {
                        ForEach(HinglishScript.allCases) { script in
                            Text(script.rawValue).tag(script)
                        }
                    }

                    Text(appState.selectedHinglishScript.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Biases output toward your preferred script. Results may still vary by utterance.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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

            TextCleanupSettingsSection()
        }
        .formStyle(.grouped)
    }
}

struct TextCleanupSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var showFillerWords = false
    @State private var newFillerWord = ""

    var body: some View {
        @Bindable var state = appState

        Section("Text Cleanup") {
            Toggle("Remove filler words", isOn: $state.textProcessingConfig.fillerRemovalEnabled)
            Toggle("Detect self-corrections", isOn: $state.textProcessingConfig.selfCorrectionEnabled)

            if appState.textProcessingConfig.fillerRemovalEnabled {
                DisclosureGroup("Filler word list", isExpanded: $showFillerWords) {
                    ForEach(appState.textProcessingConfig.fillerWords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                appState.textProcessingConfig.fillerWords.removeAll { $0 == word }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("Add word or phrase…", text: $newFillerWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addFillerWord() }
                        Button("Add") { addFillerWord() }
                            .disabled(newFillerWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button("Reset to Defaults") {
                        appState.textProcessingConfig.fillerWords = TextProcessingConfig.defaultFillerWords
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func addFillerWord() {
        let word = newFillerWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty,
              !appState.textProcessingConfig.fillerWords.contains(word) else {
            newFillerWord = ""
            return
        }
        appState.textProcessingConfig.fillerWords.append(word)
        newFillerWord = ""
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
