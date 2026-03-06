import AppKit
import Foundation

// MARK: - Private CoreGraphics SPI for Space management

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray

@_silgen_name("CGSCopyManagedDisplayForSpace")
private func CGSCopyManagedDisplayForSpace(_ cid: Int32, _ space: UInt64) -> CFString

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: Int32, _ display: CFString, _ space: UInt64)

@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: Int32, _ spaces: CFArray)

@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: Int32, _ spaces: CFArray)

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
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
            guard let subrole = subroleRef as? String, subrole == "AXStandardWindow" else {
                return false
            }

            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            if let minimized = minimizedRef as? Bool, minimized {
                return false
            }

            return true
        }

        // CGWindowList sees all windows including full-screen ones on other Spaces,
        // while AX only sees windows on the current Space.
        let cgWindowIDs = getCGWindowIDs(for: app)

        if cgWindowIDs.count > eligibleWindows.count {
            // There are windows on other Spaces (e.g. full-screen) that AX can't see.
            // Prioritize cross-Space switching over same-Space cycling.
            if switchToNextSpace(windowIDs: cgWindowIDs, app: app) {
                log("[App] Cycled window for \(app.localizedName ?? "app") via Space switch (CG: \(cgWindowIDs.count), AX: \(eligibleWindows.count))")
            }
        } else if eligibleWindows.count > 1 {
            // All windows on the current Space — use AX to raise the backmost
            let target = eligibleWindows.last!
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            app.activate()
            log("[App] Cycled window for \(app.localizedName ?? "app") (AX: \(eligibleWindows.count) windows)")
        }
    }

    /// Get CGWindowIDs for an app's real windows (all Spaces, including full-screen).
    private static func getCGWindowIDs(for app: NSRunningApplication) -> [CGWindowID] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windowList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            if let bounds = CGRect(dictionaryRepresentation: info[kCGWindowBounds as String] as! CFDictionary),
               bounds.width < 100 || bounds.height < 100 { return nil }
            return wid
        }
    }

    /// Switch to a Space that contains one of this app's windows but is not the current Space.
    private static func switchToNextSpace(windowIDs: [CGWindowID], app: NSRunningApplication) -> Bool {
        let cid = _CGSDefaultConnection()
        let currentSpace = CGSGetActiveSpace(cid)

        for wid in windowIDs {
            let widArray = [wid] as CFArray
            let spacesRef = CGSCopySpacesForWindows(cid, 0x7, widArray)
            guard let spaces = spacesRef as? [NSNumber],
                  let space = spaces.first?.uint64Value,
                  space != currentSpace else { continue }

            let display = CGSCopyManagedDisplayForSpace(cid, space)
            let targetSpaceArray = [NSNumber(value: space)] as CFArray
            let currentSpaceArray = [NSNumber(value: currentSpace)] as CFArray
            CGSManagedDisplaySetCurrentSpace(cid, display, space)
            CGSShowSpaces(cid, targetSpaceArray)
            CGSHideSpaces(cid, currentSpaceArray)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                app.activate()
            }
            return true
        }

        return false
    }
}
