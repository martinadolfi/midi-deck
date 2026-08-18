import Foundation
import XCTest
@testable import MidiDeck

final class ConfigurationTests: XCTestCase {
    func testVersionOneConfigurationMigratesInMemoryWithoutLosingMapping() throws {
        let json = """
        {
          "version": 1,
          "activeProfile": "default",
          "profiles": {
            "default": {
              "mappings": [{
                "id": "A0000001-0000-0000-0000-000000000001",
                "description": "Open Safari",
                "device": "Controller",
                "trigger": { "type": "noteOn", "channel": 10, "note": 36 },
                "action": { "type": "openApp", "bundleId": "com.apple.Safari" },
                "led": { "color": "blue", "behavior": "solid" }
              }]
            }
          }
        }
        """

        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.version, Configuration.currentVersion)
        XCTAssertEqual(configuration.midi.inputMode, .automatic)
        XCTAssertTrue(configuration.midi.inputSources.isEmpty)
        XCTAssertEqual(configuration.activeProfile, "default")
        XCTAssertEqual(configuration.profiles["default"]?.mappings.count, 1)
        XCTAssertEqual(configuration.profiles["default"]?.mappings.first?.device, "Controller")
        XCTAssertNil(configuration.profiles["default"]?.mappings.first?.source)
    }

    func testTrackedExampleStillDecodesAndValidates() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("config.example.json"))
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)

        XCTAssertTrue(ConfigurationValidator.issues(in: configuration).filter { $0.severity == .error }.isEmpty)
        XCTAssertEqual(configuration.profiles["default"]?.mappings.count, 9)
    }

    func testPartialVersionTwoMIDISettingsUseSafeDefaults() throws {
        let json = """
        {
          "version": 2,
          "activeProfile": "default",
          "profiles": { "default": { "mappings": [] } },
          "midi": { "inputMode": "all" }
        }
        """

        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.midi.inputMode, .all)
        XCTAssertTrue(configuration.midi.inputSources.isEmpty)
        XCTAssertNil(configuration.midi.feedbackDestination)
        XCTAssertTrue(configuration.profiles["default"]?.mappings.isEmpty == true)
    }

    func testMissingVersionStillMigratesAsVersionOne() throws {
        let json = """
        {
          "activeProfile": "default",
          "profiles": { "default": { "mappings": [] } }
        }
        """

        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.version, Configuration.currentVersion)
        XCTAssertEqual(configuration.activeProfile, "default")
        XCTAssertTrue(configuration.profiles["default"]?.mappings.isEmpty == true)
        XCTAssertEqual(configuration.midi.inputMode, .automatic)
    }

    func testMissingCoreConfigurationDataIsRejected() {
        let documents = [
            #"{ "version": 2, "profiles": { "default": { "mappings": [] } } }"#,
            #"{ "version": 2, "activeProfile": "default" }"#,
            #"{ "version": 2, "activeProfile": "default", "profiles": { "default": {} } }"#,
        ]

        for document in documents {
            XCTAssertThrowsError(
                try JSONDecoder().decode(Configuration.self, from: Data(document.utf8)),
                "Expected core configuration data to be required in \(document)"
            )
        }
    }

    func testSelectedModeRequiresExactlyOneSource() {
        let first = MIDIEndpointReference(uniqueID: 1, name: "First")
        let second = MIDIEndpointReference(uniqueID: 2, name: "Second")

        for sources in [[], [first, second]] {
            let configuration = Configuration(
                profiles: ["default": Profile()],
                midi: MIDIConfiguration(inputMode: .selected, inputSources: sources)
            )

            XCTAssertTrue(ConfigurationValidator.issues(in: configuration).contains {
                $0.message.contains("exactly one MIDI source")
            })
        }

        let valid = Configuration(
            profiles: ["default": Profile()],
            midi: MIDIConfiguration(inputMode: .selected, inputSources: [first])
        )
        XCTAssertFalse(ConfigurationValidator.issues(in: valid).contains {
            $0.message.contains("exactly one MIDI source")
        })
    }

    func testFutureSchemaIsRejected() {
        let json = """
        { "version": 99, "activeProfile": "default", "profiles": { "default": {} } }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(Configuration.self, from: Data(json.utf8)))
    }

    func testEndpointIdentityUsesUniqueIDRatherThanDisplayName() {
        let oldName = MIDIEndpointReference(uniqueID: 42, name: "Old Name")
        let newName = MIDIEndpointReference(uniqueID: 42, name: "New Name")

        XCTAssertEqual(oldName, newName)
        XCTAssertEqual(Set([oldName, newName]).count, 1)
    }

    func testLegacySourceNameMatchesOnlyOneConnectedController() {
        let mapping = Mapping(
            device: "Launchpad",
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "com.apple.Safari")
        )
        let mini = MIDIEndpointReference(uniqueID: 1, name: "Launchpad Mini")
        let pro = MIDIEndpointReference(uniqueID: 2, name: "Launchpad Pro")

        XCTAssertTrue(mapping.acceptsMIDIInput(from: mini, among: [mini]))
        XCTAssertFalse(mapping.acceptsMIDIInput(from: mini, among: [mini, pro]))
        XCTAssertFalse(mapping.acceptsMIDIInput(from: pro, among: [mini, pro]))
    }

    func testSourceScopedMappingWinsOverUnscopedMappingRegardlessOfOrder() {
        let source = MIDIEndpointReference(uniqueID: 7, name: "Controller")
        let input = MIDIInputEvent(
            source: source,
            event: .noteOn(channel: 1, note: 36, velocity: 127)
        )
        let unscoped = Mapping(
            description: "Fallback",
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "fallback")
        )
        let scoped = Mapping(
            description: "Controller-specific",
            source: source,
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "specific")
        )

        XCTAssertEqual(
            Profile(mappings: [unscoped, scoped]).matchingMapping(for: input, among: [source])?.id,
            scoped.id
        )
        XCTAssertEqual(
            Profile(mappings: [scoped, unscoped]).matchingMapping(for: input, among: [source])?.id,
            scoped.id
        )
    }

    func testUniqueLegacySourceMappingWinsOverUnscopedFallback() {
        let source = MIDIEndpointReference(uniqueID: 7, name: "Launchpad Mini")
        let input = MIDIInputEvent(
            source: source,
            event: .noteOn(channel: 1, note: 36, velocity: 127)
        )
        let unscoped = Mapping(
            description: "Fallback",
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "fallback")
        )
        let legacy = Mapping(
            description: "Legacy-specific",
            device: "Launchpad",
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "legacy")
        )

        XCTAssertEqual(
            Profile(mappings: [unscoped, legacy]).matchingMapping(for: input, among: [source])?.id,
            legacy.id
        )
    }

    func testAmbiguousLegacySourceFallsBackToUnscopedMapping() {
        let mini = MIDIEndpointReference(uniqueID: 1, name: "Launchpad Mini")
        let pro = MIDIEndpointReference(uniqueID: 2, name: "Launchpad Pro")
        let input = MIDIInputEvent(
            source: mini,
            event: .noteOn(channel: 1, note: 36, velocity: 127)
        )
        let ambiguous = Mapping(
            description: "Ambiguous legacy mapping",
            device: "Launchpad",
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "ambiguous")
        )
        let unscoped = Mapping(
            description: "Fallback",
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "fallback")
        )

        XCTAssertEqual(
            Profile(mappings: [ambiguous, unscoped]).matchingMapping(for: input, among: [mini, pro])?.id,
            unscoped.id
        )
    }

    func testEventSpecificMappingOverrideBypassesBlockedGlobalPolicy() {
        let first = MIDIEndpointReference(uniqueID: 1, name: "First")
        let second = MIDIEndpointReference(uniqueID: 2, name: "Second")
        let mapping = Mapping(
            source: second,
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "specific")
        )
        let configuration = Configuration(
            profiles: ["default": Profile(mappings: [mapping])],
            midi: MIDIConfiguration(inputMode: .automatic)
        )
        let mappedInput = MIDIInputEvent(
            source: second,
            event: .noteOn(channel: 1, note: 36, velocity: 127)
        )
        let unrelatedInput = MIDIInputEvent(
            source: second,
            event: .noteOn(channel: 1, note: 37, velocity: 127)
        )

        XCTAssertEqual(
            configuration.inputRoute(for: mappedInput, among: [first, second]),
            .mappingOverride(mapping.id)
        )
        XCTAssertNil(configuration.inputRoute(for: unrelatedInput, among: [first, second]))
    }

    func testAmbiguousLegacyOverrideCannotBypassBlockedGlobalPolicy() {
        let mini = MIDIEndpointReference(uniqueID: 1, name: "Launchpad Mini")
        let pro = MIDIEndpointReference(uniqueID: 2, name: "Launchpad Pro")
        let mapping = Mapping(
            device: "Launchpad",
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "ambiguous")
        )
        let configuration = Configuration(
            profiles: ["default": Profile(mappings: [mapping])],
            midi: MIDIConfiguration(inputMode: .automatic)
        )
        let input = MIDIInputEvent(
            source: mini,
            event: .noteOn(channel: 1, note: 36, velocity: 127)
        )

        XCTAssertNil(configuration.inputRoute(for: input, among: [mini, pro]))
    }

    func testGlobalPolicyRouteAllowsUnscopedMappingsWithOneAutomaticSource() {
        let source = MIDIEndpointReference(uniqueID: 1, name: "Controller")
        let configuration = Configuration(
            profiles: ["default": Profile()],
            midi: MIDIConfiguration(inputMode: .automatic)
        )
        let input = MIDIInputEvent(
            source: source,
            event: .noteOn(channel: 1, note: 36, velocity: 127)
        )

        XCTAssertEqual(configuration.inputRoute(for: input, among: [source]), .globalPolicy)
    }

    func testValidatorRejectsUnsafeTriggerAndActionCombinations() {
        let mapping = Mapping(
            description: "Bad mapping",
            trigger: Trigger(type: .controlChange, channel: 0, controller: 200),
            action: Action(type: .openApp, bundleId: "com.apple.Safari")
        )
        let configuration = Configuration(profiles: ["default": Profile(mappings: [mapping])])

        let messages = ConfigurationValidator.issues(in: configuration).map(\.message)

        XCTAssertTrue(messages.contains { $0.contains("channel") })
        XCTAssertTrue(messages.contains { $0.contains("Controller number") })
        XCTAssertTrue(messages.contains { $0.contains("not compatible") })
    }

    func testValidatorRejectsFeedbackThatRuntimeCannotApply() {
        let continuous = Mapping(
            trigger: Trigger(type: .controlChange, channel: 1, controller: 20),
            action: Action(type: .setVolume, device: "default"),
            led: LEDConfig(color: .blue, behavior: .solid),
            feedback: [MIDIFeedback(channel: 1, controller: 21, value: 127)]
        )
        let unrelatedMuteFollower = Mapping(
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "com.apple.Safari"),
            led: LEDConfig(color: .red, behavior: .toggleOnMute)
        )
        let configuration = Configuration(
            profiles: ["default": Profile(mappings: [continuous, unrelatedMuteFollower])]
        )

        let messages = ConfigurationValidator.issues(in: configuration).map(\.message)

        XCTAssertTrue(messages.contains { $0.contains("LED feedback requires") })
        XCTAssertTrue(messages.contains { $0.contains("Configured CC feedback requires") })
        XCTAssertTrue(messages.contains { $0.contains("requires a microphone mute action") })
    }

    func testValidatorDetectsSameSourceTriggerCollision() {
        let source = MIDIEndpointReference(uniqueID: 7, name: "Controller")
        let first = Mapping(
            source: source,
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .openApp, bundleId: "com.apple.Safari")
        )
        let second = Mapping(
            source: source,
            trigger: Trigger(type: .noteOn, channel: 1, note: 36),
            action: Action(type: .toggleMicMute, device: "default")
        )
        let configuration = Configuration(profiles: ["default": Profile(mappings: [first, second])])

        XCTAssertTrue(ConfigurationValidator.issues(in: configuration).contains {
            $0.message.contains("same source and trigger")
        })
    }
}
