import Foundation
import MLXLMCommon
import MLXLLM

// MARK: - Spike Benchmark Result

/// Results from a single MLX LLM spike benchmark run.
///
/// This is throwaway spike code for Step 3.3 — validates that MLX Swift LM
/// works for our text cleanup use case before committing to the runtime.
struct LLMSpikeBenchmark: CustomStringConvertible {
    let modelID: String
    let modelLoadTimeSeconds: Double
    let coldInferenceTimeSeconds: Double
    let warmInferenceTimeSeconds: Double
    let memoryAfterLoadMB: Double
    let memoryAfterInferenceMB: Double
    let coldInput: String
    let coldOutput: String
    let warmInput: String
    let warmOutput: String

    var description: String {
        """
        ╔══════════════════════════════════════════════════════╗
        ║          MLX LLM Spike Benchmark Results            ║
        ╠══════════════════════════════════════════════════════╣
        ║ Model:              \(modelID)
        ║ Model Load (cold):  \(String(format: "%.2f", modelLoadTimeSeconds))s
        ║ Inference (cold):   \(String(format: "%.2f", coldInferenceTimeSeconds))s
        ║ Inference (warm):   \(String(format: "%.2f", warmInferenceTimeSeconds))s
        ║ Memory after load:  \(String(format: "%.1f", memoryAfterLoadMB)) MB
        ║ Memory after infer: \(String(format: "%.1f", memoryAfterInferenceMB)) MB
        ╠══════════════════════════════════════════════════════╣
        ║ Cold Run:
        ║   Input:  \(coldInput.prefix(80))
        ║   Output: \(coldOutput.prefix(80))
        ║ Warm Run:
        ║   Input:  \(warmInput.prefix(80))
        ║   Output: \(warmOutput.prefix(80))
        ╚══════════════════════════════════════════════════════╝
        """
    }
}

// MARK: - Spike Runner

/// Runs MLX Swift LM spike benchmarks for text cleanup evaluation.
///
/// Usage from tests:
/// ```swift
/// let runner = LLMSpikeRunner()
/// let result = try await runner.runBenchmark()
/// print(result)
/// ```
actor LLMSpikeRunner {

    static let defaultModelID = "mlx-community/Qwen3-0.6B-4bit"

    private static let systemPrompt = """
        You are a text cleanup tool for dictated speech. Your ONLY job:
        1. Fix grammar, punctuation, and capitalization
        2. Remove filler words (um, uh, like, you know, basically)
        3. Keep the speaker's intent and meaning exactly intact
        4. Do NOT add, infer, or embellish content

        Output ONLY the cleaned text. No explanations, no tags, no commentary.
        """

    static let sampleTexts = [
        // English with fillers
        "so um I was thinking that we should like go to the store and um get some milk and uh maybe some bread too you know",
        // English with self-corrections
        "hey so basically I wanted to tell you that um the meeting has been moved to uh Thursday at like 3 pm and we need to um prepare the presentation",
        // Hinglish
        "acha so mujhe lagta hai ki humein kal subah meeting rakhni chahiye aur um usmein sab ko bulana chahiye you know",
    ]

    /// Run the full spike benchmark: cold load → cold inference → warm inference.
    ///
    /// - Note: On the very first run, `modelLoadTimeSeconds` includes the model
    ///   download from HuggingFace (~400 MB). Subsequent runs load from the local
    ///   cache and give representative cold-start numbers.
    func runBenchmark(
        modelID: String = defaultModelID,
        sampleTexts: [String]? = nil
    ) async throws -> LLMSpikeBenchmark {
        let texts = sampleTexts ?? Self.sampleTexts
        guard texts.count >= 2 else {
            throw SpikeError.insufficientSampleTexts
        }

        // 1. Model load (cold start measurement)
        let memBefore = Self.currentMemoryMB()
        print("[Spike] Loading model \(modelID) …")

        let loadStart = CFAbsoluteTimeGetCurrent()
        let container = try await loadModelContainer(id: modelID) { progress in
            if progress.fractionCompleted < 1.0 {
                print("[Spike]   download: \(Int(progress.fractionCompleted * 100))%")
            }
        }
        let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
        let memAfterLoad = Self.currentMemoryMB()

        print("[Spike] Model loaded in \(String(format: "%.2f", loadTime))s "
              + "(memory: \(String(format: "+%.0f", memAfterLoad - memBefore)) MB)")

        // 2. Cold inference (first run — includes KV cache allocation)
        let coldInput = texts[0]
        print("[Spike] Running cold inference …")

        let coldSession = ChatSession(
            container,
            instructions: Self.systemPrompt,
            generateParameters: Self.cleanupParameters,
            additionalContext: ["enable_thinking": false]
        )

        let coldStart = CFAbsoluteTimeGetCurrent()
        let coldRawOutput = try await coldSession.respond(to: coldInput)
        let coldTime = CFAbsoluteTimeGetCurrent() - coldStart
        let coldOutput = Self.stripThinkingTags(coldRawOutput)

        print("[Spike] Cold inference: \(String(format: "%.2f", coldTime))s")
        if coldRawOutput != coldOutput {
            print("[Spike]   Raw output: \(coldRawOutput.prefix(120))")
        }

        // 3. Warm-model / cold-session inference (new session, same model — KV cache
        //    re-created but model weights are already resident in memory. This matches
        //    expected product usage where each transcription gets a fresh session.)
        let warmInput = texts[1]
        print("[Spike] Running warm inference …")

        let warmSession = ChatSession(
            container,
            instructions: Self.systemPrompt,
            generateParameters: Self.cleanupParameters,
            additionalContext: ["enable_thinking": false]
        )

        let warmStart = CFAbsoluteTimeGetCurrent()
        let warmRawOutput = try await warmSession.respond(to: warmInput)
        let warmTime = CFAbsoluteTimeGetCurrent() - warmStart
        let warmOutput = Self.stripThinkingTags(warmRawOutput)
        let memAfterInference = Self.currentMemoryMB()

        print("[Spike] Warm inference: \(String(format: "%.2f", warmTime))s")
        if warmRawOutput != warmOutput {
            print("[Spike]   Raw output: \(warmRawOutput.prefix(120))")
        }

        return LLMSpikeBenchmark(
            modelID: modelID,
            modelLoadTimeSeconds: loadTime,
            coldInferenceTimeSeconds: coldTime,
            warmInferenceTimeSeconds: warmTime,
            memoryAfterLoadMB: memAfterLoad,
            memoryAfterInferenceMB: memAfterInference,
            coldInput: coldInput,
            coldOutput: coldOutput,
            warmInput: warmInput,
            warmOutput: warmOutput
        )
    }

    // MARK: - Internals

    enum SpikeError: LocalizedError {
        case insufficientSampleTexts

        var errorDescription: String? {
            switch self {
            case .insufficientSampleTexts:
                return "Need at least 2 sample texts for cold/warm comparison"
            }
        }
    }

    /// Parameters tuned for deterministic text cleanup (not creative generation).
    private static let cleanupParameters = GenerateParameters(
        maxTokens: 512,
        temperature: 0.1,
        topP: 0.9,
        repetitionPenalty: 1.1,
        repetitionContextSize: 64
    )

    /// Strip `<think>…</think>` tags that Qwen 3 may produce in thinking mode.
    /// Also handles dangling `<think>` without a closing tag (truncated output).
    static func stripThinkingTags(_ text: String) -> String {
        // 1. Remove well-formed <think>...</think> blocks (including newlines)
        let pattern = #"<think>[\s\S]*?</think>\s*"#
        var result = text
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // 2. Handle dangling <think> without closing tag (truncated generation)
        if let danglingRange = result.range(of: "<think>") {
            result = String(result[..<danglingRange.lowerBound])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
}
