import Foundation

// MARK: - MIDI routing preferences

/// A stable CoreMIDI endpoint identity. Display names can change, so equality
/// and hashing intentionally use the system-provided unique ID only.
struct MIDIEndpointReference: Codable, Identifiable, Sendable {
    var uniqueID: Int32
    var name: String

    var id: Int32 { uniqueID }
}

extension MIDIEndpointReference: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.uniqueID == rhs.uniqueID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueID)
    }
}

enum MIDIInputMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Listen automatically when exactly one source is connected. With several
    /// sources, wait for the user to choose so controls cannot collide.
    case automatic
    /// Explicit opt-in to events from every connected source.
    case all
    /// Listen only to the persisted source identities below.
    case selected
}

/// Explains why an input event may enter the action pipeline. Explicit mapping
/// overrides carry the exact mapping identity that opted the source in.
enum MIDIInputRoute: Equatable, Sendable {
    case globalPolicy
    case mappingOverride(UUID)
}

struct MIDIConfiguration: Codable, Hashable, Sendable {
    var inputMode: MIDIInputMode = .automatic
    var inputSources: [MIDIEndpointReference] = []
    var feedbackDestination: MIDIEndpointReference?

    init(
        inputMode: MIDIInputMode = .automatic,
        inputSources: [MIDIEndpointReference] = [],
        feedbackDestination: MIDIEndpointReference? = nil
    ) {
        self.inputMode = inputMode
        self.inputSources = inputSources
        self.feedbackDestination = feedbackDestination
    }

    private enum CodingKeys: String, CodingKey {
        case inputMode, inputSources, feedbackDestination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputMode = try container.decodeIfPresent(MIDIInputMode.self, forKey: .inputMode) ?? .automatic
        inputSources = try container.decodeIfPresent([MIDIEndpointReference].self, forKey: .inputSources) ?? []
        feedbackDestination = try container.decodeIfPresent(MIDIEndpointReference.self, forKey: .feedbackDestination)
    }
}

// MARK: - Configuration schema

struct Configuration: Codable, Sendable {
    static let currentVersion = 2

    var version: Int = currentVersion
    var activeProfile: String = "default"
    var profiles: [String: Profile] = ["default": Profile()]
    var midi: MIDIConfiguration = MIDIConfiguration()

    init(
        version: Int = currentVersion,
        activeProfile: String = "default",
        profiles: [String: Profile] = ["default": Profile()],
        midi: MIDIConfiguration = MIDIConfiguration()
    ) {
        self.version = version
        self.activeProfile = activeProfile
        self.profiles = profiles
        self.midi = midi
    }

    private enum CodingKeys: String, CodingKey {
        case version, activeProfile, profiles, midi
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard storedVersion <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "This configuration uses version \(storedVersion), but this MidiDeck build supports up to version \(Self.currentVersion)."
            )
        }

        version = Self.currentVersion
        activeProfile = try container.decode(String.self, forKey: .activeProfile)
        profiles = try container.decode([String: Profile].self, forKey: .profiles)
        midi = try container.decodeIfPresent(MIDIConfiguration.self, forKey: .midi) ?? MIDIConfiguration()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(activeProfile, forKey: .activeProfile)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(midi, forKey: .midi)
    }
}

struct Profile: Codable, Sendable {
    var mappings: [Mapping] = []

    init(mappings: [Mapping] = []) {
        self.mappings = mappings
    }

    private enum CodingKeys: String, CodingKey { case mappings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mappings = try container.decode([Mapping].self, forKey: .mappings)
    }
}

struct Mapping: Codable, Identifiable, Sendable {
    var id: UUID
    var description: String
    /// Legacy v1 name used for both source filtering and feedback output.
    var device: String?
    /// Stable v2 input source override. `nil` follows the global input policy.
    var source: MIDIEndpointReference?
    /// Stable v2 feedback output override. `nil` follows the global destination.
    var feedbackDestination: MIDIEndpointReference?
    var trigger: Trigger
    var action: Action
    var led: LEDConfig?
    var feedback: [MIDIFeedback]?

    init(
        id: UUID = UUID(),
        description: String = "",
        device: String? = nil,
        source: MIDIEndpointReference? = nil,
        feedbackDestination: MIDIEndpointReference? = nil,
        trigger: Trigger,
        action: Action,
        led: LEDConfig? = nil,
        feedback: [MIDIFeedback]? = nil
    ) {
        self.id = id
        self.description = description
        self.device = device
        self.source = source
        self.feedbackDestination = feedbackDestination
        self.trigger = trigger
        self.action = action
        self.led = led
        self.feedback = feedback
    }

    private enum CodingKeys: String, CodingKey {
        case id, description, device, source, feedbackDestination, trigger, action, led, feedback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        device = try container.decodeIfPresent(String.self, forKey: .device)
        source = try container.decodeIfPresent(MIDIEndpointReference.self, forKey: .source)
        feedbackDestination = try container.decodeIfPresent(MIDIEndpointReference.self, forKey: .feedbackDestination)
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        action = try container.decode(Action.self, forKey: .action)
        led = try container.decodeIfPresent(LEDConfig.self, forKey: .led)
        feedback = try container.decodeIfPresent([MIDIFeedback].self, forKey: .feedback)
    }
}

struct Trigger: Codable, Hashable, Sendable {
    var type: TriggerType
    var channel: UInt8
    var note: UInt8?
    var controller: UInt8?

    enum TriggerType: String, Codable, CaseIterable, Sendable {
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

struct Action: Codable, Sendable {
    var type: ActionType
    var bundleId: String?
    var device: String?
    var inputDevice: String?
    var profile: String?
    var muted: Bool?
    var notify: String?

    enum ActionType: String, Codable, CaseIterable, Sendable {
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
struct MIDIFeedback: Codable, Sendable {
    var channel: UInt8
    var controller: UInt8
    var value: UInt8
}

struct LEDConfig: Codable, Sendable {
    var color: LEDColor
    var behavior: LEDBehavior

    enum LEDColor: String, Codable, CaseIterable, Sendable {
        case off
        case red
        case green
        case yellow
        case blue
        case magenta
        case cyan
        case white
    }

    enum LEDBehavior: String, Codable, CaseIterable, Sendable {
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

// MARK: - Trigger matching

extension Trigger {
    func matches(_ event: MIDIEvent) -> Bool {
        switch (type, event) {
        case (.noteOn, .noteOn(let channel, let note, _)):
            return channel == self.channel && note == (self.note ?? 0)
        case (.noteOff, .noteOff(let channel, let note, _)):
            return channel == self.channel && note == (self.note ?? 0)
        case (.controlChange, .controlChange(let channel, let controller, _)):
            return channel == self.channel && controller == (self.controller ?? 0)
        default:
            return false
        }
    }
}

extension Mapping {
    var hasMIDIInputSourceOverride: Bool {
        if source != nil { return true }
        return !(device?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Applies a stable v2 source override or the documented version-1 device
    /// name filter. Legacy partial names are accepted only when they identify one
    /// connected source, preventing similarly named controllers from colliding.
    func acceptsMIDIInput(
        from source: MIDIEndpointReference,
        among connectedSources: [MIDIEndpointReference]
    ) -> Bool {
        inputMatchSpecificity(from: source, among: connectedSources) != nil
    }

    fileprivate func inputMatchSpecificity(
        from source: MIDIEndpointReference,
        among connectedSources: [MIDIEndpointReference]
    ) -> MIDIInputMatchSpecificity? {
        if let configuredSource = self.source {
            return configuredSource.uniqueID == source.uniqueID ? .stableSource : nil
        }

        guard let legacyName = device?.trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyName.isEmpty else {
            return .unscoped
        }

        let candidates = connectedSources.isEmpty ? [source] : connectedSources
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let exact = candidates.filter { $0.name.compare(legacyName, options: options) == .orderedSame }
        if !exact.isEmpty {
            return exact.count == 1 && exact[0].uniqueID == source.uniqueID ? .legacyExact : nil
        }

        let partial = candidates.filter { $0.name.range(of: legacyName, options: options) != nil }
        return partial.count == 1 && partial[0].uniqueID == source.uniqueID ? .legacyPartial : nil
    }
}

private enum MIDIInputMatchSpecificity: Int, Comparable {
    case unscoped
    case legacyPartial
    case legacyExact
    case stableSource

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension Profile {
    /// Returns the most specific mapping for an input event. A mapping scoped to
    /// the source always wins over an otherwise matching unscoped mapping, even
    /// when the unscoped mapping appears first in the configuration.
    func matchingMapping(
        for input: MIDIInputEvent,
        among connectedSources: [MIDIEndpointReference]
    ) -> Mapping? {
        bestMatchingMapping(for: input, among: connectedSources, sourceOverridesOnly: false)
    }

    fileprivate func matchingSourceOverride(
        for input: MIDIInputEvent,
        among connectedSources: [MIDIEndpointReference]
    ) -> Mapping? {
        bestMatchingMapping(for: input, among: connectedSources, sourceOverridesOnly: true)
    }

    private func bestMatchingMapping(
        for input: MIDIInputEvent,
        among connectedSources: [MIDIEndpointReference],
        sourceOverridesOnly: Bool
    ) -> Mapping? {
        var bestMatch: (mapping: Mapping, specificity: MIDIInputMatchSpecificity)?

        for mapping in mappings where mapping.trigger.matches(input.event) {
            if sourceOverridesOnly, !mapping.hasMIDIInputSourceOverride {
                continue
            }
            guard let specificity = mapping.inputMatchSpecificity(
                from: input.source,
                among: connectedSources
            ) else {
                continue
            }

            if let current = bestMatch {
                if specificity > current.specificity {
                    bestMatch = (mapping, specificity)
                }
            } else {
                bestMatch = (mapping, specificity)
            }
        }

        return bestMatch?.mapping
    }
}

extension Configuration {
    /// Applies source-scoped mapping overrides before the global input policy.
    /// The override is event-specific, so one scoped button cannot accidentally
    /// opt unrelated unscoped controls on that controller into the pipeline.
    func inputRoute(
        for input: MIDIInputEvent,
        among connectedSources: [MIDIEndpointReference]
    ) -> MIDIInputRoute? {
        guard let profile = profiles[activeProfile] else { return nil }

        if let mapping = profile.matchingSourceOverride(for: input, among: connectedSources) {
            return .mappingOverride(mapping.id)
        }

        switch midi.inputMode {
        case .automatic:
            let connectedIDs = Set(connectedSources.map(\.uniqueID))
            guard connectedIDs.count == 1, connectedIDs.contains(input.source.uniqueID) else {
                return nil
            }
        case .all:
            break
        case .selected:
            guard midi.inputSources.count == 1,
                  midi.inputSources[0].uniqueID == input.source.uniqueID else {
                return nil
            }
        }

        return .globalPolicy
    }
}

// MARK: - Semantic validation

struct ConfigurationIssue: Identifiable, Hashable, Sendable {
    enum Severity: String, Sendable {
        case warning
        case error
    }

    let severity: Severity
    let message: String
    let location: String?

    var id: String { "\(severity.rawValue):\(location ?? ""):\(message)" }
}

enum ConfigurationValidator {
    static func issues(in configuration: Configuration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []

        if configuration.profiles.isEmpty {
            issues.append(.error("At least one profile is required."))
        }
        if configuration.profiles[configuration.activeProfile] == nil {
            issues.append(.error("The active profile '\(configuration.activeProfile)' does not exist."))
        }

        if configuration.midi.inputMode == .selected,
           configuration.midi.inputSources.count != 1 {
            issues.append(.error("Selected-input mode needs exactly one MIDI source.", at: "MIDI"))
        }

        let selectedIDs = configuration.midi.inputSources.map(\.uniqueID)
        if selectedIDs.contains(0) {
            issues.append(.error("A selected MIDI source has an invalid ID.", at: "MIDI"))
        }
        if Set(selectedIDs).count != selectedIDs.count {
            issues.append(.error("The selected MIDI source list contains duplicates.", at: "MIDI"))
        }
        if configuration.midi.feedbackDestination?.uniqueID == 0 {
            issues.append(.error("The feedback destination has an invalid ID.", at: "MIDI"))
        }

        var mappingIDs = Set<UUID>()
        for profileName in configuration.profiles.keys.sorted() {
            guard let profile = configuration.profiles[profileName] else { continue }
            if profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.error("Profile names cannot be empty."))
            }

            var triggerKeys = Set<String>()
            for mapping in profile.mappings {
                let location = "\(profileName) / \(mapping.description.isEmpty ? mapping.id.uuidString : mapping.description)"

                if !mappingIDs.insert(mapping.id).inserted {
                    issues.append(.error("Mapping IDs must be unique.", at: location))
                }
                issues.append(contentsOf: mappingIssues(mapping, configuration: configuration, location: location))

                let sourceKey: String
                if let source = mapping.source {
                    sourceKey = "id:\(source.uniqueID)"
                } else if let legacy = nonEmpty(mapping.device) {
                    sourceKey = "legacy:\(legacy.lowercased())"
                } else {
                    sourceKey = "global"
                }
                let triggerKey = "\(sourceKey):\(mapping.trigger.matchKey)"
                if !triggerKeys.insert(triggerKey).inserted {
                    issues.append(.error("Another mapping in this profile uses the same source and trigger.", at: location))
                }
            }
        }
        return issues
    }

    static func mappingIssues(
        _ mapping: Mapping,
        configuration: Configuration,
        location: String? = nil
    ) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        let trigger = mapping.trigger

        if !(1...16).contains(Int(trigger.channel)) {
            issues.append(.error("MIDI channel must be between 1 and 16.", at: location))
        }
        switch trigger.type {
        case .noteOn, .noteOff:
            guard let note = trigger.note, note <= 127 else {
                issues.append(.error("Note must be between 0 and 127.", at: location))
                break
            }
        case .controlChange:
            guard let controller = trigger.controller, controller <= 127 else {
                issues.append(.error("Controller number must be between 0 and 127.", at: location))
                break
            }
        }

        if !mapping.action.type.isCompatible(with: trigger.type) {
            issues.append(.error("\(mapping.action.type.rawValue) is not compatible with a \(trigger.type.rawValue) trigger.", at: location))
        }

        switch mapping.action.type {
        case .openApp where nonEmpty(mapping.action.bundleId) == nil:
            issues.append(.error("Choose an application.", at: location))
        case .setAudioOutput, .setAudioInput:
            if nonEmpty(mapping.action.device) == nil {
                issues.append(.error("Choose an audio device.", at: location))
            }
        case .switchAudioDevice where nonEmpty(mapping.action.device) == nil && nonEmpty(mapping.action.inputDevice) == nil:
            issues.append(.error("Choose at least one audio device.", at: location))
        case .switchProfile:
            if let target = nonEmpty(mapping.action.profile) {
                if configuration.profiles[target] == nil {
                    issues.append(.error("The target profile '\(target)' does not exist.", at: location))
                }
            } else {
                issues.append(.error("Choose a target profile.", at: location))
            }
        default:
            break
        }

        if mapping.source?.uniqueID == 0 {
            issues.append(.error("The mapping source has an invalid MIDI ID.", at: location))
        }
        if mapping.feedbackDestination?.uniqueID == 0 {
            issues.append(.error("The mapping feedback destination has an invalid MIDI ID.", at: location))
        }
        if mapping.source != nil, nonEmpty(mapping.device) != nil {
            issues.append(.warning("This mapping still has a legacy device name; the stable source selection takes precedence.", at: location))
        }

        if mapping.led != nil, trigger.type == .controlChange {
            issues.append(.error("LED feedback requires a note press or release trigger.", at: location))
        }
        if mapping.led?.behavior == .toggleOnMute,
           mapping.action.type != .toggleMicMute,
           mapping.action.type != .setMicMute {
            issues.append(.error("Follow-mute LED behavior requires a microphone mute action.", at: location))
        }
        if mapping.feedback?.isEmpty == false, trigger.type == .controlChange {
            issues.append(.error("Configured CC feedback requires a note press or release trigger.", at: location))
        }

        for message in mapping.feedback ?? [] {
            if !(1...16).contains(Int(message.channel)) {
                issues.append(.error("Feedback channel must be between 1 and 16.", at: location))
            }
            if message.controller > 127 || message.value > 127 {
                issues.append(.error("Feedback controller and value must be between 0 and 127.", at: location))
            }
        }
        return issues
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private extension ConfigurationIssue {
    static func error(_ message: String, at location: String? = nil) -> Self {
        Self(severity: .error, message: message, location: location)
    }

    static func warning(_ message: String, at location: String? = nil) -> Self {
        Self(severity: .warning, message: message, location: location)
    }
}

extension Action.ActionType {
    func isCompatible(with triggerType: Trigger.TriggerType) -> Bool {
        switch triggerType {
        case .controlChange:
            return self == .setVolume || self == .setInputVolume
        case .noteOn, .noteOff:
            return self != .setVolume && self != .setInputVolume
        }
    }
}
