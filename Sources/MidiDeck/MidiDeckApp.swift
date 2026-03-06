import SwiftUI
import CoreMIDI
import os.log
import ApplicationServices

private let logger = Logger(subsystem: "com.midideck", category: "app")

/// Logs to stderr so output always appears in the terminal.
func log(_ message: String) {
    fputs(message + "\n", stderr)
    logger.info("\(message)")
}

/// Shared state that starts the MIDI engine immediately on creation.
final class AppState: ObservableObject {
    let configManager = ConfigManager()
    let midiEngine = MIDIEngine()
    let midiOutput = MIDIOutputManager()
    var actionExecutor: ActionExecutor?
    private var eventLoopTask: Task<Void, Never>?

    init() {
        log("[MidiDeck] Initializing...")

        configManager.load()
        midiEngine.start()
        midiOutput.start()

        let executor = ActionExecutor(configManager: configManager, midiOutput: midiOutput)
        actionExecutor = executor

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            executor.sendInitialLEDStates()
        }

        eventLoopTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.midiEngine.eventStream {
                if Task.isCancelled { break }
                executor.handle(event: event)
            }
        }

        log("[MidiDeck] Started")
        checkAccessibilityPermission()
    }

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            log("[MidiDeck] WARNING: Accessibility permission not granted — window cycling will not work")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "MidiDeck needs Accessibility access to cycle windows. Please grant permission in System Settings → Privacy & Security → Accessibility, then relaunch MidiDeck."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        } else {
            log("[MidiDeck] Accessibility permission granted")
        }
    }

    deinit {
        eventLoopTask?.cancel()
        midiEngine.stop()
        midiOutput.stop()
    }
}

@main
struct MidiDeckApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                configManager: appState.configManager,
                midiEngine: appState.midiEngine,
                onSendLEDs: { appState.actionExecutor?.sendInitialLEDStates() },
                onOpenSettings: { openSettings() }
            )
        } label: {
            Image(systemName: "square.grid.3x3.fill")
        }
        .menuBarExtraStyle(.window)

        Window("MidiDeck Settings", id: "settings") {
            SettingsView(configManager: appState.configManager, midiEngine: appState.midiEngine)
        }
        .defaultSize(width: 700, height: 500)
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func openSettings() {
        NSApplication.shared.setActivationPolicy(.regular)
        for window in NSApplication.shared.windows {
            if window.title.contains("Settings") {
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
