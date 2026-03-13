import Foundation
import OnnxRuntimeBindings

/// Wraps the Silero VAD v5 ONNX model for per-frame speech probability inference.
///
/// The processor is **stateful** — it maintains an LSTM hidden state between
/// calls. Call ``resetState()`` when starting a new recording session.
///
/// Thread safety: not thread-safe. Call from a single serial queue.
final class VADProcessor {

    // MARK: - Constants

    /// Number of new audio samples per window (32 ms at 16 kHz).
    static let windowSize = 512
    /// Context samples prepended from the previous window.
    static let contextSize = 64
    /// Total samples fed into the model per call.
    static let effectiveWindowSize = windowSize + contextSize
    /// Target sample rate expected by the model.
    static let sampleRate: Int64 = 16_000

    // MARK: - ONNX Runtime objects

    private let env: ORTEnv
    private let session: ORTSession

    // MARK: - Per-call mutable state

    /// LSTM hidden state carried across inference calls — shape [2, 1, 128].
    private var state: [Float]
    /// Rolling context buffer of the last `contextSize` samples.
    private var context: [Float]
    /// Accumulates incoming samples until a full window is ready.
    private var pendingSamples: [Float] = []

    // MARK: - Output callback

    /// Called for every `windowSize` chunk with its speech probability.
    /// The chunk is the 512-sample window (without the context prefix).
    var onProbability: ((Float, [Float]) -> Void)?

    // MARK: - Init

    /// Create a processor by loading the Silero VAD ONNX model.
    ///
    /// - Parameter modelPath: Absolute path to `silero_vad.onnx`.
    /// - Throws: ``VADError`` or ONNX Runtime errors.
    init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw VADError.modelNotFound
        }

        self.env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)

        self.state = [Float](repeating: 0, count: 2 * 1 * 128)
        self.context = [Float](repeating: 0, count: Self.contextSize)
    }

    /// Convenience initializer that finds the bundled model in the app bundle.
    convenience init() throws {
        guard let path = Bundle.main.path(forResource: "silero_vad", ofType: "onnx") else {
            throw VADError.modelNotFound
        }
        try self.init(modelPath: path)
    }

    // MARK: - Public API

    /// Feed arbitrary-length 16 kHz mono Float32 samples.
    ///
    /// Internally buffers until a full 512-sample window is available, then
    /// runs inference and calls ``onProbability`` with the result.
    func feed(samples: [Float]) throws {
        pendingSamples.append(contentsOf: samples)

        while pendingSamples.count >= Self.windowSize {
            let chunk = Array(pendingSamples.prefix(Self.windowSize))
            pendingSamples.removeFirst(Self.windowSize)

            let probability = try processWindow(chunk)
            onProbability?(probability, chunk)
        }
    }

    /// Reset LSTM state and context. Call between recording sessions.
    func resetState() {
        state = [Float](repeating: 0, count: 2 * 1 * 128)
        context = [Float](repeating: 0, count: Self.contextSize)
        pendingSamples = []
    }

    // MARK: - Private

    /// Run inference on exactly `windowSize` samples, returning speech probability.
    private func processWindow(_ samples: [Float]) throws -> Float {
        assert(samples.count == Self.windowSize)

        // Build effective input: context (64) + new samples (512) = 576
        var effectiveSamples = context + samples
        assert(effectiveSamples.count == Self.effectiveWindowSize)

        // Slide context for next call
        context = Array(samples.suffix(Self.contextSize))

        // --- Input: audio [1, 576] ---
        let inputData = NSMutableData(
            bytes: &effectiveSamples,
            length: effectiveSamples.count * MemoryLayout<Float>.size
        )
        let inputTensor = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [1, NSNumber(value: Self.effectiveWindowSize)]
        )

        // --- Input: state [2, 1, 128] ---
        let stateData = NSMutableData(
            bytes: &state,
            length: state.count * MemoryLayout<Float>.size
        )
        let stateTensor = try ORTValue(
            tensorData: stateData,
            elementType: .float,
            shape: [2, 1, 128]
        )

        // --- Input: sr [1] ---
        var sr = Self.sampleRate
        let srData = NSMutableData(
            bytes: &sr,
            length: MemoryLayout<Int64>.size
        )
        let srTensor = try ORTValue(
            tensorData: srData,
            elementType: .int64,
            shape: [1]
        )

        // --- Run ---
        let outputs = try session.run(
            withInputs: [
                "input": inputTensor,
                "state": stateTensor,
                "sr": srTensor,
            ],
            outputNames: Set(["output", "stateN"]),
            runOptions: nil
        )

        // --- Read output probability ---
        guard let outputValue = outputs["output"] else {
            throw VADError.inferenceOutputMissing
        }
        let outputData = try outputValue.tensorData() as Data
        let probability: Float = outputData.withUnsafeBytes { $0.load(as: Float.self) }

        // --- Carry state forward ---
        guard let stateNValue = outputs["stateN"] else {
            throw VADError.inferenceOutputMissing
        }
        let stateNData = try stateNValue.tensorData() as Data
        state = stateNData.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }

        return probability
    }
}

// MARK: - Errors

enum VADError: Error, LocalizedError {
    case modelNotFound
    case inferenceOutputMissing

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Silero VAD model file (silero_vad.onnx) not found"
        case .inferenceOutputMissing:
            return "VAD inference did not produce expected output tensors"
        }
    }
}
