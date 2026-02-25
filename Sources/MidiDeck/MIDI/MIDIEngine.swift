import CoreMIDI
import Foundation

final class MIDIEngine: ObservableObject {
    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var connectedSources: Set<MIDIEndpointRef> = []

    @Published var connectedDeviceNames: [String] = []

    private var eventContinuation: AsyncStream<MIDIEvent>.Continuation?
    private(set) var eventStream: AsyncStream<MIDIEvent>!

    init() {
        let (stream, continuation) = AsyncStream<MIDIEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    func start() {
        let status = MIDIClientCreateWithBlock("MidiDeck" as CFString, &client) { [weak self] notification in
            self?.handleMIDINotification(notification)
        }
        guard status == noErr else {
            log("[MIDI] Failed to create client: \(status)")
            return
        }

        let portStatus = MIDIInputPortCreateWithProtocol(
            client,
            "MidiDeck Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, _ in
            self?.handleEventList(eventList)
        }
        guard portStatus == noErr else {
            log("[MIDI] Failed to create input port: \(portStatus)")
            return
        }

        connectAllSources()
        log("[MIDI] Engine started")
    }

    func stop() {
        for source in connectedSources {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources.removeAll()
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
            inputPort = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
        eventContinuation?.finish()
        log("[MIDI] Engine stopped")
    }

    // MARK: - Source Management

    private func connectAllSources() {
        let sourceCount = MIDIGetNumberOfSources()
        var newNames: [String] = []
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            if !connectedSources.contains(source) {
                let status = MIDIPortConnectSource(inputPort, source, nil)
                if status == noErr {
                    connectedSources.insert(source)
                    let name = Self.endpointName(source)
                    newNames.append(name)
                    log("[MIDI] Connected source: \(name)")
                }
            } else {
                newNames.append(Self.endpointName(source))
            }
        }
        DispatchQueue.main.async {
            self.connectedDeviceNames = newNames
        }
    }

    private func handleMIDINotification(_ notificationPtr: UnsafePointer<MIDINotification>) {
        let notification = notificationPtr.pointee
        switch notification.messageID {
        case .msgSetupChanged:
            log("[MIDI] Setup changed — reconnecting sources")
            // Remove stale sources
            let currentSources = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
            let stale = connectedSources.subtracting(currentSources)
            for source in stale {
                MIDIPortDisconnectSource(inputPort, source)
                connectedSources.remove(source)
            }
            connectAllSources()
        default:
            break
        }
    }

    // MARK: - Event Parsing

    private func handleEventList(_ eventListPtr: UnsafePointer<MIDIEventList>) {
        let eventList = eventListPtr.pointee
        // Walk through the event packets using the unsafe raw pointer approach
        withUnsafePointer(to: eventList.packet) { firstPacketPtr in
            var packetPtr = UnsafeMutablePointer(mutating: firstPacketPtr)
            for _ in 0..<eventList.numPackets {
                let p = packetPtr.pointee
                let wordCount = Int(p.wordCount)
                if wordCount > 0 {
                    let words = withUnsafePointer(to: p.words) { wordsPtr in
                        wordsPtr.withMemoryRebound(to: UInt32.self, capacity: wordCount) { ptr in
                            Array(UnsafeBufferPointer(start: ptr, count: wordCount))
                        }
                    }
                    let events = MIDIEvent.parse(words: words)
                    for event in events {
                        eventContinuation?.yield(event)
                    }
                }
                packetPtr = MIDIEventPacketNext(packetPtr)
            }
        }
    }

    // MARK: - Helpers

    static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        if status == noErr, let cfName = name?.takeRetainedValue() {
            return cfName as String
        }
        return "Unknown"
    }

    static func allSourceNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).map { endpointName(MIDIGetSource($0)) }
    }

    static func allDestinationNames() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).map { endpointName(MIDIGetDestination($0)) }
    }
}
