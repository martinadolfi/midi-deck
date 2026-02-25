import CoreAudio
import AudioToolbox
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool
}

final class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    private init() {}

    // MARK: - Device Enumeration

    func allDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID) else { return nil }
            let hasInput = channelCount(deviceID, scope: kAudioDevicePropertyScopeInput) > 0
            let hasOutput = channelCount(deviceID, scope: kAudioDevicePropertyScopeOutput) > 0
            return AudioDevice(id: deviceID, name: name, uid: uid, hasInput: hasInput, hasOutput: hasOutput)
        }
    }

    func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasOutput }
    }

    func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasInput }
    }

    func findDevice(named name: String) -> AudioDevice? {
        if name == "default" {
            return nil  // Caller should handle "default" specially
        }
        return allDevices().first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    // MARK: - Default Device

    func defaultOutputDevice() -> AudioDevice? {
        let deviceID = getDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard deviceID != kAudioObjectUnknown else { return nil }
        guard let name = getDeviceName(deviceID), let uid = getDeviceUID(deviceID) else { return nil }
        return AudioDevice(id: deviceID, name: name, uid: uid, hasInput: false, hasOutput: true)
    }

    func defaultInputDevice() -> AudioDevice? {
        let deviceID = getDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        guard deviceID != kAudioObjectUnknown else { return nil }
        guard let name = getDeviceName(deviceID), let uid = getDeviceUID(deviceID) else { return nil }
        return AudioDevice(id: deviceID, name: name, uid: uid, hasInput: true, hasOutput: false)
    }

    // MARK: - Set Default Device

    func setDefaultOutputDevice(_ device: AudioDevice) -> Bool {
        return setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func setDefaultOutputDevice(named name: String) -> Bool {
        guard let device = outputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            log("[Audio] Output device not found: \(name)")
            return false
        }
        let result = setDefaultOutputDevice(device)
        if result {
            log("[Audio] Set default output to: \(device.name)")
        }
        return result
    }

    func setDefaultInputDevice(_ device: AudioDevice) -> Bool {
        return setDefaultDevice(device.id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func setDefaultInputDevice(named name: String) -> Bool {
        guard let device = inputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            log("[Audio] Input device not found: \(name)")
            return false
        }
        let result = setDefaultInputDevice(device)
        if result {
            log("[Audio] Set default input to: \(device.name)")
        }
        return result
    }

    // MARK: - Volume

    func getVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> Float? {
        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if virtual main volume is supported
        if !AudioObjectHasProperty(deviceID, &propertyAddress) {
            // Fall back to main volume
            propertyAddress.mSelector = kAudioDevicePropertyVolumeScalar
            propertyAddress.mElement = 1  // Channel 1
            guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }
        }

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volume)
        return status == noErr ? volume : nil
    }

    func setVolume(_ volume: Float, deviceID: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> Bool {
        var vol = max(0, min(1, volume))
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &propertyAddress) {
            propertyAddress.mSelector = kAudioDevicePropertyVolumeScalar
            propertyAddress.mElement = 1
            guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return false }
        }

        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &vol)
        return status == noErr
    }

    func setVolume(_ volume: Float, deviceName: String) -> Bool {
        let deviceID: AudioDeviceID
        if deviceName == "default" {
            guard let dev = defaultOutputDevice() else { return false }
            deviceID = dev.id
        } else {
            guard let dev = findDevice(named: deviceName) else {
                log("[Audio] Device not found for volume: \(deviceName)")
                return false
            }
            deviceID = dev.id
        }
        return setVolume(volume, deviceID: deviceID)
    }

    // MARK: - Mute

    func isMuted(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput) -> Bool? {
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &muted)
        return status == noErr ? (muted != 0) : nil
    }

    func setMute(_ muted: Bool, deviceID: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput) -> Bool {
        var muteValue: UInt32 = muted ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return false }
        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &muteValue)
        return status == noErr
    }

    func toggleMute(deviceName: String) -> Bool? {
        let deviceID: AudioDeviceID
        if deviceName == "default" {
            guard let dev = defaultInputDevice() else { return nil }
            deviceID = dev.id
        } else {
            guard let dev = inputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(deviceName) }) else {
                log("[Audio] Input device not found for mute: \(deviceName)")
                return nil
            }
            deviceID = dev.id
        }

        guard let currentlyMuted = isMuted(deviceID: deviceID) else { return nil }
        let newState = !currentlyMuted
        let success = setMute(newState, deviceID: deviceID)
        if success {
            log("[Audio] Mic \(newState ? "muted" : "unmuted"): \(deviceName)")
        }
        return success ? newState : nil
    }

    func setMute(_ muted: Bool, deviceName: String) -> Bool {
        let deviceID: AudioDeviceID
        if deviceName == "default" {
            guard let dev = defaultInputDevice() else { return false }
            deviceID = dev.id
        } else {
            guard let dev = inputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(deviceName) }) else {
                log("[Audio] Input device not found for mute: \(deviceName)")
                return false
            }
            deviceID = dev.id
        }
        return setMute(muted, deviceID: deviceID)
    }

    // MARK: - Private Helpers

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &result)
        guard status == noErr, let cfString = result?.takeUnretainedValue() else { return nil }
        return cfString as String
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &result)
        guard status == noErr, let cfString = result?.takeUnretainedValue() else { return nil }
        return cfString as String
    }

    private func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }

        let status2 = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferList)
        guard status2 == noErr else { return 0 }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func getDefaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        )
        return deviceID
    }

    private func setDefaultDevice(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var devID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, dataSize, &devID
        )
        return status == noErr
    }
}
