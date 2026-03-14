import Foundation

/// Available LLM models for local text cleanup.
///
/// Each case maps to an MLX-quantized HuggingFace artifact that can be
/// loaded by ``LocalLLMProcessor`` via `loadModelContainer(id:)`.
enum LLMModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case qwen3_0_6B = "qwen3-0.6b"
    case qwen3_1_7B = "qwen3-1.7b"
    case qwen3_5_0_8B_4bit = "qwen3.5-0.8b-4bit"
    case qwen3_5_2B_4bit = "qwen3.5-2b-4bit"

    var id: String { rawValue }
}

/// Metadata for an LLM model in the catalog.
struct LLMModelInfo: Identifiable, Equatable, Sendable {
    let model: LLMModel
    let displayName: String

    /// HuggingFace model identifier passed to `loadModelContainer(id:)`.
    let huggingFaceID: String

    let sizeDescription: String
    let sizeBytes: Int64
    let ramUsage: String
    let speed: String
    let quality: String
    let recommendedFor: String

    var id: String { model.id }
}

/// Catalog of LLM models available for local text cleanup.
///
/// Mirrors the pattern of ``ModelCatalog`` (Whisper models). Models must
/// be explicitly downloaded via ``LLMModelManager`` before use.
enum LLMModelCatalog {

    static let models: [LLMModelInfo] = [
        LLMModelInfo(
            model: .qwen3_0_6B,
            displayName: "Qwen 3 0.6B",
            huggingFaceID: "mlx-community/Qwen3-0.6B-4bit",
            sizeDescription: "~470 MB",
            sizeBytes: 470_000_000,
            ramUsage: "~1 GB",
            speed: "<0.5s",
            quality: "Good",
            recommendedFor: "Default — fastest, lowest memory"
        ),
        LLMModelInfo(
            model: .qwen3_1_7B,
            displayName: "Qwen 3 1.7B",
            huggingFaceID: "mlx-community/Qwen3-1.7B-4bit",
            sizeDescription: "~1.1 GB",
            sizeBytes: 1_100_000_000,
            ramUsage: "~1.5 GB",
            speed: "<0.8s",
            quality: "High",
            recommendedFor: "Best balance — recommended for 16 GB+ RAM"
        ),
        LLMModelInfo(
            model: .qwen3_5_0_8B_4bit,
            displayName: "Qwen 3.5 0.8B (4-bit)",
            huggingFaceID: "mlx-community/Qwen3.5-0.8B-4bit",
            sizeDescription: "~622 MB",
            sizeBytes: 622_000_000,
            ramUsage: "~1.2 GB",
            speed: "~2s",
            quality: "Good",
            recommendedFor: "Slow on current MLX — not recommended"
        ),
        LLMModelInfo(
            model: .qwen3_5_2B_4bit,
            displayName: "Qwen 3.5 2B (4-bit)",
            huggingFaceID: "mlx-community/Qwen3.5-2B-4bit",
            sizeDescription: "~1.5 GB",
            sizeBytes: 1_500_000_000,
            ramUsage: "~2 GB",
            speed: "~3–5s",
            quality: "High",
            recommendedFor: "Slow on current MLX — not recommended"
        ),
    ]

    /// The default model for new installs.
    static let defaultModel: LLMModel = .qwen3_0_6B

    /// Look up metadata for a specific model.
    static func info(for model: LLMModel) -> LLMModelInfo {
        models.first { $0.model == model }!
    }

    /// Suggest a model based on available system RAM.
    ///
    /// - 16 GB+: Qwen 3 1.7B (best quality with good speed)
    /// - <16 GB: Qwen 3 0.6B (fastest, lowest memory)
    static func recommendedModel() -> LLMModel {
        systemMemoryGB >= 16 ? .qwen3_1_7B : .qwen3_0_6B
    }

    /// Total physical memory in GB.
    static var systemMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
}
