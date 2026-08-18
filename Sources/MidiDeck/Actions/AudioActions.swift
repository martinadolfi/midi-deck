import CoreAudio
import Foundation

enum AudioActions {
    private static let audio = AudioDeviceManager.shared

    @discardableResult
    static func setAudioOutput(deviceName: String) -> Bool {
        audio.setDefaultOutputDevice(named: deviceName)
    }

    @discardableResult
    static func setAudioInput(deviceName: String) -> Bool {
        audio.setDefaultInputDevice(named: deviceName)
    }

    /// Set output volume from a CC value (0-127) mapped to 0.0-1.0.
    @discardableResult
    static func setVolume(deviceName: String, ccValue: UInt8) -> Bool {
        let volume = Float(ccValue) / 127.0
        return audio.setVolume(volume, deviceName: deviceName)
    }

    /// Set input volume from a CC value (0-127) mapped to 0.0-1.0.
    @discardableResult
    static func setInputVolume(deviceName: String, ccValue: UInt8) -> Bool {
        let volume = Float(ccValue) / 127.0
        guard let device = audio.inputDevice(named: deviceName) else {
            log("[Audio] Input device not found for volume: \(deviceName)")
            return false
        }
        return audio.setVolume(volume, deviceID: device.id, scope: kAudioDevicePropertyScopeInput)
    }

    /// Toggle mic mute. Returns the new mute state, or nil on failure.
    @discardableResult
    static func toggleMicMute(deviceName: String) -> Bool? {
        return audio.toggleMute(deviceName: deviceName)
    }

    @discardableResult
    static func setMicMute(deviceName: String, muted: Bool) -> Bool {
        audio.setMute(muted, deviceName: deviceName)
    }

    /// Switch both output and input device at once.
    @discardableResult
    static func switchAudioDevice(outputName: String?, inputName: String?) -> AudioSwitchResult {
        var outputResult: Bool?
        var inputResult: Bool?
        if let out = outputName {
            let ok = audio.setDefaultOutputDevice(named: out)
            if ok { log("[Audio] Output → \(out)") }
            outputResult = ok
        }
        if let inp = inputName {
            let ok = audio.setDefaultInputDevice(named: inp)
            if ok { log("[Audio] Input → \(inp)") }
            inputResult = ok
        }
        return AudioSwitchResult(outputSucceeded: outputResult, inputSucceeded: inputResult)
    }
}

struct AudioSwitchResult {
    let outputSucceeded: Bool?
    let inputSucceeded: Bool?

    var succeeded: Bool {
        let attempted = [outputSucceeded, inputSucceeded].compactMap { $0 }
        return !attempted.isEmpty && attempted.allSatisfy { $0 }
    }
}
