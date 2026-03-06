import AppKit
import Foundation

enum AppActions {
    /// Open an app by bundle ID. Launches if not running, focuses if already running,
    /// cycles through windows if already focused.
    static func openApp(bundleId: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            if app.isActive {
                cycleWindows(for: app)
            } else {
                app.activate()
                log("[App] Focused: \(app.localizedName ?? bundleId)")
            }
        } else {
            launchApp(bundleId: bundleId)
        }
    }

    // MARK: - Private

    private static func launchApp(bundleId: String) {
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
                log("[App] Launched: \(app.localizedName ?? bundleId)")
            }
        }
    }

    private static func cycleWindows(for app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        if result == .apiDisabled {
            log("[App] Accessibility permission not granted — falling back to activate")
            app.activate()
            return
        }

        guard result == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            log("[App] Could not retrieve windows for \(app.localizedName ?? "app")")
            return
        }

        let eligibleWindows = axWindows.filter { window in
            // Filter to standard windows only
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
            guard let subrole = subroleRef as? String, subrole == "AXStandardWindow" else {
                return false
            }

            // Skip minimized windows
            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            if let minimized = minimizedRef as? Bool, minimized {
                return false
            }

            return true
        }

        guard eligibleWindows.count > 1 else { return }

        // Windows are in front-to-back order. Raise the backmost window to cycle
        // through all windows, not just the first two.
        // A, B, C → raise C → C, A, B → raise B → B, C, A → raise A → A, B, C
        let target = eligibleWindows.last!
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        // Setting main window attribute helps macOS switch Spaces when the
        // target window lives on a different virtual desktop.
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate()
        log("[App] Cycled window for \(app.localizedName ?? "app")")
    }
}
