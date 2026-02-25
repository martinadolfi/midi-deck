import CoreMIDI
import Foundation

/// Represents a parsed MIDI event.
enum MIDIEvent: Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)

    var channel: UInt8 {
        switch self {
        case .noteOn(let ch, _, _): return ch
        case .noteOff(let ch, _, _): return ch
        case .controlChange(let ch, _, _): return ch
        }
    }

    var description: String {
        switch self {
        case .noteOn(let ch, let note, let vel):
            return "NoteOn ch:\(ch) note:\(note) vel:\(vel)"
        case .noteOff(let ch, let note, let vel):
            return "NoteOff ch:\(ch) note:\(note) vel:\(vel)"
        case .controlChange(let ch, let cc, let val):
            return "CC ch:\(ch) cc:\(cc) val:\(val)"
        }
    }

    /// Parse MIDI 1.0 protocol UMP words into MIDIEvents.
    /// UMP MIDI 1.0 Channel Voice messages are message type 0x2 (32-bit, 1 word).
    static func parse(words: [UInt32]) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            let messageType = (word >> 28) & 0x0F

            switch messageType {
            case 0x2:
                // MIDI 1.0 Channel Voice Message (1 word)
                let status = UInt8((word >> 16) & 0xF0)
                let channel = UInt8((word >> 16) & 0x0F) + 1  // 1-based channel
                let data1 = UInt8((word >> 8) & 0x7F)
                let data2 = UInt8(word & 0x7F)

                switch status {
                case 0x90:
                    if data2 > 0 {
                        events.append(.noteOn(channel: channel, note: data1, velocity: data2))
                    } else {
                        events.append(.noteOff(channel: channel, note: data1, velocity: 0))
                    }
                case 0x80:
                    events.append(.noteOff(channel: channel, note: data1, velocity: data2))
                case 0xB0:
                    events.append(.controlChange(channel: channel, controller: data1, value: data2))
                default:
                    break
                }
                i += 1

            case 0x4:
                // MIDI 2.0 Channel Voice Message (2 words) — skip for now
                i += 2

            case 0x0, 0x1:
                // Utility / System messages (1 word)
                i += 1

            case 0x3, 0x5:
                // Data messages (2 words)
                i += 2

            default:
                i += 1
            }
        }
        return events
    }

    /// Parse legacy MIDI 1.0 bytes (3-byte messages) — fallback for non-UMP sources.
    static func fromBytes(_ bytes: [UInt8]) -> MIDIEvent? {
        guard bytes.count >= 2 else { return nil }
        let status = bytes[0] & 0xF0
        let channel = (bytes[0] & 0x0F) + 1  // 1-based channel
        let data1 = bytes[1]
        let data2 = bytes.count > 2 ? bytes[2] : 0

        switch status {
        case 0x90:
            if data2 > 0 {
                return .noteOn(channel: channel, note: data1, velocity: data2)
            } else {
                return .noteOff(channel: channel, note: data1, velocity: 0)
            }
        case 0x80:
            return .noteOff(channel: channel, note: data1, velocity: data2)
        case 0xB0:
            return .controlChange(channel: channel, controller: data1, value: data2)
        default:
            return nil
        }
    }
}
