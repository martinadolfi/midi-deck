import CoreMIDI
import Foundation

final class MIDIOutputManager: @unchecked Sendable {
    enum DestinationSelector: Equatable {
        case endpoint(MIDIEndpointReference)
        case legacyName(String)
        case implicit
    }

    enum DestinationResolution: Equatable {
        case resolved(index: Int)
        case unavailable(DestinationResolutionFailure)
    }

    enum DestinationResolutionFailure: Equatable {
        case noDestinations
        case endpointNotConnected(name: String, uniqueID: Int32)
        case endpointAmbiguous(uniqueID: Int32)
        case legacyNameNotConnected(String)
        case legacyNameAmbiguous(String)
        case implicitRequiresSelection(destinationCount: Int)

        var logMessage: String {
            switch self {
            case .noDestinations:
                return "[MIDI Out] No destinations available"
            case .endpointNotConnected(let name, let uniqueID):
                return "[MIDI Out] Destination '\(name)' [\(uniqueID)] is not connected"
            case .endpointAmbiguous(let uniqueID):
                return "[MIDI Out] Destination ID \(uniqueID) is ambiguous; message not sent"
            case .legacyNameNotConnected(let name):
                return "[MIDI Out] Legacy destination '\(name)' is not connected"
            case .legacyNameAmbiguous(let name):
                return "[MIDI Out] Legacy destination '\(name)' is ambiguous; message not sent"
            case .implicitRequiresSelection(let destinationCount):
                return "[MIDI Out] \(destinationCount) destinations available; select one before sending feedback"
            }
        }
    }

    private let outputQueue = DispatchQueue(label: "com.midideck.midi.output")
    private let outputQueueKey = DispatchSpecificKey<Void>()

    private var client: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0
    private var ownsClient = false

    init() {
        outputQueue.setSpecific(key: outputQueueKey, value: ())
    }

    deinit {
        stop()
    }

    func start(existingClient: MIDIClientRef? = nil) {
        syncOnOutputQueue {
            guard outputPort == 0 else { return }

            if let existingClient, existingClient != 0 {
                client = existingClient
                ownsClient = false
            } else {
                let status = MIDIClientCreate("MidiDeck Output" as CFString, nil, nil, &client)
                guard status == noErr else {
                    client = 0
                    ownsClient = false
                    log("[MIDI Out] Failed to create client: \(status)")
                    return
                }
                ownsClient = true
            }

            let portStatus = MIDIOutputPortCreate(client, "MidiDeck Output Port" as CFString, &outputPort)
            guard portStatus == noErr else {
                log("[MIDI Out] Failed to create output port: \(portStatus)")
                cleanupClientIfOwned()
                client = 0
                outputPort = 0
                return
            }
            log("[MIDI Out] Output port created (\(MIDIGetNumberOfDestinations()) destinations)")
        }
    }

    func stop() {
        syncOnOutputQueue {
            if outputPort != 0 {
                MIDIPortDispose(outputPort)
                outputPort = 0
            }
            cleanupClientIfOwned()
            client = 0
        }
    }

    /// Sends a Note On message. With no explicit destination, routing is only
    /// permitted when CoreMIDI exposes exactly one destination.
    func sendNoteOn(
        channel: UInt8,
        note: UInt8,
        velocity: UInt8,
        to destination: MIDIEndpointReference? = nil
    ) {
        guard validate(channel: channel) else { return }
        let statusByte: UInt8 = 0x90 | (channel - 1)
        sendMessage(
            bytes: [statusByte, note & 0x7F, velocity & 0x7F],
            selector: selector(for: destination)
        )
    }

    /// Legacy name-based API. A name must match exactly one destination.
    func sendNoteOn(
        channel: UInt8,
        note: UInt8,
        velocity: UInt8,
        toDeviceNamed name: String?
    ) {
        guard validate(channel: channel) else { return }
        let statusByte: UInt8 = 0x90 | (channel - 1)
        sendMessage(
            bytes: [statusByte, note & 0x7F, velocity & 0x7F],
            selector: selector(forLegacyName: name)
        )
    }

    /// Sends a Note Off message. With no explicit destination, routing is only
    /// permitted when CoreMIDI exposes exactly one destination.
    func sendNoteOff(
        channel: UInt8,
        note: UInt8,
        to destination: MIDIEndpointReference? = nil
    ) {
        guard validate(channel: channel) else { return }
        let statusByte: UInt8 = 0x80 | (channel - 1)
        sendMessage(bytes: [statusByte, note & 0x7F, 0], selector: selector(for: destination))
    }

    /// Legacy name-based API. A name must match exactly one destination.
    func sendNoteOff(channel: UInt8, note: UInt8, toDeviceNamed name: String?) {
        guard validate(channel: channel) else { return }
        let statusByte: UInt8 = 0x80 | (channel - 1)
        sendMessage(bytes: [statusByte, note & 0x7F, 0], selector: selector(forLegacyName: name))
    }

    /// Sends a CC message. With no explicit destination, routing is only
    /// permitted when CoreMIDI exposes exactly one destination.
    func sendCC(
        channel: UInt8,
        controller: UInt8,
        value: UInt8,
        to destination: MIDIEndpointReference? = nil
    ) {
        guard validate(channel: channel) else { return }
        let statusByte: UInt8 = 0xB0 | (channel - 1)
        sendMessage(
            bytes: [statusByte, controller & 0x7F, value & 0x7F],
            selector: selector(for: destination)
        )
    }

    /// Legacy name-based API. A name must match exactly one destination.
    func sendCC(
        channel: UInt8,
        controller: UInt8,
        value: UInt8,
        toDeviceNamed name: String?
    ) {
        guard validate(channel: channel) else { return }
        let statusByte: UInt8 = 0xB0 | (channel - 1)
        sendMessage(
            bytes: [statusByte, controller & 0x7F, value & 0x7F],
            selector: selector(forLegacyName: name)
        )
    }

    /// Sends LED state using this precedence: the mapping's explicit feedback
    /// destination, the supplied global default, its legacy device name, then
    /// implicit routing (which is safe only with one destination).
    func sendLEDState(
        mapping: Mapping,
        on: Bool = true,
        defaultDestination: MIDIEndpointReference? = nil
    ) {
        guard let led = mapping.led, let note = mapping.trigger.note else { return }
        let selector = destinationSelector(for: mapping, defaultDestination: defaultDestination)
        let channel = mapping.trigger.channel
        guard validate(channel: channel) else { return }

        if on && led.color != .off {
            let statusByte: UInt8 = 0x90 | (channel - 1)
            sendMessage(bytes: [statusByte, note & 0x7F, led.velocity & 0x7F], selector: selector)
        } else {
            let statusByte: UInt8 = 0x80 | (channel - 1)
            sendMessage(bytes: [statusByte, note & 0x7F, 0], selector: selector)
        }
    }

    /// Sends CC feedback messages for a mapping.
    func sendFeedback(
        mapping: Mapping,
        defaultDestination: MIDIEndpointReference? = nil
    ) {
        guard let feedback = mapping.feedback else { return }
        let selector = destinationSelector(for: mapping, defaultDestination: defaultDestination)
        for message in feedback {
            guard validate(channel: message.channel) else { continue }
            let statusByte: UInt8 = 0xB0 | (message.channel - 1)
            sendMessage(
                bytes: [statusByte, message.controller & 0x7F, message.value & 0x7F],
                selector: selector
            )
        }
    }

    /// Sends LED states for all mappings in a profile.
    func sendAllLEDStates(
        profile: Profile,
        deviceFilter: String? = nil,
        defaultDestination: MIDIEndpointReference? = nil
    ) {
        for mapping in profile.mappings {
            if let filter = deviceFilter, let device = mapping.device,
               !device.localizedCaseInsensitiveContains(filter) {
                continue
            }
            sendLEDState(mapping: mapping, on: true, defaultDestination: defaultDestination)
        }
    }

    // MARK: - Destination resolution

    private func destinationSelector(
        for mapping: Mapping,
        defaultDestination: MIDIEndpointReference?
    ) -> DestinationSelector {
        if let destination = mapping.feedbackDestination {
            return .endpoint(destination)
        }
        if let defaultDestination {
            return .endpoint(defaultDestination)
        }
        if let legacyName = normalized(mapping.device) {
            return .legacyName(legacyName)
        }
        return .implicit
    }

    private func selector(for destination: MIDIEndpointReference?) -> DestinationSelector {
        destination.map(DestinationSelector.endpoint) ?? .implicit
    }

    private func selector(forLegacyName name: String?) -> DestinationSelector {
        normalized(name).map(DestinationSelector.legacyName) ?? .implicit
    }

    private func normalized(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Resolves a routing request against a topology snapshot without touching CoreMIDI.
    static func resolveDestination(
        for selector: DestinationSelector,
        among destinations: [MIDIEndpointReference]
    ) -> DestinationResolution {
        guard !destinations.isEmpty else {
            return .unavailable(.noDestinations)
        }

        switch selector {
        case .endpoint(let requested):
            let matches = destinations.indices.filter {
                destinations[$0].uniqueID == requested.uniqueID
            }
            if matches.count == 1 {
                return .resolved(index: matches[0])
            }
            if matches.isEmpty {
                return .unavailable(
                    .endpointNotConnected(name: requested.name, uniqueID: requested.uniqueID)
                )
            }
            return .unavailable(.endpointAmbiguous(uniqueID: requested.uniqueID))

        case .legacyName(let requestedName):
            let exactMatches = destinations.indices.filter {
                destinations[$0].name.compare(
                    requestedName,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
            if exactMatches.count == 1 {
                return .resolved(index: exactMatches[0])
            }
            if exactMatches.count > 1 {
                return .unavailable(.legacyNameAmbiguous(requestedName))
            }

            // V1 configs documented short names such as "iRig". Preserve that
            // behavior only when the case-insensitive partial match is unique.
            let partialMatches = destinations.indices.filter {
                destinations[$0].name.range(
                    of: requestedName,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
            if partialMatches.count == 1 {
                return .resolved(index: partialMatches[0])
            }
            if partialMatches.isEmpty {
                return .unavailable(.legacyNameNotConnected(requestedName))
            }
            return .unavailable(.legacyNameAmbiguous(requestedName))

        case .implicit:
            if destinations.count == 1 {
                return .resolved(index: 0)
            }
            return .unavailable(
                .implicitRequiresSelection(destinationCount: destinations.count)
            )
        }
    }

    /// Must only be called on `outputQueue`.
    private func findDestination(for selector: DestinationSelector) -> MIDIEndpointRef? {
        let destinations: [(endpoint: MIDIEndpointRef, reference: MIDIEndpointReference)] =
            (0..<MIDIGetNumberOfDestinations()).compactMap { index in
                let endpoint = MIDIGetDestination(index)
                guard endpoint != 0, let reference = MIDIEngine.endpointReference(endpoint) else {
                    return nil
                }
                return (endpoint, reference)
            }

        switch Self.resolveDestination(
            for: selector,
            among: destinations.map(\.reference)
        ) {
        case .resolved(let index):
            return destinations[index].endpoint
        case .unavailable(let failure):
            log(failure.logMessage)
            return nil
        }
    }

    // MARK: - Sending and lifecycle

    private func validate(channel: UInt8) -> Bool {
        guard (1...16).contains(Int(channel)) else {
            log("[MIDI Out] Invalid MIDI channel \(channel); expected 1...16")
            return false
        }
        return true
    }

    private func sendMessage(bytes: [UInt8], selector: DestinationSelector) {
        guard bytes.count <= 3 else { return }

        syncOnOutputQueue {
            guard outputPort != 0 else {
                log("[MIDI Out] Output port is not running")
                return
            }
            guard let destination = findDestination(for: selector) else { return }

            var word: UInt32 = 0x20000000  // MIDI 1.0 Channel Voice UMP
            if !bytes.isEmpty { word |= UInt32(bytes[0]) << 16 }
            if bytes.count > 1 { word |= UInt32(bytes[1]) << 8 }
            if bytes.count > 2 { word |= UInt32(bytes[2]) }

            var eventList = MIDIEventList()
            var packet = MIDIEventListInit(&eventList, ._1_0)
            packet = MIDIEventListAdd(
                &eventList,
                MemoryLayout<MIDIEventList>.size,
                packet,
                0,
                1,
                &word
            )

            let status = MIDISendEventList(outputPort, destination, &eventList)
            if status != noErr {
                log("[MIDI Out] Send failed: \(status)")
            }
        }
    }

    private func cleanupClientIfOwned() {
        if ownsClient, client != 0 {
            MIDIClientDispose(client)
        }
        ownsClient = false
    }

    private func syncOnOutputQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: outputQueueKey) != nil {
            operation()
        } else {
            outputQueue.sync(execute: operation)
        }
    }
}
