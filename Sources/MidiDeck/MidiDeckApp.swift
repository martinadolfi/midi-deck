import ApplicationServices
import Combine
import CoreMIDI
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.midideck", category: "app")

/// Logs to stderr as well as Unified Logging so development builds remain easy
/// to diagnose from a terminal.
func log(_ message: String) {
    fputs(message + "\n", stderr)
    logger.info("\(message)")
}

@MainActor
final class AppState: ObservableObject {
    let configManager: ConfigManager
    let midiEngine: MIDIEngine
    let midiOutput: MIDIOutputManager
    let actionExecutor: ActionExecutor

    @Published var actionsPaused = false
    @Published private(set) var isLearning = false
    @Published private(set) var routingNotice: String?

    private var eventLoopTask: Task<Void, Never>?
    private var feedbackRefreshCancellable: AnyCancellable?
    private var configurationRefreshCancellable: AnyCancellable?

    init() {
        let manager = ConfigManager()
        let engine = MIDIEngine()
        let output = MIDIOutputManager()

        configManager = manager
        midiEngine = engine
        midiOutput = output
        actionExecutor = ActionExecutor(configManager: manager, midiOutput: output)

        log("[MidiDeck] Initializing…")
        _ = manager.load()
        engine.start()
        output.start()

        eventLoopTask = Task { [weak self, engine] in
            for await input in engine.events() {
                guard !Task.isCancelled, let self else { break }
                route(input)
            }
        }

        // Rehydrate feedback after a destination is connected or reconnected.
        feedbackRefreshCancellable = engine.$connectedDestinations
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.actionExecutor.sendInitialLEDStates()
                }
            }

        // Configuration can change through the visual editor or an external
        // JSON edit. Reset continuous-control caches and rehydrate feedback for
        // both paths so a previously applied CC value never masks a new action.
        configurationRefreshCancellable = manager.$config
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.actionExecutor.configurationDidChange()
                }
            }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.actionExecutor.sendInitialLEDStates()
        }

        if !AXIsProcessTrusted() {
            log("[MidiDeck] Accessibility is off; app launching works, but window cycling is limited")
        }
        log("[MidiDeck] Started")
    }

    deinit {
        eventLoopTask?.cancel()
        midiEngine.stop()
        midiOutput.stop()
    }

    func beginLearning() {
        isLearning = true
        routingNotice = "MIDI Learn is listening; actions are temporarily paused."
        actionExecutor.clearPendingControls()
    }

    func endLearning() {
        isLearning = false
        routingNotice = nil
    }

    func setPaused(_ paused: Bool) {
        actionsPaused = paused
        if paused {
            actionExecutor.clearPendingControls()
            routingNotice = "Actions are paused."
        } else {
            routingNotice = nil
        }
    }

    @discardableResult
    func reloadConfiguration() -> Bool {
        configManager.load()
    }

    private func route(_ input: MIDIInputEvent) {
        guard !actionsPaused, !isLearning else { return }

        guard configManager.config.inputRoute(
            for: input,
            among: midiEngine.connectedSources
        ) != nil else {
            if configManager.config.midi.inputMode == .automatic,
               midiEngine.connectedSources.count > 1 {
                routingNotice = "Choose which MIDI controller MidiDeck should respond to."
            }
            return
        }

        routingNotice = nil
        actionExecutor.handle(input: input, connectedSources: midiEngine.connectedSources)
    }
}

@main
struct MidiDeckApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarIcon(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Window("MidiDeck Control Center", id: "settings") {
            SettingsView(appState: appState)
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var configManager: ConfigManager
    @ObservedObject private var midiEngine: MIDIEngine

    init(appState: AppState) {
        self.appState = appState
        _configManager = ObservedObject(wrappedValue: appState.configManager)
        _midiEngine = ObservedObject(wrappedValue: appState.midiEngine)
    }

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("MidiDeck")
            .accessibilityValue(status)
    }

    private var symbol: String {
        if configManager.configError != nil || midiEngine.initializationError != nil {
            return "exclamationmark.square.fill"
        }
        if appState.actionsPaused || appState.isLearning {
            return "square.grid.3x3.middle.filled"
        }
        return "square.grid.3x3.fill"
    }

    private var status: String {
        if configManager.configError != nil { return "Configuration error" }
        if midiEngine.initializationError != nil { return "MIDI error" }
        if appState.isLearning { return "MIDI Learn active" }
        if appState.actionsPaused { return "Actions paused" }
        if midiEngine.connectedSources.isEmpty { return "No controller connected" }
        if configManager.config.midi.inputMode == .automatic,
           midiEngine.connectedSources.count > 1 {
            return "Controller selection required"
        }
        if configManager.config.midi.inputMode == .selected {
            let connectedIDs = Set(midiEngine.connectedSources.map(\.uniqueID))
            if configManager.config.midi.inputSources.allSatisfy({ !connectedIDs.contains($0.uniqueID) }) {
                return "Waiting for selected controller"
            }
        }
        return "Ready"
    }
}
