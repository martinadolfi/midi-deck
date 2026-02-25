import Foundation

struct Configuration: Codable {
    var version: Int = 1
    var activeProfile: String = "default"
    var profiles: [String: Profile] = ["default": Profile()]
}

struct Profile: Codable {
    var mappings: [Mapping] = []
}

struct Mapping: Codable, Identifiable {
    var id: UUID
    var description: String
    var device: String?
    var trigger: Trigger
    var action: Action
    var led: LEDConfig?
    var feedback: [MIDIFeedback]?

    init(
        id: UUID = UUID(),
        description: String = "",
        device: String? = nil,
        trigger: Trigger,
        action: Action,
        led: LEDConfig? = nil,
        feedback: [MIDIFeedback]? = nil
    ) {
        self.id = id
        self.description = description
        self.device = device
        self.trigger = trigger
        self.action = action
        self.led = led
        self.feedback = feedback
    }
}

struct Trigger: Codable, Hashable {
    var type: TriggerType
    var channel: UInt8
    var note: UInt8?
    var controller: UInt8?

    enum TriggerType: String, Codable, CaseIterable {
        case noteOn
        case noteOff
        case controlChange
    }

    var matchKey: String {
        switch type {
        case .noteOn:
            return "noteOn:\(channel):\(note ?? 0)"
        case .noteOff:
            return "noteOff:\(channel):\(note ?? 0)"
        case .controlChange:
            return "cc:\(channel):\(controller ?? 0)"
        }
    }
}

struct Action: Codable {
    var type: ActionType
    var bundleId: String?
    var device: String?
    var inputDevice: String?
    var profile: String?
    var muted: Bool?
    var notify: String?

    enum ActionType: String, Codable, CaseIterable {
        case openApp
        case setAudioOutput
        case setAudioInput
        case setVolume
        case setInputVolume
        case switchAudioDevice
        case toggleMicMute
        case setMicMute
        case switchProfile
    }
}

/// A MIDI CC message to send as feedback when a mapping fires.
struct MIDIFeedback: Codable {
    var channel: UInt8
    var controller: UInt8
    var value: UInt8
}

struct LEDConfig: Codable {
    var color: LEDColor
    var behavior: LEDBehavior

    enum LEDColor: String, Codable, CaseIterable {
        case off
        case red
        case green
        case yellow
        case blue
        case magenta
        case cyan
        case white
    }

    enum LEDBehavior: String, Codable, CaseIterable {
        case solid
        case blink
        case toggleOnMute
    }

    var velocity: UInt8 {
        switch color {
        case .off: return 0
        case .red: return 5
        case .green: return 17
        case .yellow: return 41
        case .blue: return 45
        case .magenta: return 53
        case .cyan: return 37
        case .white: return 127
        }
    }
}

// MARK: - Trigger matching helpers

extension Trigger {
    func matches(_ event: MIDIEvent) -> Bool {
        switch (type, event) {
        case (.noteOn, .noteOn(let ch, let n, _)):
            return ch == channel && n == (note ?? 0)
        case (.noteOff, .noteOff(let ch, let n, _)):
            return ch == channel && n == (note ?? 0)
        case (.controlChange, .controlChange(let ch, let cc, _)):
            return ch == channel && cc == (controller ?? 0)
        default:
            return false
        }
    }
}
