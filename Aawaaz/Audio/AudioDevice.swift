import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    static func allInputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputChannels(deviceID: deviceID) else { return nil }
            guard let name = getDeviceName(deviceID: deviceID) else { return nil }
            guard let uid = getDeviceUID(deviceID: deviceID) else { return nil }
            return AudioDevice(id: deviceID, name: name, uid: uid)
        }
    }

    static func defaultInputDevice() -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        guard let name = getDeviceName(deviceID: deviceID) else { return nil }
        guard let uid = getDeviceUID(deviceID: deviceID) else { return nil }
        return AudioDevice(id: deviceID, name: name, uid: uid)
    }

    /// Look up the `AudioDeviceID` for a given device UID string.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first { $0.uid == uid }?.id
    }

    // MARK: - Private Helpers

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return false
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else {
            return false
        }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        getStringProperty(kAudioDevicePropertyDeviceNameCFString, deviceID: deviceID)
    }

    private static func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        getStringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    private static func getStringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef) == noErr,
              let name = nameRef?.takeRetainedValue() else {
            return nil
        }
        return name as String
    }
}

// MARK: - Device Change Observer

final class AudioDeviceObserver {
    fileprivate let onChange: () -> Void
    private var isObserving = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        startObserving()
    }

    private func startObserving() {
        guard !isObserving else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioDeviceChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status == noErr {
            isObserving = true
        }
    }

    func stopObserving() {
        guard isObserving else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            audioDeviceChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        isObserving = false
    }

    deinit {
        stopObserving()
    }
}

private func audioDeviceChangeListener(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let observer = Unmanaged<AudioDeviceObserver>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        observer.onChange()
    }
    return noErr
}
