import SwiftUI

struct ModelDownloadView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ModelCatalog.models.enumerated()), id: \.element.id) { index, info in
                if index > 0 { Divider() }
                ModelRow(info: info)
            }

            if let error = appState.modelManager.downloadError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 6)
            }
        }
    }
}

// MARK: - Model Row

private struct ModelRow: View {
    let info: ModelInfo
    @Environment(AppState.self) private var appState

    private var isSelected: Bool {
        appState.selectedModel == info.model
    }

    private var isDownloaded: Bool {
        appState.modelManager.isDownloaded(info.model)
    }

    private var isDownloading: Bool {
        appState.modelManager.activeDownload == info.model
    }

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 10) {
            // Selection indicator — tap to select (only if downloaded)
            Button {
                if isDownloaded {
                    appState.selectedModel = info.model
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isDownloaded ? "Use this model" : "Download the model first")

            // Model metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(info.model.displayName)
                    .fontWeight(isSelected ? .semibold : .regular)

                HStack(spacing: 8) {
                    Label(info.sizeDescription, systemImage: "arrow.down.circle")
                    Label(info.ramUsage, systemImage: "memorychip")
                    Label(info.speed, systemImage: "speedometer")
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
                    appState.modelManager.download(info.model)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private var downloadingControls: some View {
        HStack(spacing: 8) {
            ProgressView(value: appState.modelManager.downloadProgress)
                .frame(width: 80)
            Text("\(Int(appState.modelManager.downloadProgress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            Button {
                appState.modelManager.cancelDownload()
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
                appState.modelManager.deleteModel(info.model)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete model")
        }
    }
}
