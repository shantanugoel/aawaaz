import AVFoundation
import CoreAudio

enum AudioCaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case converterCreationFailed
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied"
        case .noInputDevice:
            return "No audio input device found"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        }
    }
}

final class AudioCaptureManager {
    static let targetSampleRate: Double = 16_000
    static let targetChannelCount: AVAudioChannelCount = 1

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?

    private(set) var isCapturing = false

    /// Called on the audio thread with 16kHz mono Float32 samples.
    var onSamplesReceived: (([Float]) -> Void)?

    // MARK: - Permissions

    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static var microphonePermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Capture Control

    /// Starts audio capture using the system's default input device.
    /// Delivers 16kHz mono Float32 samples via `onSamplesReceived`.
    func startCapture() throws {
        guard !isCapturing else { return }

        if engine == nil {
            engine = AVAudioEngine()
        }
        guard let engine else { throw AudioCaptureError.noInputDevice }

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.converterCreationFailed
        }

        guard let newConverter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        converter = newConverter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            self?.convertAndDeliver(buffer)
        }

        engine.prepare()

        do {
            try engine.start()
            isCapturing = true
        } catch {
            inputNode.removeTap(onBus: 0)
            converter = nil
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        converter = nil
        isCapturing = false
    }

    // MARK: - Private

    private func convertAndDeliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var error: NSError?
        var hasData = true

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard error == nil,
              let channelData = outputBuffer.floatChannelData,
              outputBuffer.frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))

        onSamplesReceived?(samples)
    }
}
