import Foundation
import Combine

final class ConfigManager: ObservableObject {
    @Published var config: Configuration = Configuration()
    @Published var configError: String?

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var monitoredFileDescriptor: Int32 = -1
    private let fileManager = FileManager.default

    var activeProfile: Profile? {
        config.profiles[config.activeProfile]
    }

    var profileNames: [String] {
        Array(config.profiles.keys).sorted()
    }

    // MARK: - Config File Paths

    static var configPaths: [String] {
        let cwd = FileManager.default.currentDirectoryPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(cwd)/config.json",
            "\(home)/.config/midideck/config.json",
        ]
    }

    static func resolvedConfigPath() -> String? {
        for path in configPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Load

    func load() {
        guard let path = Self.resolvedConfigPath() else {
            log("[Config] No config.json found, using defaults")
            configError = nil
            return
        }
        loadFrom(path: path)
        watchFile(at: path)
    }

    func loadFrom(path: String) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoded = try JSONDecoder().decode(Configuration.self, from: data)
            DispatchQueue.main.async {
                self.config = decoded
                self.configError = nil
            }
            log("[Config] Loaded from \(path) — active profile: \(decoded.activeProfile)")
        } catch {
            log("[Config] Failed to load \(path): \(error)")
            DispatchQueue.main.async {
                self.configError = error.localizedDescription
            }
        }
    }

    // MARK: - Save

    func save() {
        let path = Self.resolvedConfigPath() ?? Self.configPaths[0]

        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: path))
            log("[Config] Saved to \(path)")
        } catch {
            log("[Config] Failed to save: \(error)")
        }
    }

    // MARK: - Profile Switching

    func switchProfile(_ name: String) {
        guard config.profiles[name] != nil else {
            log("[Config] Profile not found: \(name)")
            return
        }
        config.activeProfile = name
        log("[Config] Switched to profile: \(name)")
    }

    // MARK: - Mapping Management

    func addMapping(_ mapping: Mapping, toProfile profileName: String? = nil) {
        let name = profileName ?? config.activeProfile
        config.profiles[name, default: Profile()].mappings.append(mapping)
    }

    func removeMapping(id: UUID, fromProfile profileName: String? = nil) {
        let name = profileName ?? config.activeProfile
        config.profiles[name]?.mappings.removeAll { $0.id == id }
    }

    func updateMapping(_ mapping: Mapping, inProfile profileName: String? = nil) {
        let name = profileName ?? config.activeProfile
        guard let index = config.profiles[name]?.mappings.firstIndex(where: { $0.id == mapping.id }) else { return }
        config.profiles[name]?.mappings[index] = mapping
    }

    // MARK: - File Watching

    private func watchFile(at path: String) {
        stopWatching()

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            log("[Config] Failed to open file for watching: \(path)")
            return
        }
        monitoredFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            // Small delay to let the write finish
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                log("[Config] File changed — reloading")
                self?.loadFrom(path: path)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileMonitor = source
        log("[Config] Watching \(path) for changes")
    }

    private func stopWatching() {
        fileMonitor?.cancel()
        fileMonitor = nil
        if monitoredFileDescriptor >= 0 {
            monitoredFileDescriptor = -1
        }
    }

    deinit {
        stopWatching()
    }
}
