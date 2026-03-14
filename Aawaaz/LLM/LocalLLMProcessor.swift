import Foundation
import MLXLMCommon
import MLXLLM

/// Local LLM post-processor using MLX Swift LM for on-device text cleanup.
///
/// Loads a Qwen 3 model from the ``LLMModelCatalog``, constructs a
/// context-aware system prompt, and runs inference to clean up dictated
/// text. The model is lazy-loaded on first use and can be explicitly
/// unloaded to free memory.
///
/// Thread-safe via actor isolation. Conforms to ``PostProcessor`` so
/// it can be used as a drop-in replacement for ``NoOpProcessor`` in
/// the transcription pipeline.
///
/// ## Usage
/// ```swift
/// let processor = LocalLLMProcessor()
/// let cleaned = try await processor.process(
///     rawText: "um so I was thinking we should like go",
///     context: .unknown
/// )
/// ```
actor LocalLLMProcessor: PostProcessor {

    // MARK: - Model State

    /// Current state of the model (loading progress, loaded, error, etc.).
    ///
    /// Not `@Observable` — this is actor-isolated state. Step 3.6 will add
    /// an `@Observable` wrapper or `AsyncStream` for UI consumption.
    enum ModelState: Sendable, Equatable {
        case unloaded
        case loading(progress: Double)
        case loaded
        case error(String)
    }

    private(set) var modelState: ModelState = .unloaded
    private var modelContainer: ModelContainer?
    private var loadedModelID: String?

    /// Coordinates concurrent load requests so only one load runs at a time.
    private var activeLoadTask: Task<ModelContainer, Error>?
    /// Tracks which model ID the active load is for, to discard stale progress.
    private var activeLoadModelID: String?
    /// The model to use for inference.
    private(set) var selectedModel: LLMModel

    /// Override for testing: when set, `loadModel()` uses this HuggingFace ID
    /// instead of looking up the selected model in the catalog.
    var testOverrideModelID: String?

    // MARK: - Init

    init(selectedModel: LLMModel = LLMModelCatalog.defaultModel) {
        self.selectedModel = selectedModel
    }

    // MARK: - PostProcessor

    func process(rawText: String, context: InsertionContext, cleanupLevel: CleanupLevel, scriptPreference: HinglishScript? = nil) async throws -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        let container = try await ensureModelLoaded()
        let systemPrompt = Self.buildSystemPrompt(for: context, cleanupLevel: cleanupLevel, scriptPreference: scriptPreference)

        let params = Self.cleanupParameters(for: trimmed, cleanupLevel: cleanupLevel)
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: params,
            additionalContext: ["enable_thinking": false]
        )

        let rawOutput = try await session.respond(to: trimmed)
        let cleaned = Self.stripThinkingTags(rawOutput)

        // Guard against model returning empty or gibberish
        guard !cleaned.isEmpty else { return rawText }

        return cleaned
    }

    // MARK: - Model Lifecycle

    /// Load the model for the currently selected ``LLMModel``.
    ///
    /// If a different model is already loaded, it is unloaded first.
    /// The first call for a given model downloads weights from HuggingFace
    /// (~400 MB–2.5 GB); subsequent calls load from the local cache.
    ///
    /// Concurrent calls are coalesced: if a load is already in progress
    /// for the same model, callers wait on the existing task.
    func loadModel() async throws {
        let modelInfo = LLMModelCatalog.info(for: selectedModel)
        let targetID = testOverrideModelID ?? modelInfo.huggingFaceID

        // Already loaded with the right model
        if loadedModelID == targetID, modelContainer != nil {
            return
        }

        // If a load for the same model is already in progress, wait on it
        if let existingTask = activeLoadTask, activeLoadModelID == targetID {
            _ = try await existingTask.value
            return
        }

        // Different model selected — unload first
        if loadedModelID != nil {
            unloadModel()
        }

        modelState = .loading(progress: 0)
        activeLoadModelID = targetID

        let task = Task<ModelContainer, Error> { [weak self] in
            try await loadModelContainer(
                id: targetID
            ) { [weak self] progress in
                Task { [weak self] in
                    await self?.updateLoadingProgress(
                        progress.fractionCompleted,
                        forModelID: targetID
                    )
                }
            }
        }
        activeLoadTask = task

        do {
            let container = try await task.value
            modelContainer = container
            loadedModelID = targetID
            modelState = .loaded
            activeLoadTask = nil
            activeLoadModelID = nil
        } catch {
            modelState = .error(error.localizedDescription)
            activeLoadTask = nil
            activeLoadModelID = nil
            throw error
        }
    }

    /// Unload the model to free memory.
    ///
    /// Safe to call when no model is loaded (no-op). Cancels any
    /// in-progress load.
    func unloadModel() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
        activeLoadModelID = nil
        modelContainer = nil
        loadedModelID = nil
        modelState = .unloaded
    }

    /// Sets the test override model ID for loading arbitrary HuggingFace models.
    func setTestOverride(_ huggingFaceID: String?) {
        testOverrideModelID = huggingFaceID
        if huggingFaceID != nil {
            loadedModelID = nil
        }
    }

    /// Switch to a different model, unloading the current one first.
    ///
    /// No-op if the requested model is already selected and loaded.
    func switchModel(to model: LLMModel) async throws {
        guard model != selectedModel else { return }
        selectedModel = model
        unloadModel()
        try await loadModel()
    }

    /// Ensure the specified model is selected and loaded, ready for inference.
    ///
    /// Unlike ``switchModel(to:)``, this is safe to call even when the model
    /// is already the current selection — it will load it if not yet loaded.
    /// Use this for preloading or before inference to guarantee readiness.
    func prepare(model: LLMModel) async throws {
        selectedModel = model
        try await loadModel()
    }

    // MARK: - Memory

    /// Current process resident memory in MB (best-effort; returns -1 on failure).
    static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    // MARK: - Private

    private func updateLoadingProgress(_ fraction: Double, forModelID modelID: String) {
        // Discard stale progress updates from a previous/cancelled load
        guard activeLoadModelID == modelID else { return }
        modelState = .loading(progress: fraction)
    }

    private func ensureModelLoaded() async throws -> ModelContainer {
        let expectedID = LLMModelCatalog.info(for: selectedModel).huggingFaceID
        if let container = modelContainer, loadedModelID == expectedID {
            return container
        }
        try await loadModel()
        guard let container = modelContainer else {
            throw LLMProcessorError.modelNotLoaded
        }
        return container
    }

    // MARK: - Prompt Construction

    /// Build a system prompt tailored to the cleanup level, target app category,
    /// and field type.
    ///
    /// - ``CleanupLevel/light``: Grammar and punctuation fixes only. Preserves
    ///   everything else as spoken. No category-specific tone adjustment.
    /// - ``CleanupLevel/medium``: Adds sentence structure improvements,
    ///   capitalization, and self-correction resolution.
    /// - ``CleanupLevel/full``: Adds context-aware formatting (email → formal,
    ///   chat → casual) and nuanced filler word removal.
    ///
    /// Field-type constraints (e.g., single-line fields must not receive
    /// paragraph breaks) and Hindi/English code-switching preservation apply
    /// at all levels.
    static func buildSystemPrompt(
        for context: InsertionContext,
        cleanupLevel: CleanupLevel,
        scriptPreference: HinglishScript? = nil
    ) -> String {
        var instructions: [String] = []
        let fieldConstraint = fieldTypeConstraint(for: context.fieldType)

        switch cleanupLevel {
        case .light:
            instructions = [
                "1. Fix grammar and punctuation",
                "2. Fix obvious typos",
                "3. Keep everything else exactly as spoken — do NOT restructure sentences or change word choice",
                "4. Do NOT remove any words (even fillers like \"um\", \"uh\")",
                "5. Do NOT add, infer, or embellish content",
                "6. If the text mixes Hindi and English, preserve as-is",
            ]

        case .medium:
            instructions = [
                "1. Fix grammar, punctuation, and capitalization",
                "2. Improve sentence structure where clearly needed",
                "3. Make the smallest possible edit. Preserve unchanged words and sentence structure whenever possible",
                "4. If the speaker corrects themselves (e.g. \"actually no\", \"scratch that\", \"sorry\", \"never mind\"), replace only the superseded span and keep the stable prefix intact",
                "5. If the correction after the marker is a fragment (e.g. \"to John\" or \"Wednesday\"), attach it back to the existing sentence instead of outputting the fragment by itself",
                "6. Keep the speaker's intent and meaning exactly intact",
                "7. Do NOT add, infer, or embellish content",
                "8. If the text mixes Hindi and English, preserve the code-switching naturally",
                """
                Examples:
                Input: can you send it to Mark, oh scratch that, to John
                Output: can you send it to John
                Input: the meeting is Tuesday, actually no, Wednesday
                Output: the meeting is Wednesday
                """,
            ]

        case .full:
            let categoryInstruction = categorySpecificInstruction(for: context)
            instructions = [
                "1. Fix grammar, punctuation, and capitalization",
                "2. Remove obvious filler words (e.g. um, uh, you know, basically) only when clearly disfluent",
                "3. Improve sentence structure for clarity",
                "4. Make the smallest possible edit. Preserve unchanged words and sentence structure whenever possible",
                "5. If the speaker corrects themselves (e.g. \"actually no\", \"scratch that\", \"sorry\", \"never mind\"), replace only the superseded span and keep the stable prefix intact",
                "6. If the correction after the marker is a fragment (e.g. \"to John\" or \"Wednesday\"), attach it back to the existing sentence instead of outputting the fragment by itself",
                "7. Keep the speaker's intent and meaning exactly intact",
                "8. Do NOT add, infer, or embellish content",
                "9. If the text mixes Hindi and English, preserve the code-switching naturally",
                """
                Examples:
                Input: can you send it to Mark, oh scratch that, to John
                Output: can you send it to John
                Input: the meeting is Tuesday, actually no, Wednesday
                Output: the meeting is Wednesday
                """,
                categoryInstruction.replacingOccurrences(of: "8.", with: "10."),
            ]
        }

        // Add script preference instruction for Hinglish
        if let script = scriptPreference {
            switch script {
            case .romanized:
                instructions.append("SCRIPT: Transliterate any Devanagari (Hindi) script to Roman/Latin script (e.g. \"नमस्ते\" → \"namaste\")")
            case .devanagari:
                instructions.append("SCRIPT: Keep Hindi portions in Devanagari script. Do not romanize Hindi words.")
            case .mixed:
                break // Let the model decide naturally
            }
        }

        if !fieldConstraint.isEmpty {
            instructions.append(fieldConstraint)
        }

        let numberedInstructions = instructions.joined(separator: "\n")

        return """
            You are a text cleanup tool for dictated speech. Your ONLY job:
            \(numberedInstructions)

            Output ONLY the cleaned text. No explanations, no tags, no commentary.
            """
    }

    /// Category-specific formatting instruction for ``CleanupLevel/full``.
    private static func categorySpecificInstruction(
        for context: InsertionContext
    ) -> String {
        switch context.appCategory {
        case .email:
            return "8. Format for email: use professional tone, proper paragraphs"
        case .chat:
            return "8. Format for chat: keep casual tone, minimal formatting"
        case .code:
            return "8. Format for code editor: preserve code, symbols, filenames, APIs, and identifiers exactly; only clean surrounding prose"
        case .terminal:
            return "8. Format for terminal: preserve commands, flags, paths, casing, and spacing exactly"
        case .document:
            return "8. Format for document: use structured prose, proper paragraphs"
        case .browser, .other:
            return "8. Format naturally for general use"
        }
    }

    private static func fieldTypeConstraint(
        for fieldType: InsertionContext.TextFieldType
    ) -> String {
        switch fieldType {
        case .singleLine, .comboBox:
            return "IMPORTANT: This is a single-line field — output must be one line only, no paragraph breaks or newlines"
        case .multiLine, .webArea, .unknown:
            return ""
        }
    }

    /// Generation parameters tuned for deterministic text cleanup.
    ///
    /// Token budget is sized to the input: ~2 tokens per word with headroom
    /// for punctuation/grammar fixes. Capped to prevent runaway generation.
    private static func cleanupParameters(for inputText: String, cleanupLevel: CleanupLevel) -> GenerateParameters {
        let wordCount = inputText.split(whereSeparator: \.isWhitespace).count
        // ~1.5 tokens per word, with headroom for punctuation/grammar
        let headroom = cleanupLevel == .full ? 40 : 24
        let estimatedTokens = max(wordCount * 2 + headroom, 50)
        let maxCap = cleanupLevel == .full ? 384 : 256
        let cappedMaxTokens = min(estimatedTokens, maxCap)

        return GenerateParameters(
            maxTokens: cappedMaxTokens,
            temperature: 0.05,
            topP: 0.9,
            repetitionPenalty: 1.1,
            repetitionContextSize: 64
        )
    }

    /// Strip `<think>…</think>` tags that Qwen 3 may produce in thinking mode.
    ///
    /// Also handles dangling `<think>` without a closing tag (truncated output).
    static func stripThinkingTags(_ text: String) -> String {
        // 1. Remove well-formed <think>...</think> blocks (including newlines)
        let pattern = #"<think>[\s\S]*?</think>\s*"#
        var result = text
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: ""
            )
        }

        // 2. Handle dangling <think> without closing tag (truncated generation)
        if let danglingRange = result.range(of: "<think>") {
            result = String(result[..<danglingRange.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

// MARK: - Errors

enum LLMProcessorError: LocalizedError {
    case modelNotLoaded
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "LLM model is not loaded. Please wait for the model to finish loading."
        case .processingFailed(let reason):
            return "LLM processing failed: \(reason)"
        }
    }
}
