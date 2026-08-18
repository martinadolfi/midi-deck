import Combine
import Darwin
import Foundation

enum ConfigurationSaveState: Equatable {
    case notSaved
    case saved(Date)
    case failed(String)

    var label: String {
        switch self {
        case .notSaved: return "Not saved yet"
        case .saved: return "Saved"
        case .failed: return "Save failed"
        }
    }
}

/// Owns one visible, canonical configuration file and applies changes as
/// validated transactions. Invalid loads and failed saves never replace the
/// last-known-good in-memory configuration.
@MainActor
final class ConfigManager: ObservableObject {
    @Published var config: Configuration = Configuration()
    @Published private(set) var configError: String?
    @Published private(set) var validationIssues: [ConfigurationIssue] = []
    @Published private(set) var saveState: ConfigurationSaveState = .notSaved
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var migrationNotice: String?
    @Published private(set) var isUsingLastKnownGood = false
    @Published private(set) var lastRecoverySnapshotURL: URL?

    let activeConfigURL: URL
    let alternativeConfigURLs: [URL]

    private let fileManager: FileManager
    private let watchesFile: Bool
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var lastWrittenData: Data?
    private var lastLoadedData: Data?
    /// Raw, validated version-1 bytes waiting to be preserved before the first
    /// write upgrades the canonical file to the current schema.
    private var pendingMigrationBackupData: Data?

    init(
        configurationURL: URL? = nil,
        alternativeURLs: [URL]? = nil,
        fileManager: FileManager = .default,
        watchesFile: Bool = true
    ) {
        self.fileManager = fileManager
        self.watchesFile = watchesFile
        self.activeConfigURL = configurationURL ?? Self.canonicalConfigURL(fileManager: fileManager)

        if let alternativeURLs {
            self.alternativeConfigURLs = alternativeURLs
        } else if configurationURL == nil {
            let projectURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("config.json")
                .standardizedFileURL
            let canonical = Self.canonicalConfigURL(fileManager: fileManager).standardizedFileURL
            self.alternativeConfigURLs = projectURL != canonical && fileManager.fileExists(atPath: projectURL.path)
                ? [projectURL]
                : []
        } else {
            self.alternativeConfigURLs = []
        }
    }

    deinit {
        reloadTask?.cancel()
        fileMonitor?.cancel()
    }

    var activeProfile: Profile? {
        config.profiles[config.activeProfile]
    }

    var profileNames: [String] {
        config.profiles.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var errorIssues: [ConfigurationIssue] {
        validationIssues.filter { $0.severity == .error }
    }

    var warningIssues: [ConfigurationIssue] {
        validationIssues.filter { $0.severity == .warning }
    }

    var lastBackupURL: URL? {
        let url = backupURL
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Paths

    static func canonicalConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("midideck", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Compatibility list for diagnostics and older call sites. The stable user
    /// path is always first; project-local files are treated as explicit imports.
    static var configPaths: [String] {
        let canonical = canonicalConfigURL().path
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("config.json").path
        return canonical == project ? [canonical] : [canonical, project]
    }

    static func resolvedConfigPath() -> String? {
        configPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private var backupURL: URL {
        activeConfigURL.appendingPathExtension("bak")
    }

    private var backupsDirectoryURL: URL {
        activeConfigURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    // MARK: - Load / import / restore

    /// Loads synchronously so callers can safely refresh feedback immediately
    /// after this method returns.
    @discardableResult
    func load() -> Bool {
        startWatchingIfPossible()

        guard fileManager.fileExists(atPath: activeConfigURL.path) else {
            if lastLoadedData != nil || lastWrittenData != nil {
                setError("The configuration file is missing. MidiDeck is keeping the last-known-good setup active.")
                isUsingLastKnownGood = true
                statusMessage = "Using last-known-good configuration"
                return false
            }
            configError = nil
            validationIssues = ConfigurationValidator.issues(in: config)
            saveState = .notSaved
            statusMessage = "No configuration file yet"
            migrationNotice = nil
            isUsingLastKnownGood = false
            log("[Config] No configuration at \(activeConfigURL.path); using safe defaults")
            return true
        }

        return loadActiveFile(externalChange: false)
    }

    /// Compatibility entry point. Loading a different path is an explicit import
    /// into the canonical file, never a silent change of the save destination.
    @discardableResult
    func loadFrom(path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if url == activeConfigURL.standardizedFileURL {
            return load()
        }
        return importConfiguration(from: url)
    }

    @discardableResult
    func importConfiguration(from url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try decodeAndValidate(data)
            guard write(decoded, createBackup: true, reason: "Imported configuration") else {
                return false
            }
            migrationNotice = storedVersion(in: data).flatMap {
                $0 < Configuration.currentVersion
                    ? "Imported version \($0) and upgraded it safely to version \(Configuration.currentVersion)."
                    : nil
            }
            return true
        } catch {
            report(error, prefix: "Could not import \(url.lastPathComponent)")
            return false
        }
    }

    @discardableResult
    func restoreLastBackup() -> Bool {
        guard fileManager.fileExists(atPath: backupURL.path) else {
            setError("No configuration backup is available yet.")
            return false
        }

        do {
            let backupData = try Data(contentsOf: backupURL)
            let decoded = try decodeAndValidate(backupData)
            let currentData = try currentValidatedSnapshotData()

            // Rotate the current configuration into the last-backup slot first.
            // A second restore can therefore undo this restore. If the canonical
            // write fails, put the original backup back in place.
            try createBackups(from: currentData)
            guard write(
                decoded,
                createBackup: false,
                reason: "Restored last backup",
                suppressAutomaticBackup: true
            ) else {
                try? backupData.write(to: backupURL, options: .atomic)
                return false
            }
            return true
        } catch {
            report(error, prefix: "Could not restore the backup")
            return false
        }
    }

    // MARK: - Save and transactions

    @discardableResult
    func save() -> Bool {
        write(config, createBackup: true, reason: "Saved configuration")
    }

    @discardableResult
    private func mutate(
        reason: String,
        createBackup: Bool = true,
        _ change: (inout Configuration) -> Void
    ) -> Bool {
        var candidate = config
        change(&candidate)
        candidate.version = Configuration.currentVersion
        return write(candidate, createBackup: createBackup, reason: reason)
    }

    private func write(
        _ candidate: Configuration,
        createBackup: Bool,
        reason: String,
        suppressAutomaticBackup: Bool = false
    ) -> Bool {
        let issues = ConfigurationValidator.issues(in: candidate)
        validationIssues = issues
        if let firstError = issues.first(where: { $0.severity == .error }) {
            setError(firstError.message)
            return false
        }

        do {
            let data = try encoded(candidate)
            let directory = activeConfigURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let recoverySnapshot = try preserveInvalidCanonicalFile(candidateData: data)

            if !suppressAutomaticBackup,
               let backupData = backupDataForWrite(candidateData: data, requested: createBackup) {
                try createBackups(from: backupData)
            }

            try data.write(to: activeConfigURL, options: .atomic)
            config = candidate
            lastWrittenData = data
            lastLoadedData = data
            pendingMigrationBackupData = nil
            configError = nil
            isUsingLastKnownGood = false
            saveState = .saved(Date())
            if let recoverySnapshot {
                lastRecoverySnapshotURL = recoverySnapshot
                statusMessage = "\(reason). Preserved the unreadable file as \(recoverySnapshot.lastPathComponent)."
            } else {
                statusMessage = reason
            }
            migrationNotice = nil
            startWatchingIfPossible()
            log("[Config] \(reason) at \(activeConfigURL.path)")
            return true
        } catch {
            report(error, prefix: "Could not save configuration")
            saveState = .failed(configError ?? error.localizedDescription)
            return false
        }
    }

    // MARK: - Profile management

    @discardableResult
    func switchProfile(_ name: String) -> Bool {
        guard config.profiles[name] != nil else {
            setError("Profile not found: \(name)")
            return false
        }
        return mutate(reason: "Switched to \(name)", createBackup: false) {
            $0.activeProfile = name
        }
    }

    @discardableResult
    func addProfile(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setError("Profile names cannot be empty.")
            return false
        }
        guard config.profiles[name] == nil else {
            setError("A profile named '\(name)' already exists.")
            return false
        }
        return mutate(reason: "Added profile \(name)") {
            $0.profiles[name] = Profile()
        }
    }

    @discardableResult
    func duplicateProfile(_ sourceName: String, as rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = config.profiles[sourceName] else {
            setError("Profile not found: \(sourceName)")
            return false
        }
        guard !name.isEmpty, config.profiles[name] == nil else {
            setError(name.isEmpty ? "Profile names cannot be empty." : "A profile named '\(name)' already exists.")
            return false
        }
        return mutate(reason: "Duplicated profile \(sourceName)") {
            var copy = source
            copy.mappings = copy.mappings.map { mapping in
                var mapping = mapping
                mapping.id = UUID()
                return mapping
            }
            $0.profiles[name] = copy
        }
    }

    @discardableResult
    func renameProfile(_ oldName: String, to rawName: String) -> Bool {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile = config.profiles[oldName] else {
            setError("Profile not found: \(oldName)")
            return false
        }
        guard !newName.isEmpty, oldName == newName || config.profiles[newName] == nil else {
            setError(newName.isEmpty ? "Profile names cannot be empty." : "A profile named '\(newName)' already exists.")
            return false
        }
        guard oldName != newName else { return true }

        return mutate(reason: "Renamed profile to \(newName)") { candidate in
            candidate.profiles.removeValue(forKey: oldName)
            candidate.profiles[newName] = profile
            if candidate.activeProfile == oldName {
                candidate.activeProfile = newName
            }
            for profileKey in candidate.profiles.keys {
                guard var edited = candidate.profiles[profileKey] else { continue }
                for index in edited.mappings.indices
                    where edited.mappings[index].action.type == .switchProfile
                        && edited.mappings[index].action.profile == oldName {
                    edited.mappings[index].action.profile = newName
                }
                candidate.profiles[profileKey] = edited
            }
        }
    }

    @discardableResult
    func removeProfile(named name: String) -> Bool {
        guard config.profiles[name] != nil else { return false }
        guard config.profiles.count > 1 else {
            setError("MidiDeck needs at least one profile.")
            return false
        }
        let replacement = profileNames.first { $0 != name }!
        return mutate(reason: "Deleted profile \(name)") { candidate in
            candidate.profiles.removeValue(forKey: name)
            if candidate.activeProfile == name {
                candidate.activeProfile = replacement
            }
            // Preserve validity for mappings that switched to the deleted profile.
            for profileKey in candidate.profiles.keys {
                guard var edited = candidate.profiles[profileKey] else { continue }
                for index in edited.mappings.indices
                    where edited.mappings[index].action.type == .switchProfile
                        && edited.mappings[index].action.profile == name {
                    edited.mappings[index].action.profile = replacement
                }
                candidate.profiles[profileKey] = edited
            }
        }
    }

    // MARK: - Mapping management

    @discardableResult
    func addMapping(_ mapping: Mapping, toProfile profileName: String? = nil) -> Bool {
        let name = profileName ?? config.activeProfile
        guard config.profiles[name] != nil else {
            setError("Profile not found: \(name)")
            return false
        }
        return mutate(reason: "Added mapping") {
            $0.profiles[name]?.mappings.append(mapping)
        }
    }

    @discardableResult
    func removeMapping(id: UUID, fromProfile profileName: String? = nil) -> Bool {
        let name = profileName ?? config.activeProfile
        guard config.profiles[name]?.mappings.contains(where: { $0.id == id }) == true else {
            return false
        }
        return mutate(reason: "Deleted mapping") {
            $0.profiles[name]?.mappings.removeAll { $0.id == id }
        }
    }

    @discardableResult
    func updateMapping(_ mapping: Mapping, inProfile profileName: String? = nil) -> Bool {
        let name = profileName ?? config.activeProfile
        guard let index = config.profiles[name]?.mappings.firstIndex(where: { $0.id == mapping.id }) else {
            setError("That mapping no longer exists.")
            return false
        }
        return mutate(reason: "Updated mapping") {
            $0.profiles[name]?.mappings[index] = mapping
        }
    }

    // MARK: - MIDI preferences

    @discardableResult
    func setMIDIInputMode(_ mode: MIDIInputMode) -> Bool {
        mutate(reason: "Updated MIDI input routing") {
            $0.midi.inputMode = mode
            if mode == .automatic || mode == .all {
                $0.midi.inputSources = []
            }
        }
    }

    @discardableResult
    func setSelectedInputSources(_ sources: [MIDIEndpointReference]) -> Bool {
        let deduplicated = Array(Set(sources)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !deduplicated.isEmpty else {
            setError("Choose at least one MIDI input, or use Automatic.")
            return false
        }
        return mutate(reason: "Selected MIDI input") {
            $0.midi.inputMode = .selected
            $0.midi.inputSources = deduplicated
        }
    }

    @discardableResult
    func selectExclusiveInput(_ source: MIDIEndpointReference) -> Bool {
        setSelectedInputSources([source])
    }

    @discardableResult
    func setFeedbackDestination(_ destination: MIDIEndpointReference?) -> Bool {
        mutate(reason: "Updated feedback output") {
            $0.midi.feedbackDestination = destination
        }
    }

    func shouldRespond(
        to source: MIDIEndpointReference,
        connectedSources: [MIDIEndpointReference]
    ) -> Bool {
        switch config.midi.inputMode {
        case .automatic:
            return connectedSources.count == 1 && connectedSources[0].uniqueID == source.uniqueID
        case .all:
            return true
        case .selected:
            return config.midi.inputSources.contains { $0.uniqueID == source.uniqueID }
        }
    }

    // MARK: - File watching

    private func startWatchingIfPossible() {
        guard watchesFile else { return }
        let directory = activeConfigURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directory.path) else { return }

        fileMonitor?.cancel()
        fileMonitor = nil

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log("[Config] Could not watch \(directory.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleExternalReload()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        fileMonitor = source
    }

    private func scheduleExternalReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            _ = self?.loadActiveFile(externalChange: true)
        }
    }

    @discardableResult
    private func loadActiveFile(externalChange: Bool) -> Bool {
        do {
            let data = try Data(contentsOf: activeConfigURL)
            let canSuppressSelfWrite = configError == nil && !isUsingLastKnownGood
            if externalChange,
               canSuppressSelfWrite,
               data == lastWrittenData || data == lastLoadedData {
                return true
            }

            let originalVersion = storedVersion(in: data) ?? 1
            let decoded = try decodeAndValidate(data)
            config = decoded
            lastLoadedData = data
            lastWrittenData = nil
            pendingMigrationBackupData = originalVersion < Configuration.currentVersion ? data : nil
            validationIssues = ConfigurationValidator.issues(in: decoded)
            configError = nil
            isUsingLastKnownGood = false
            saveState = .saved(Date())
            statusMessage = externalChange ? "Reloaded external changes" : "Configuration loaded"
            migrationNotice = originalVersion < Configuration.currentVersion
                ? "Version \(originalVersion) is loaded safely in memory. It will be upgraded with a backup when you next save."
                : nil
            log("[Config] Loaded \(activeConfigURL.path) — profile: \(decoded.activeProfile)")
            return true
        } catch {
            report(error, prefix: "Could not load configuration")
            isUsingLastKnownGood = true
            statusMessage = "Using last-known-good configuration"
            return false
        }
    }

    // MARK: - Encoding, validation, and backups

    private func decodeAndValidate(_ data: Data) throws -> Configuration {
        do {
            let decoded = try JSONDecoder().decode(Configuration.self, from: data)
            let issues = ConfigurationValidator.issues(in: decoded)
            if let firstError = issues.first(where: { $0.severity == .error }) {
                throw ConfigurationReadError.validation(firstError.message)
            }
            return decoded
        } catch let error as ConfigurationReadError {
            throw error
        } catch {
            throw ConfigurationReadError.decoding(Self.describeDecodingError(error))
        }
    }

    private func encoded(_ configuration: Configuration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(configuration)
    }

    /// Selects recovery bytes without ever replacing an existing good backup
    /// with malformed on-disk data. Pending legacy bytes win so even mutations
    /// that normally skip backups (such as profile switches) migrate safely.
    private func backupDataForWrite(candidateData: Data, requested: Bool) -> Data? {
        if let pendingMigrationBackupData,
           pendingMigrationBackupData != candidateData {
            return pendingMigrationBackupData
        }

        if let currentData = try? Data(contentsOf: activeConfigURL) {
            guard currentData != candidateData else { return nil }
            if isValidConfigurationData(currentData) {
                let isExpectedOnDiskData = currentData == lastLoadedData || currentData == lastWrittenData
                if requested || !isExpectedOnDiskData {
                    if !requested {
                        log("[Config] Backing up valid external changes before a normally unbacked mutation")
                    }
                    return currentData
                }
                return nil
            }
        }

        // A missing or malformed canonical file is exceptional: preserve the
        // last validated bytes even for normally non-structural mutations.
        guard let lastLoadedData,
              lastLoadedData != candidateData,
              isValidConfigurationData(lastLoadedData) else {
            return nil
        }

        log("[Config] Backing up the last validated configuration because the on-disk file is unavailable or invalid")
        return lastLoadedData
    }

    /// Returns the best exact representation of the active, validated setup.
    /// This is used by restore so the last-backup file behaves like an undo slot.
    private func currentValidatedSnapshotData() throws -> Data {
        if let currentData = try? Data(contentsOf: activeConfigURL),
           isValidConfigurationData(currentData) {
            return currentData
        }
        if let lastLoadedData, isValidConfigurationData(lastLoadedData) {
            return lastLoadedData
        }

        let currentData = try encoded(config)
        _ = try decodeAndValidate(currentData)
        return currentData
    }

    private func isValidConfigurationData(_ data: Data) -> Bool {
        (try? decodeAndValidate(data)) != nil
    }

    /// Never discard the only copy of an unreadable configuration. These raw
    /// recovery snapshots are deliberately separate from `.bak`, which always
    /// represents a configuration MidiDeck has successfully validated.
    private func preserveInvalidCanonicalFile(candidateData: Data) throws -> URL? {
        guard let currentData = try? Data(contentsOf: activeConfigURL),
              currentData != candidateData,
              !isValidConfigurationData(currentData) else {
            return nil
        }

        try fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let snapshot = backupsDirectoryURL.appendingPathComponent(
            "config-invalid-\(backupTimestamp())-\(UUID().uuidString.prefix(8)).json"
        )
        try currentData.write(to: snapshot, options: .atomic)
        pruneBackups(keeping: 10)
        log("[Config] Preserved unreadable configuration at \(snapshot.path)")
        return snapshot
    }

    private func createBackups(from data: Data) throws {
        try fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let snapshot = backupsDirectoryURL
            .appendingPathComponent("config-\(backupTimestamp())-\(UUID().uuidString.prefix(8)).json")
        try data.write(to: snapshot, options: .atomic)
        // Publish the rollback slot last. If history staging fails, an existing
        // `.bak` remains untouched and a failed restore cannot consume itself.
        try data.write(to: backupURL, options: .atomic)
        pruneBackups(keeping: 10)
    }

    private func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private func pruneBackups(keeping limit: Int) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: backupsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in sorted.dropFirst(limit) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func storedVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? Int
    }

    private func setError(_ message: String) {
        configError = message
        statusMessage = message
        log("[Config] \(message)")
    }

    private func report(_ error: Error, prefix: String) {
        let message = "\(prefix): \(error.localizedDescription)"
        setError(message)
    }

    private static func describeDecodingError(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "Missing '\(key.stringValue)' at \(codingPath(context.codingPath))."
        case let DecodingError.typeMismatch(_, context):
            return "Wrong value type at \(codingPath(context.codingPath)): \(context.debugDescription)"
        case let DecodingError.valueNotFound(_, context):
            return "Missing value at \(codingPath(context.codingPath)): \(context.debugDescription)"
        case let DecodingError.dataCorrupted(context):
            return "Invalid value at \(codingPath(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "the document root" : value
    }
}

private enum ConfigurationReadError: LocalizedError {
    case decoding(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .decoding(let message), .validation(let message): return message
        }
    }
}
