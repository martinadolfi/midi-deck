import AppKit
import Foundation

enum AppActions {
    /// Open an app by bundle ID. Launches if not running, focuses if already running.
    static func openApp(bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            log("[App] Bundle ID not found: \(bundleId)")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if let error = error {
                log("[App] Failed to open \(bundleId): \(error.localizedDescription)")
            } else if let app = app {
                log("[App] Opened/focused: \(app.localizedName ?? bundleId)")
            }
        }
    }
}
