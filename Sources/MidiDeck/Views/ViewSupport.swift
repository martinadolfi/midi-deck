import SwiftUI

extension Trigger.TriggerType {
    var displayName: String {
        switch self {
        case .noteOn: return "Pad / key press"
        case .noteOff: return "Pad / key release"
        case .controlChange: return "Knob / fader"
        }
    }

    var systemImage: String {
        switch self {
        case .noteOn: return "button.programmable"
        case .noteOff: return "button.programmable.square"
        case .controlChange: return "slider.horizontal.3"
        }
    }
}

extension Action.ActionType {
    var displayName: String {
        switch self {
        case .openApp: return "Open or cycle an app"
        case .setAudioOutput: return "Switch audio output"
        case .setAudioInput: return "Switch audio input"
        case .setVolume: return "Control output volume"
        case .setInputVolume: return "Control input volume"
        case .switchAudioDevice: return "Switch input and output"
        case .toggleMicMute: return "Toggle microphone mute"
        case .setMicMute: return "Set microphone mute"
        case .switchProfile: return "Switch profile"
        }
    }

    var shortName: String {
        switch self {
        case .openApp: return "Open app"
        case .setAudioOutput: return "Audio output"
        case .setAudioInput: return "Audio input"
        case .setVolume: return "Output volume"
        case .setInputVolume: return "Input volume"
        case .switchAudioDevice: return "Audio pair"
        case .toggleMicMute: return "Toggle mute"
        case .setMicMute: return "Set mute"
        case .switchProfile: return "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .openApp: return "app.dashed"
        case .setAudioOutput: return "speaker.wave.2"
        case .setAudioInput: return "mic"
        case .setVolume: return "speaker.wave.3"
        case .setInputVolume: return "waveform"
        case .switchAudioDevice: return "arrow.triangle.swap"
        case .toggleMicMute, .setMicMute: return "mic.slash"
        case .switchProfile: return "rectangle.3.group"
        }
    }

}

extension LEDConfig.LEDColor {
    var displayName: String { rawValue.capitalized }

    var swiftUIColor: Color {
        switch self {
        case .off: return .gray
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .blue: return .blue
        case .magenta: return .purple
        case .cyan: return .cyan
        case .white: return .white
        }
    }
}

extension LEDConfig.LEDBehavior {
    var displayName: String {
        switch self {
        case .solid: return "Stay on"
        case .blink: return "Pulse when triggered"
        case .toggleOnMute: return "Follow microphone mute"
        }
    }
}

extension MIDIEvent {
    var friendlyDescription: String {
        switch self {
        case .noteOn(let channel, let note, let velocity):
            return "Pressed note \(note) · Channel \(channel) · Velocity \(velocity)"
        case .noteOff(let channel, let note, _):
            return "Released note \(note) · Channel \(channel)"
        case .controlChange(let channel, let controller, let value):
            return "CC \(controller) · Channel \(channel) · Value \(value)"
        }
    }
}

extension Mapping {
    var displayTitle: String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? triggerSummary : trimmed
    }

    var triggerSummary: String {
        switch trigger.type {
        case .noteOn:
            return "Press · Ch \(trigger.channel) · Note \(trigger.note ?? 0)"
        case .noteOff:
            return "Release · Ch \(trigger.channel) · Note \(trigger.note ?? 0)"
        case .controlChange:
            return "Fader/knob · Ch \(trigger.channel) · CC \(trigger.controller ?? 0)"
        }
    }

    var actionSummary: String {
        switch action.type {
        case .openApp:
            return action.bundleId.map { "Open \($0)" } ?? "Choose an application"
        case .setAudioOutput:
            return "Output → \(action.device ?? "Choose device")"
        case .setAudioInput:
            return "Input → \(action.device ?? "Choose device")"
        case .setVolume:
            return "Output volume · \(action.device ?? "default")"
        case .setInputVolume:
            return "Input volume · \(action.device ?? "default")"
        case .switchAudioDevice:
            return "Audio → \(action.device ?? "output?") / \(action.inputDevice ?? "input?")"
        case .toggleMicMute:
            return "Toggle mic · \(action.device ?? "default")"
        case .setMicMute:
            return "Mic → \((action.muted ?? true) ? "muted" : "unmuted")"
        case .switchProfile:
            return "Profile → \(action.profile ?? "Choose profile")"
        }
    }
}
