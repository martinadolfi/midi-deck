import CoreAudio
import Foundation

enum AudioActions {
    private static let audio = AudioDeviceManager.shared

    static func setAudioOutput(deviceName: String) {
        _ = audio.setDefaultOutputDevice(named: deviceName)
    }

    static func setAudioInput(deviceName: String) {
        _ = audio.setDefaultInputDevice(named: deviceName)
    }

    /// Set output volume from a CC value (0-127) mapped to 0.0-1.0.
    static func setVolume(deviceName: String, ccValue: UInt8) {
        let volume = Float(ccValue) / 127.0
        _ = audio.setVolume(volume, deviceName: deviceName)
    }

    /// Set input volume from a CC value (0-127) mapped to 0.0-1.0.
    static func setInputVolume(deviceName: String, ccValue: UInt8) {
        let volume = Float(ccValue) / 127.0
        let deviceID: AudioDeviceID
        if deviceName == "default" {
            guard let dev = audio.defaultInputDevice() else { return }
            deviceID = dev.id
        } else {
            guard let dev = audio.inputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(deviceName) }) else {
                log("[Audio] Input device not found for volume: \(deviceName)")
                return
            }
            deviceID = dev.id
        }
        _ = audio.setVolume(volume, deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    /// Toggle mic mute. Returns the new mute state, or nil on failure.
    @discardableResult
    static func toggleMicMute(deviceName: String) -> Bool? {
        return audio.toggleMute(deviceName: deviceName)
    }

    static func setMicMute(deviceName: String, muted: Bool) {
        _ = audio.setMute(muted, deviceName: deviceName)
    }

    /// Switch both output and input device at once.
    static func switchAudioDevice(outputName: String?, inputName: String?) {
        if let out = outputName {
            let ok = audio.setDefaultOutputDevice(named: out)
            if ok { log("[Audio] Output → \(out)") }
        }
        if let inp = inputName {
            let ok = audio.setDefaultInputDevice(named: inp)
            if ok { log("[Audio] Input → \(inp)") }
        }
    }
}
