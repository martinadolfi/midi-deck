import Foundation
import XCTest
@testable import MidiDeck

@MainActor
final class ConfigManagerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MidiDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testInputRoutingFailsClosedWithSeveralAutomaticSources() {
        let manager = makeManager()
        let first = MIDIEndpointReference(uniqueID: 1, name: "First")
        let second = MIDIEndpointReference(uniqueID: 2, name: "Second")

        XCTAssertTrue(manager.shouldRespond(to: first, connectedSources: [first]))
        XCTAssertFalse(manager.shouldRespond(to: first, connectedSources: [first, second]))
        XCTAssertFalse(manager.shouldRespond(to: second, connectedSources: [first, second]))

        XCTAssertTrue(manager.selectExclusiveInput(second))
        XCTAssertFalse(manager.shouldRespond(to: first, connectedSources: [first, second]))
        XCTAssertTrue(manager.shouldRespond(to: second, connectedSources: [first, second]))

        XCTAssertTrue(manager.setMIDIInputMode(.all))
        XCTAssertTrue(manager.shouldRespond(to: first, connectedSources: [first, second]))
        XCTAssertTrue(manager.shouldRespond(to: second, connectedSources: [first, second]))
    }

    func testMutationsPersistAndReload() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let manager = makeManager(url: url)

        XCTAssertTrue(manager.addProfile(named: "Streaming"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reloaded = makeManager(url: url)
        XCTAssertTrue(reloaded.load())
        XCTAssertNotNil(reloaded.config.profiles["Streaming"])
        XCTAssertEqual(reloaded.config.version, Configuration.currentVersion)
    }

    func testStructuralChangeCreatesRestorableBackup() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let initial = Configuration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(initial).write(to: url, options: .atomic)

        let manager = makeManager(url: url)
        XCTAssertTrue(manager.load())
        XCTAssertTrue(manager.addProfile(named: "Temporary"))
        XCTAssertNotNil(manager.lastBackupURL)
        XCTAssertNotNil(manager.config.profiles["Temporary"])

        XCTAssertTrue(manager.restoreLastBackup())
        XCTAssertNil(manager.config.profiles["Temporary"])
        XCTAssertNotNil(manager.config.profiles["default"])
    }

    func testSecondRestoreUndoesFirstRestore() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        try JSONEncoder().encode(Configuration()).write(to: url, options: .atomic)

        let manager = makeManager(url: url)
        XCTAssertTrue(manager.load())
        XCTAssertTrue(manager.addProfile(named: "Temporary"))
        XCTAssertNotNil(manager.config.profiles["Temporary"])

        XCTAssertTrue(manager.restoreLastBackup())
        XCTAssertNil(manager.config.profiles["Temporary"])

        XCTAssertTrue(manager.restoreLastBackup())
        XCTAssertNotNil(manager.config.profiles["Temporary"])
    }

    func testMalformedReloadKeepsLastKnownGoodConfiguration() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let manager = makeManager(url: url)
        XCTAssertTrue(manager.addProfile(named: "Good"))

        try Data("{ not valid json".utf8).write(to: url, options: .atomic)

        XCTAssertFalse(manager.load())
        XCTAssertNotNil(manager.config.profiles["Good"])
        XCTAssertTrue(manager.isUsingLastKnownGood)
        XCTAssertNotNil(manager.configError)
    }

    func testStructurallyIncompleteReloadKeepsLastKnownGoodConfiguration() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let manager = makeManager(url: url)
        XCTAssertTrue(manager.addProfile(named: "Good"))

        let incompleteData = Data(
            #"{ "version": 2, "activeProfile": "default", "profiles": { "default": {} } }"#.utf8
        )
        try incompleteData.write(to: url, options: .atomic)

        XCTAssertFalse(manager.load())
        XCTAssertNotNil(manager.config.profiles["Good"])
        XCTAssertTrue(manager.isUsingLastKnownGood)
        XCTAssertTrue(manager.configError?.contains("mappings") == true)
    }

    func testMissingReloadKeepsLastKnownGoodConfiguration() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let manager = makeManager(url: url)
        XCTAssertTrue(manager.addProfile(named: "Good"))
        try FileManager.default.removeItem(at: url)

        XCTAssertFalse(manager.load())
        XCTAssertNotNil(manager.config.profiles["Good"])
        XCTAssertTrue(manager.isUsingLastKnownGood)
        XCTAssertTrue(manager.configError?.contains("missing") == true)
    }

    func testMalformedDiskFileRotatesBackupToMostRecentValidatedBytes() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        try JSONEncoder().encode(Configuration()).write(to: url, options: .atomic)
        let manager = makeManager(url: url)
        XCTAssertTrue(manager.load())
        XCTAssertTrue(manager.addProfile(named: "First Change"))
        _ = try XCTUnwrap(manager.lastBackupURL)
        let lastGoodData = try Data(contentsOf: url)

        try Data("{ broken".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(manager.load())
        XCTAssertTrue(manager.addProfile(named: "Second Change"))

        let rotatedBackup = try Data(contentsOf: try XCTUnwrap(manager.lastBackupURL))
        XCTAssertEqual(rotatedBackup, lastGoodData)
        let decodedBackup = try JSONDecoder().decode(Configuration.self, from: rotatedBackup)
        XCTAssertNotNil(decodedBackup.profiles["First Change"])
        XCTAssertNil(decodedBackup.profiles["Second Change"])
    }

    func testMutationAfterMalformedDiskCreatesBackupFromLastValidatedBytes() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let original = Configuration(
            profiles: ["default": Profile(), "Original": Profile()]
        )
        let originalData = try JSONEncoder().encode(original)
        try originalData.write(to: url, options: .atomic)

        let manager = makeManager(url: url)
        XCTAssertTrue(manager.load())
        XCTAssertNil(manager.lastBackupURL)

        try Data("{ malformed".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(manager.load())
        XCTAssertTrue(manager.switchProfile("Original"))

        let backupData = try Data(contentsOf: try XCTUnwrap(manager.lastBackupURL))
        XCTAssertEqual(backupData, originalData)
        let backup = try JSONDecoder().decode(Configuration.self, from: backupData)
        XCTAssertEqual(backup.activeProfile, "default")
        XCTAssertNotNil(backup.profiles["Original"])
    }

    func testWatcherReloadsLastLoadedBytesToClearLastKnownGoodError() async throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let originalData = try JSONEncoder().encode(Configuration())
        try originalData.write(to: url, options: .atomic)
        let manager = ConfigManager(
            configurationURL: url,
            alternativeURLs: [],
            watchesFile: true
        )
        XCTAssertTrue(manager.load())

        try Data("{ malformed".utf8).write(to: url, options: .atomic)
        let detectedMalformedFile = await waitUntil {
            manager.isUsingLastKnownGood && manager.configError != nil
        }
        XCTAssertTrue(detectedMalformedFile)

        try originalData.write(to: url, options: .atomic)
        let recoveredOriginalFile = await waitUntil {
            !manager.isUsingLastKnownGood && manager.configError == nil
        }
        XCTAssertTrue(recoveredOriginalFile)
        XCTAssertEqual(manager.statusMessage, "Reloaded external changes")
    }

    func testFirstProfileSwitchAfterVersionOneLoadPreservesOriginalBytes() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let versionOneData = Data(
            """
            {
              "version": 1,
              "activeProfile": "default",
              "profiles": {
                "default": { "mappings": [] },
                "other": { "mappings": [] }
              }
            }
            """.utf8
        )
        try versionOneData.write(to: url, options: .atomic)

        let manager = makeManager(url: url)
        XCTAssertTrue(manager.load())
        XCTAssertNotNil(manager.migrationNotice)
        XCTAssertTrue(manager.switchProfile("other"))

        let backupData = try Data(contentsOf: try XCTUnwrap(manager.lastBackupURL))
        XCTAssertEqual(backupData, versionOneData)

        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(storedObject["version"] as? Int, Configuration.currentVersion)
        XCTAssertEqual(storedObject["activeProfile"] as? String, "other")
    }

    func testProfileSwitchBacksUpUnexpectedValidExternalEdit() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let initial = Configuration(
            profiles: ["default": Profile(), "other": Profile()]
        )
        try JSONEncoder().encode(initial).write(to: url, options: .atomic)

        let manager = makeManager(url: url)
        XCTAssertTrue(manager.load())

        let externallyEdited = Configuration(
            profiles: ["default": Profile(), "other": Profile(), "External": Profile()]
        )
        let externalData = try JSONEncoder().encode(externallyEdited)
        try externalData.write(to: url, options: .atomic)

        XCTAssertTrue(manager.switchProfile("other"))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(manager.lastBackupURL)), externalData)

        let persisted = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.activeProfile, "other")
        XCTAssertNil(persisted.profiles["External"])
    }

    func testFailedRestoreHistoryStagingDoesNotConsumeOriginalBackup() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let backupURL = url.appendingPathExtension("bak")
        let current = Configuration(
            profiles: ["default": Profile(), "Current": Profile()]
        )
        let previous = Configuration(
            profiles: ["default": Profile(), "Previous": Profile()]
        )
        let currentData = try JSONEncoder().encode(current)
        let backupData = try JSONEncoder().encode(previous)
        try currentData.write(to: url, options: .atomic)
        try backupData.write(to: backupURL, options: .atomic)

        // A non-directory at the history path forces staging to fail. The
        // rollback slot must still contain the configuration being restored.
        let historyPath = temporaryDirectory.appendingPathComponent("backups")
        try Data("not a directory".utf8).write(to: historyPath, options: .atomic)

        let manager = makeManager(url: url)
        XCTAssertTrue(manager.load())
        XCTAssertFalse(manager.restoreLastBackup())

        XCTAssertEqual(try Data(contentsOf: url), currentData)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
        XCTAssertNotNil(manager.config.profiles["Current"])
        XCTAssertNil(manager.config.profiles["Previous"])
    }

    func testInitialMalformedFileIsPreservedAsRawRecoverySnapshotBeforeMutation() throws {
        let url = temporaryDirectory.appendingPathComponent("config.json")
        let malformedData = Data("{ this is the user's only copy".utf8)
        try malformedData.write(to: url, options: .atomic)

        let manager = makeManager(url: url)
        XCTAssertFalse(manager.load())
        XCTAssertNil(manager.lastBackupURL)

        XCTAssertTrue(manager.addProfile(named: "Recovered"))

        let recoveryURL = try XCTUnwrap(manager.lastRecoverySnapshotURL)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), malformedData)
        XCTAssertTrue(recoveryURL.lastPathComponent.hasPrefix("config-invalid-"))
        XCTAssertTrue(manager.statusMessage.contains(recoveryURL.lastPathComponent))
        XCTAssertNil(manager.lastBackupURL, "Unreadable bytes must not become the trusted .bak file")

        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        XCTAssertNotNil(saved.profiles["Recovered"])
    }

    private func waitUntil(
        attempts: Int = 60,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func makeManager(url: URL? = nil) -> ConfigManager {
        ConfigManager(
            configurationURL: url ?? temporaryDirectory.appendingPathComponent("config.json"),
            alternativeURLs: [],
            watchesFile: false
        )
    }
}
