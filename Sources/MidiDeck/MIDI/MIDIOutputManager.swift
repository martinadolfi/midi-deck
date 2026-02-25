import CoreMIDI
import Foundation

final class MIDIOutputManager {
    private var client: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0

    func start(existingClient: MIDIClientRef? = nil) {
        if let existing = existingClient {
            client = existing
        } else {
            let status = MIDIClientCreate("MidiDeck Output" as CFString, nil, nil, &client)
            guard status == noErr else {
                log("[MIDI Out] Failed to create client: \(status)")
                return
            }
        }

        let portStatus = MIDIOutputPortCreate(client, "MidiDeck Output Port" as CFString, &outputPort)
        guard portStatus == noErr else {
            log("[MIDI Out] Failed to create output port: \(portStatus)")
            return
        }
        log("[MIDI Out] Output port created (\(MIDIGetNumberOfDestinations()) destinations)")
    }

    func stop() {
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
            outputPort = 0
        }
    }

    /// Send a Note On message to control an LED on the given channel/note.
    func sendNoteOn(channel: UInt8, note: UInt8, velocity: UInt8, toDeviceNamed name: String? = nil) {
        guard let destination = findDestination(named: name) else { return }
        let statusByte: UInt8 = 0x90 | ((channel - 1) & 0x0F)
        sendMessage(bytes: [statusByte, note & 0x7F, velocity & 0x7F], to: destination)
    }

    /// Send a Note Off message (LED off).
    func sendNoteOff(channel: UInt8, note: UInt8, toDeviceNamed name: String? = nil) {
        guard let destination = findDestination(named: name) else { return }
        let statusByte: UInt8 = 0x80 | ((channel - 1) & 0x0F)
        sendMessage(bytes: [statusByte, note & 0x7F, 0], to: destination)
    }

    /// Send LED state based on a mapping's LED config.
    func sendLEDState(mapping: Mapping, on: Bool = true) {
        guard let led = mapping.led, let note = mapping.trigger.note else { return }
        let channel = mapping.trigger.channel
        if on && led.color != .off {
            sendNoteOn(channel: channel, note: note, velocity: led.velocity, toDeviceNamed: mapping.device)
        } else {
            sendNoteOff(channel: channel, note: note, toDeviceNamed: mapping.device)
        }
    }

    /// Send a CC message.
    func sendCC(channel: UInt8, controller: UInt8, value: UInt8, toDeviceNamed name: String? = nil) {
        guard let destination = findDestination(named: name) else { return }
        let statusByte: UInt8 = 0xB0 | ((channel - 1) & 0x0F)
        sendMessage(bytes: [statusByte, controller & 0x7F, value & 0x7F], to: destination)
    }

    /// Send CC feedback messages for a mapping.
    func sendFeedback(mapping: Mapping) {
        guard let feedback = mapping.feedback else { return }
        for msg in feedback {
            sendCC(channel: msg.channel, controller: msg.controller, value: msg.value, toDeviceNamed: mapping.device)
        }
    }

    /// Send LED states for all mappings in a profile.
    func sendAllLEDStates(profile: Profile, deviceFilter: String? = nil) {
        for mapping in profile.mappings {
            if let filter = deviceFilter, let device = mapping.device,
               !device.localizedCaseInsensitiveContains(filter) {
                continue
            }
            sendLEDState(mapping: mapping, on: true)
            sendFeedback(mapping: mapping)
        }
    }

    // MARK: - Private

    private func findDestination(named name: String?) -> MIDIEndpointRef? {
        let count = MIDIGetNumberOfDestinations()
        guard count > 0 else {
            log("[MIDI Out] No destinations available")
            return nil
        }

        if let name = name {
            for i in 0..<count {
                let dest = MIDIGetDestination(i)
                let destName = MIDIEngine.endpointName(dest)
                if destName.localizedCaseInsensitiveContains(name) {
                    return dest
                }
            }
            // Fall back to first destination
            log("[MIDI Out] Destination '\(name)' not found, using first available")
        }
        return MIDIGetDestination(0)
    }

    private func sendMessage(bytes: [UInt8], to destination: MIDIEndpointRef) {
        guard bytes.count <= 3, outputPort != 0 else { return }

        // Build a MIDI 1.0 UMP word
        var word: UInt32 = 0x20000000  // Message type 0x2 (MIDI 1.0 Channel Voice)
        if bytes.count > 0 { word |= UInt32(bytes[0]) << 16 }
        if bytes.count > 1 { word |= UInt32(bytes[1]) << 8 }
        if bytes.count > 2 { word |= UInt32(bytes[2]) }

        var eventList = MIDIEventList()
        var packet = MIDIEventListInit(&eventList, ._1_0)
        packet = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)

        let status = MIDISendEventList(outputPort, destination, &eventList)
        if status != noErr {
            log("[MIDI Out] Send failed: \(status)")
        }
    }
}
