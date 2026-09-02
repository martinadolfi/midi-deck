import CoreMIDI
import Foundation

final class MIDIEngine: ObservableObject, @unchecked Sendable {
    private let topologyQueue = DispatchQueue(label: "com.midideck.midi.topology")
    private let topologyQueueKey = DispatchSpecificKey<Void>()
    private let eventQueue = DispatchQueue(label: "com.midideck.midi.events", qos: .userInteractive)
    private let sourceIdentityLock = NSLock()
    private let subscriberLock = NSLock()
    private let lastEventLock = NSLock()
    private let continuousEventLock = NSLock()

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var connectedSourceEndpoints: Set<MIDIEndpointRef> = []
    private var sourceIdentities: [MIDIEndpointRef: MIDIEndpointReference] = [:]
    private var eventContinuations: [UUID: AsyncStream<MIDIInputEvent>.Continuation] = [:]
    private var pendingLastEvent: MIDIInputEvent?
    private var lastEventUpdateScheduled = false
    private var pendingContinuousEvents: [ContinuousEventKey: PendingContinuousEvent] = [:]
    private var continuousEventSequence: UInt64 = 0
    private var continuousFlushID: UUID?

    private struct ContinuousEventKey: Hashable {
        let sourceID: Int32
        let channel: UInt8
        let controller: UInt8
    }

    private struct PendingContinuousEvent {
        let input: MIDIInputEvent
        let sequence: UInt64
    }

    /// Sources that are currently connected to the input port.
    @Published private(set) var connectedSources: [MIDIEndpointReference] = []

    /// Destinations currently advertised by CoreMIDI.
    @Published private(set) var connectedDestinations: [MIDIEndpointReference] = []

    /// The most recently received event, useful for status and diagnostics UI.
    @Published private(set) var lastEvent: MIDIInputEvent?

    /// A startup failure means connecting a controller cannot fix the issue;
    /// surface it separately from the ordinary no-controller state.
    @Published private(set) var initializationError: String?

    /// Compatibility view of `connectedSources` for the existing menu UI.
    var connectedDeviceNames: [String] {
        connectedSources.map(\.name)
    }

    init() {
        topologyQueue.setSpecific(key: topologyQueueKey, value: ())
    }

    deinit {
        stop()
        finishEventStreams()
    }

    /// Returns an independent event stream for each caller.
    ///
    /// A slow subscriber only retains its newest events and cannot consume events
    /// intended for another subscriber (for example, runtime dispatch and MIDI Learn).
    func events(bufferLimit: Int = 64) -> AsyncStream<MIDIInputEvent> {
        let id = UUID()
        let boundedLimit = max(1, bufferLimit)
        return AsyncStream(bufferingPolicy: .bufferingNewest(boundedLimit)) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            subscriberLock.lock()
            eventContinuations[id] = continuation
            subscriberLock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.removeEventContinuation(id: id)
            }
        }
    }

    func start() {
        syncOnTopologyQueue {
            guard client == 0, inputPort == 0 else { return }

            let status = MIDIClientCreateWithBlock("MidiDeck" as CFString, &client) { [weak self] notification in
                self?.handleMIDINotification(notification)
            }
            guard status == noErr else {
                client = 0
                let message = "CoreMIDI client could not start (error \(status))."
                publishInitializationError(message)
                log("[MIDI] \(message)")
                return
            }

            let portStatus = MIDIInputPortCreateWithProtocol(
                client,
                "MidiDeck Input" as CFString,
                ._1_0,
                &inputPort
            ) { [weak self] eventList, sourceConnectionRefCon in
                self?.handleEventList(eventList, sourceConnectionRefCon: sourceConnectionRefCon)
            }
            guard portStatus == noErr else {
                inputPort = 0
                MIDIClientDispose(client)
                client = 0
                let message = "CoreMIDI input could not start (error \(portStatus))."
                publishInitializationError(message)
                log("[MIDI] \(message)")
                return
            }

            publishInitializationError(nil)
            refreshTopology()
            log("[MIDI] Engine started")
        }
    }

    func stop() {
        syncOnTopologyQueue {
            guard client != 0 || inputPort != 0 else { return }

            if inputPort != 0 {
                for source in connectedSourceEndpoints {
                    MIDIPortDisconnectSource(inputPort, source)
                }
                connectedSourceEndpoints.removeAll()
                clearSourceIdentities()
                MIDIPortDispose(inputPort)
                inputPort = 0
            }
            if client != 0 {
                MIDIClientDispose(client)
                client = 0
            }

            clearPendingContinuousEvents()
            publishTopology(sources: [], destinations: [])
            log("[MIDI] Engine stopped")
        }
    }

    // MARK: - Source Management

    /// Must only be called on `topologyQueue`.
    private func refreshTopology() {
        guard client != 0, inputPort != 0 else { return }

        var currentSources: [MIDIEndpointRef: MIDIEndpointReference] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0, let reference = Self.endpointReference(endpoint) else {
                continue
            }
            currentSources[endpoint] = reference
        }

        let staleSources = connectedSourceEndpoints.subtracting(currentSources.keys)
        for source in staleSources {
            MIDIPortDisconnectSource(inputPort, source)
            connectedSourceEndpoints.remove(source)
        }

        replaceSourceIdentities(with: currentSources)

        for (source, reference) in currentSources where !connectedSourceEndpoints.contains(source) {
            // The endpoint itself is passed as srcConnRefCon so the read callback can
            // recover which source produced each event without allocating refcon state.
            let sourceRefCon = UnsafeMutableRawPointer(bitPattern: UInt(source))
            let status = MIDIPortConnectSource(inputPort, source, sourceRefCon)
            if status == noErr {
                connectedSourceEndpoints.insert(source)
                log("[MIDI] Connected source: \(reference.name) [\(reference.uniqueID)]")
            } else {
                log("[MIDI] Failed to connect source \(reference.name): \(status)")
            }
        }

        let sourceReferences = connectedSourceEndpoints.compactMap { currentSources[$0] }
        let destinationReferences = Self.allDestinations()
        publishTopology(
            sources: Self.sorted(sourceReferences),
            destinations: Self.sorted(destinationReferences)
        )
    }

    private func handleMIDINotification(_ notificationPtr: UnsafePointer<MIDINotification>) {
        let messageID = notificationPtr.pointee.messageID
        switch messageID {
        case .msgIOError:
            topologyQueue.async { [weak self] in
                guard let self, client != 0, inputPort != 0 else { return }
                log("[MIDI] I/O connection changed — reconnecting sources")
                disconnectAllSources()
                refreshTopology()
            }

        case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged,
             .msgThruConnectionsChanged, .msgSerialPortOwnerChanged:
            topologyQueue.async { [weak self] in
                guard let self, client != 0, inputPort != 0 else { return }
                log("[MIDI] Topology changed — refreshing endpoints")
                refreshTopology()
            }
        default:
            break
        }
    }

    /// Must only be called on `topologyQueue`.
    private func disconnectAllSources() {
        guard inputPort != 0 else { return }
        for source in connectedSourceEndpoints {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSourceEndpoints.removeAll()
    }

    // MARK: - Event Parsing

    private func handleEventList(
        _ eventListPtr: UnsafePointer<MIDIEventList>,
        sourceConnectionRefCon: UnsafeMutableRawPointer?
    ) {
        guard let sourceConnectionRefCon else { return }

        let sourceEndpoint = MIDIEndpointRef(UInt(bitPattern: sourceConnectionRefCon))
        guard let source = sourceIdentity(for: sourceEndpoint) else { return }

        // Both MIDIEventList and MIDIEventPacket are variable-length C structs.
        // Walk the callback's original memory instead of copying either `.pointee`,
        // which can truncate packets containing more than their imported fixed size.
        let eventListRaw = UnsafeRawPointer(eventListPtr)
        let packetCountOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.numPackets)!
        let firstPacketOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet)!
        let wordCountOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.wordCount)!
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        let packetCount = eventListRaw.load(fromByteOffset: packetCountOffset, as: UInt32.self)

        var packetPtr = UnsafeMutableRawPointer(mutating: eventListRaw)
            .advanced(by: firstPacketOffset)
            .assumingMemoryBound(to: MIDIEventPacket.self)
        var receivedWords: [UInt32] = []

        for _ in 0..<packetCount {
            let packetRaw = UnsafeRawPointer(packetPtr)
            let wordCount = Int(packetRaw.load(fromByteOffset: wordCountOffset, as: UInt32.self))
            if wordCount > 0 {
                let wordsPtr = packetRaw
                    .advanced(by: wordsOffset)
                    .assumingMemoryBound(to: UInt32.self)
                receivedWords.append(contentsOf: UnsafeBufferPointer(start: wordsPtr, count: wordCount))
            }
            packetPtr = MIDIEventPacketNext(packetPtr)
        }

        guard !receivedWords.isEmpty else { return }
        let words = receivedWords
        eventQueue.async { [weak self] in
            guard let self else { return }
            for event in MIDIEvent.parse(words: words) {
                publish(MIDIInputEvent(source: source, event: event))
            }
        }
    }

    // MARK: - Helpers

    static func endpointReference(_ endpoint: MIDIEndpointRef) -> MIDIEndpointReference? {
        var uniqueID: Int32 = 0
        let status = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
        guard status == noErr, uniqueID != 0 else {
            log("[MIDI] Endpoint has no stable unique ID: \(status)")
            return nil
        }
        return MIDIEndpointReference(uniqueID: uniqueID, name: endpointName(endpoint))
    }

    static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr,
           let cfName = name?.takeRetainedValue() {
            let displayName = cfName as String
            if !displayName.isEmpty { return displayName }
        }

        name = nil
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) == noErr,
           let cfName = name?.takeRetainedValue() {
            let endpointName = cfName as String
            if !endpointName.isEmpty { return endpointName }
        }
        return "Unknown"
    }

    static func allSources() -> [MIDIEndpointReference] {
        sorted((0..<MIDIGetNumberOfSources()).compactMap {
            endpointReference(MIDIGetSource($0))
        })
    }

    static func allDestinations() -> [MIDIEndpointReference] {
        sorted((0..<MIDIGetNumberOfDestinations()).compactMap {
            endpointReference(MIDIGetDestination($0))
        })
    }

    static func allSourceNames() -> [String] {
        allSources().map(\.name)
    }

    static func allDestinationNames() -> [String] {
        allDestinations().map(\.name)
    }

    private static func sorted(_ endpoints: [MIDIEndpointReference]) -> [MIDIEndpointReference] {
        endpoints.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.uniqueID < $1.uniqueID : comparison == .orderedAscending
        }
    }

    private func replaceSourceIdentities(with identities: [MIDIEndpointRef: MIDIEndpointReference]) {
        sourceIdentityLock.lock()
        sourceIdentities = identities
        sourceIdentityLock.unlock()
    }

    private func clearSourceIdentities() {
        sourceIdentityLock.lock()
        sourceIdentities.removeAll()
        sourceIdentityLock.unlock()
    }

    private func sourceIdentity(for endpoint: MIDIEndpointRef) -> MIDIEndpointReference? {
        sourceIdentityLock.lock()
        defer { sourceIdentityLock.unlock() }
        return sourceIdentities[endpoint]
    }

    private func publishTopology(
        sources: [MIDIEndpointReference],
        destinations: [MIDIEndpointReference]
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.connectedSources = sources
            self?.connectedDestinations = destinations
        }
    }

    private func publishInitializationError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.initializationError = message
        }
    }

    /// Publishes an already parsed event to every subscriber. Note events are
    /// delivered immediately. High-rate control changes are collapsed by
    /// source/channel/controller over a single display-frame-sized window, so
    /// downstream consumers can never spend seconds replaying stale fader data.
    /// Kept internal so delivery behavior can be verified without MIDI hardware.
    func publish(_ inputEvent: MIDIInputEvent) {
        scheduleLastEventUpdate(inputEvent)

        guard case .controlChange(let channel, let controller, _) = inputEvent.event else {
            yieldToSubscribers(inputEvent)
            return
        }

        let key = ContinuousEventKey(
            sourceID: inputEvent.source.uniqueID,
            channel: channel,
            controller: controller
        )

        continuousEventLock.lock()
        continuousEventSequence &+= 1
        pendingContinuousEvents[key] = PendingContinuousEvent(
            input: inputEvent,
            sequence: continuousEventSequence
        )

        guard continuousFlushID == nil else {
            continuousEventLock.unlock()
            return
        }

        let flushID = UUID()
        continuousFlushID = flushID
        continuousEventLock.unlock()

        eventQueue.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            self?.flushContinuousEvents(id: flushID)
        }
    }

    private func flushContinuousEvents(id: UUID) {
        continuousEventLock.lock()
        guard continuousFlushID == id else {
            continuousEventLock.unlock()
            return
        }
        let events = pendingContinuousEvents.values.sorted { $0.sequence < $1.sequence }
        pendingContinuousEvents.removeAll(keepingCapacity: true)
        continuousFlushID = nil
        continuousEventLock.unlock()

        for pending in events {
            yieldToSubscribers(pending.input)
        }
    }

    private func clearPendingContinuousEvents() {
        continuousEventLock.lock()
        pendingContinuousEvents.removeAll()
        continuousFlushID = nil
        continuousEventLock.unlock()
    }

    private func yieldToSubscribers(_ inputEvent: MIDIInputEvent) {
        subscriberLock.lock()
        let continuations = Array(eventContinuations.values)
        subscriberLock.unlock()

        for continuation in continuations {
            continuation.yield(inputEvent)
        }
    }

    private func removeEventContinuation(id: UUID) {
        subscriberLock.lock()
        eventContinuations.removeValue(forKey: id)
        subscriberLock.unlock()
    }

    private func finishEventStreams() {
        subscriberLock.lock()
        let continuations = Array(eventContinuations.values)
        eventContinuations.removeAll()
        subscriberLock.unlock()

        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Coalesces high-rate CC traffic so publishing diagnostic UI state cannot
    /// enqueue an unbounded number of main-queue updates.
    private func scheduleLastEventUpdate(_ inputEvent: MIDIInputEvent) {
        lastEventLock.lock()
        pendingLastEvent = inputEvent
        let shouldSchedule = !lastEventUpdateScheduled
        lastEventUpdateScheduled = true
        lastEventLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            lastEventLock.lock()
            let latestEvent = pendingLastEvent
            pendingLastEvent = nil
            lastEventUpdateScheduled = false
            lastEventLock.unlock()

            if let latestEvent {
                lastEvent = latestEvent
            }
        }
    }

    private func syncOnTopologyQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: topologyQueueKey) != nil {
            operation()
        } else {
            topologyQueue.sync(execute: operation)
        }
    }
}
