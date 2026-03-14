import Foundation
import MLXLMCommon
import MLXLLM

/// Manages LLM model downloads, caching, and deletion.
///
/// Uses MLX's ``loadModelContainer`` for downloads (which caches to
/// `~/Library/Caches/models/models/<huggingFaceID>/`). Tracks download
/// progress and which models are available locally.
///
/// Mirrors the pattern of ``ModelManager`` (Whisper models) but delegates
/// the actual download to MLX's HuggingFace Hub integration instead of
/// a raw URLSession download task.
@Observable
final class LLMModelManager {

    // MARK: - State

    var downloadedModels: Set<LLMModel> = []
    var activeDownload: LLMModel?
    var downloadProgress: Double = 0
    var downloadError: String?

    /// Called after downloadedModels changes so the app can reconcile selectedLLMModel.
    var onModelsChanged: (() -> Void)?

    @ObservationIgnored
    private var downloadTask: Task<Void, Never>?

    // MARK: - Cache Paths

    /// Base directory where MLX/HuggingFace Hub caches downloaded models.
    ///
    /// MLX's `defaultHubApi` sets `downloadBase = cachesDirectory`, and
    /// the Hub library appends `models/<repoID>` via `localRepoLocation`.
    /// So the full path is `~/Library/Caches/models/<huggingFaceID>/`.
    static let cacheBase: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("models", isDirectory: true)
    }()

    /// Returns the expected cache directory for a given HuggingFace model ID.
    static func cacheDirectory(for huggingFaceID: String) -> URL {
        cacheBase.appendingPathComponent(huggingFaceID, isDirectory: true)
    }

    // MARK: - Init

    init() {
        scanDownloadedModels()
    }

    // MARK: - Public API

    func isDownloaded(_ model: LLMModel) -> Bool {
        downloadedModels.contains(model)
    }

    /// Whether any LLM models have been downloaded.
    var hasDownloadedModels: Bool {
        !downloadedModels.isEmpty
    }

    /// Start downloading a model. Uses MLX's `loadModelContainer` which
    /// downloads from HuggingFace and caches locally.
    func download(_ model: LLMModel) {
        guard activeDownload == nil else { return }

        let info = LLMModelCatalog.info(for: model)
        activeDownload = model
        downloadProgress = 0
        downloadError = nil

        let huggingFaceID = info.huggingFaceID

        downloadTask = Task { [weak self] in
            do {
                print("[LLMModelManager] Starting download: \(info.displayName) (\(huggingFaceID))")

                // loadModelContainer downloads + loads the model.
                // We use it for the download side-effect and discard the container.
                let _ = try await loadModelContainer(id: huggingFaceID) { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.activeDownload == model else { return }
                        self.downloadProgress = fraction
                    }
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    print("[LLMModelManager] Download complete: \(info.displayName)")
                    self.downloadedModels.insert(model)
                    self.activeDownload = nil
                    self.downloadProgress = 0
                    self.downloadTask = nil
                    self.onModelsChanged?()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.activeDownload = nil
                    self?.downloadProgress = 0
                    self?.downloadTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    print("[LLMModelManager] Download failed: \(error.localizedDescription)")
                    self.downloadError = error.localizedDescription
                    self.activeDownload = nil
                    self.downloadProgress = 0
                    self.downloadTask = nil
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeDownload = nil
        downloadProgress = 0
    }

    /// Delete a cached model from disk.
    func deleteModel(_ model: LLMModel) {
        let info = LLMModelCatalog.info(for: model)
        let cacheDir = Self.cacheDirectory(for: info.huggingFaceID)

        if FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.removeItem(at: cacheDir)
        }

        downloadedModels.remove(model)
        onModelsChanged?()
    }

    // MARK: - Private

    /// Scan the HuggingFace cache directory to detect already-downloaded models.
    private func scanDownloadedModels() {
        downloadedModels = []
        for info in LLMModelCatalog.models {
            let cacheDir = Self.cacheDirectory(for: info.huggingFaceID)
            // Check for the presence of safetensors files as a reliable indicator
            if directoryContainsSafetensors(cacheDir) {
                downloadedModels.insert(info.model)
            }
        }
    }

    /// Check if a directory contains .safetensors files (indicating a complete download).
    private func directoryContainsSafetensors(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.pathExtension == "safetensors" }
    }
}
