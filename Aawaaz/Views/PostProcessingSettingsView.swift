import SwiftUI

/// Settings tab for configuring LLM post-processing (Step 3.6).
///
/// Provides controls for:
/// - Post-processing mode (Off / Local LLM)
/// - Cleanup level (Light / Medium / Full)
/// - LLM model selection with download/delete controls
/// - Preview of last raw vs. processed transcription
struct PostProcessingSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            // MARK: - Mode & Level

            Section("Post-Processing") {
                Picker("Mode", selection: $state.postProcessingMode) {
                    ForEach(PostProcessingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if appState.postProcessingMode != .off {
                    Picker("Cleanup Level", selection: $state.cleanupLevel) {
                        ForEach(CleanupLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }

                    Text(appState.cleanupLevel.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Punctuation Model
            // Punctuation & capitalization is independent of LLM mode — always visible.

            Section("Punctuation & Capitalization") {
                Toggle("Punctuation Model", isOn: $state.punctuationModelEnabled)

                if appState.punctuationModelEnabled {
                    if PunctuationModelRunner.isAvailable {
                        Toggle("Use Neural Engine (ANE)", isOn: $state.punctuationModelUseANE)
                        Text("ANE accelerates inference. Disable to use CPU only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "Model files not found. Download and install the model first.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.callout)

                        Text("""
                        Run in Terminal:
                        python scripts/setup_punct_model.py
                        
                        (from the Aawaaz project root)
                        """)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            // MARK: - Model Selection & Download

            if appState.postProcessingMode == .local {
                Section("LLM Model") {
                    if !appState.llmModelManager.hasDownloadedModels {
                        Label(
                            "Download a model to use local post-processing.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.callout)
                    }

                    ForEach(LLMModelCatalog.models) { info in
                        LLMModelRow(info: info)
                    }

                    if let error = appState.llmModelManager.downloadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            // MARK: - Preview

            if !appState.lastRawTranscription.isEmpty {
                Section("Last Transcription Preview") {
                    TranscriptionPreviewView(
                        rawText: appState.lastRawTranscription,
                        processedText: appState.lastProcessedTranscription,
                        isProcessing: appState.status == .processing
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - LLM Model Row

/// A row displaying an LLM model's metadata with download/delete controls.
private struct LLMModelRow: View {
    let info: LLMModelInfo
    @Environment(AppState.self) private var appState

    private var isSelected: Bool {
        appState.selectedLLMModel == info.model && isDownloaded
    }

    private var isDownloaded: Bool {
        appState.llmModelManager.isDownloaded(info.model)
    }

    private var isDownloading: Bool {
        appState.llmModelManager.activeDownload == info.model
    }

    private var isRecommended: Bool {
        info.model == LLMModelCatalog.recommendedModel()
    }

    var body: some View {
        HStack(spacing: 10) {
            // Selection indicator — tap to select (only if downloaded)
            Button {
                if isDownloaded {
                    appState.selectedLLMModel = info.model
                    // Switch the loaded model immediately so the next
                    // dictation uses it without a hot-path model swap.
                    Task {
                        try? await appState.pipeline.switchLLMModel(to: info.model)
                    }
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!isDownloaded || appState.pipeline.isBusy)
            .help(isDownloaded ? "Use this model" : "Download the model first")

            // Model metadata
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(info.displayName)
                        .fontWeight(isSelected ? .semibold : .regular)
                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Label(info.sizeDescription, systemImage: "arrow.down.circle")
                    Label(info.ramUsage, systemImage: "memorychip")
                    Label(info.speed, systemImage: "speedometer")
                    Label(info.quality, systemImage: "star")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(info.recommendedFor)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Action area
            if isDownloading {
                downloadingControls
            } else if isDownloaded {
                downloadedControls
            } else {
                Button("Download") {
                    appState.llmModelManager.download(info.model)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var downloadingControls: some View {
        HStack(spacing: 8) {
            ProgressView(value: appState.llmModelManager.downloadProgress)
                .frame(width: 80)
            Text("\(Int(appState.llmModelManager.downloadProgress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            Button {
                appState.llmModelManager.cancelDownload()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Cancel download")
        }
    }

    private var downloadedControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button(role: .destructive) {
                appState.llmModelManager.deleteModel(info.model)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete model")
        }
    }
}

// MARK: - Transcription Preview

/// Shows a side-by-side comparison of raw and processed transcription text.
private struct TranscriptionPreviewView: View {
    let rawText: String
    let processedText: String
    let isProcessing: Bool

    @State private var showingRaw = false

    private var hasChanges: Bool {
        rawText != processedText && !processedText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("View", selection: $showingRaw) {
                Text("Processed").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let displayText: String = {
                if showingRaw { return rawText }
                if !processedText.isEmpty { return processedText }
                return rawText
            }()

            Text(displayText)
                .font(.body)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

            if !showingRaw {
                if processedText.isEmpty && !rawText.isEmpty {
                    if isProcessing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Post-processing in progress…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !hasChanges {
                    Text("Post-processing made no changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
