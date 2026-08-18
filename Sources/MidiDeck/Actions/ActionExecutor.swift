import AppKit
import Combine
import Foundation

struct ActionActivity: Identifiable {
    let id = UUID()
    let date = Date()
    let sourceName: String
    let mappingName: String
    let detail: String
    let succeeded: Bool
}

/// Matches routed MIDI input to configured actions and owns feedback state.
/// Calls arrive on the main actor so configuration, activity UI, and throttled
/// CC state stay coherent when profiles or files change.
@MainActor
final class ActionExecutor: ObservableObject {
    let configManager: ConfigManager
    let midiOutput: MIDIOutputManager

    @Published private(set) var lastActivity: ActionActivity?
    @Published private(set) var actionError: String?

    private struct PendingCC {
        let mapping: Mapping
        let source: MIDIEndpointReference
        let value: UInt8
    }

    private var latestCC: [String: PendingCC] = [:]
    private var appliedCC: [String: UInt8] = [:]
    private var ccTimer: DispatchSourceTimer?
    private var feedbackGeneration: UInt64 = 0
    private var pendingFeedbackTasks: [UUID: Task<Void, Never>] = [:]
    private var configurationCancellable: AnyCancellable?
    private var lastProfileName: String?
    private var lastFeedbackProfile: Profile?
    private var lastFeedbackDestination: MIDIEndpointReference?
    private var toastWindow: NSWindow?
    private var toastDismissTask: Task<Void, Never>?

    init(configManager: ConfigManager, midiOutput: MIDIOutputManager) {
        self.configManager = configManager
        self.midiOutput = midiOutput
        self.lastProfileName = configManager.config.activeProfile
        startCCTimer()
        configurationCancellable = configManager.$config
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.invalidatePendingFeedback()
                }
            }
    }

    deinit {
        ccTimer?.cancel()
        pendingFeedbackTasks.values.forEach { $0.cancel() }
        toastDismissTask?.cancel()
    }

    // MARK: - Event handling

    func handle(
        input: MIDIInputEvent,
        connectedSources: [MIDIEndpointReference] = []
    ) {
        let profileName = configManager.config.activeProfile
        if profileName != lastProfileName {
            invalidatePendingFeedback()
            clearPendingControls()
            lastProfileName = profileName
        }

        guard let profile = configManager.activeProfile else { return }

        guard let mapping = profile.matchingMapping(for: input, among: connectedSources) else {
            log("[MIDI] Unmatched from \(input.source.name): \(input.event.description)")
            return
        }

        if case .controlChange(_, _, let value) = input.event {
            guard mapping.action.type == .setVolume || mapping.action.type == .setInputVolume else {
                record(
                    mapping: mapping,
                    source: input.source,
                    detail: "This control-change trigger needs a volume action",
                    succeeded: false
                )
                return
            }

            let key = "\(profileName):\(mapping.id.uuidString):\(input.source.uniqueID)"
            latestCC[key] = PendingCC(mapping: mapping, source: input.source, value: value)
        } else {
            log("[Action] Matched on \(input.source.name): \(mapping.description) → \(mapping.action.type.rawValue)")
            let result = execute(mapping: mapping)
            if result.succeeded, mapping.action.type != .switchProfile {
                sendFeedback(mapping: mapping)
            }
            record(
                mapping: mapping,
                source: input.source,
                detail: result.detail,
                succeeded: result.succeeded
            )
        }
    }

    func clearPendingControls() {
        latestCC.removeAll()
        appliedCC.removeAll()
    }

    /// Reconciles controller state after any validated configuration change.
    /// Clearing the last rendered profile first prevents deleted mappings or a
    /// profile changed outside the MIDI action path from leaving stale LEDs on.
    func configurationDidChange() {
        // The config publisher invalidates feedback synchronously at the actual
        // mutation boundary. Do not cancel actions received afterward while the
        // app's visual reconciliation debounce is still pending.
        clearPendingControls()
        if let lastFeedbackProfile {
            clearLEDs(
                profile: lastFeedbackProfile,
                defaultDestination: lastFeedbackDestination
            )
        }
        lastFeedbackProfile = nil
        lastFeedbackDestination = nil
        lastProfileName = configManager.config.activeProfile
        sendInitialLEDStates()
    }

    // MARK: - CC throttling

    private func startCCTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.flushCC()
            }
        }
        timer.resume()
        ccTimer = timer
    }

    private func flushCC() {
        let pendingValues = latestCC
        latestCC.removeAll(keepingCapacity: true)

        for (key, pending) in pendingValues where appliedCC[key] != pending.value {
            log("[Action] \(pending.mapping.description) → val:\(pending.value)")
            let result = executeCC(action: pending.mapping.action, value: pending.value)
            if result.succeeded {
                appliedCC[key] = pending.value
            }
            record(
                mapping: pending.mapping,
                source: pending.source,
                detail: result.detail,
                succeeded: result.succeeded
            )
        }
    }

    private func executeCC(action: Action, value: UInt8) -> (succeeded: Bool, detail: String) {
        switch action.type {
        case .setVolume:
            let device = action.device ?? "default"
            let success = AudioActions.setVolume(deviceName: device, ccValue: value)
            return (success, success ? "Output volume \(Int(value) * 100 / 127)%" : "Could not set output volume")

        case .setInputVolume:
            let device = action.device ?? "default"
            let success = AudioActions.setInputVolume(deviceName: device, ccValue: value)
            return (success, success ? "Input volume \(Int(value) * 100 / 127)%" : "Could not set input volume")

        default:
            return (false, "Unsupported continuous action")
        }
    }

    // MARK: - Action execution

    private func execute(mapping: Mapping) -> (succeeded: Bool, detail: String) {
        let action = mapping.action

        switch action.type {
        case .openApp:
            guard let bundleID = nonEmpty(action.bundleId) else {
                return (false, "Choose an application first")
            }
            let success = AppActions.openApp(bundleId: bundleID)
            return (success, success ? "Opened application" : "Application not found: \(bundleID)")

        case .setAudioOutput:
            guard let device = nonEmpty(action.device) else {
                return (false, "Choose an output device first")
            }
            let success = AudioActions.setAudioOutput(deviceName: device)
            return (success, success ? "Output → \(device)" : "Output device unavailable: \(device)")

        case .setAudioInput:
            guard let device = nonEmpty(action.device) else {
                return (false, "Choose an input device first")
            }
            let success = AudioActions.setAudioInput(deviceName: device)
            return (success, success ? "Input → \(device)" : "Input device unavailable: \(device)")

        case .switchAudioDevice:
            let result = AudioActions.switchAudioDevice(
                outputName: nonEmpty(action.device),
                inputName: nonEmpty(action.inputDevice)
            )
            if result.succeeded, let message = nonEmpty(action.notify) {
                showNotification(title: "MidiDeck", body: message)
            }
            return (result.succeeded, result.succeeded ? "Audio devices switched" : "One or more audio devices were unavailable")

        case .setVolume, .setInputVolume:
            return (false, "Volume actions require a control-change trigger")

        case .toggleMicMute:
            let device = nonEmpty(action.device) ?? "default"
            guard let muted = AudioActions.toggleMicMute(deviceName: device) else {
                return (false, "Microphone mute is unavailable for \(device)")
            }
            sendMuteLED(mapping: mapping, muted: muted)
            return (true, muted ? "Microphone muted" : "Microphone unmuted")

        case .setMicMute:
            let device = nonEmpty(action.device) ?? "default"
            let muted = action.muted ?? true
            let success = AudioActions.setMicMute(deviceName: device, muted: muted)
            if success {
                sendMuteLED(mapping: mapping, muted: muted)
            }
            return (success, success ? (muted ? "Microphone muted" : "Microphone unmuted") : "Microphone mute is unavailable for \(device)")

        case .switchProfile:
            guard let profileName = nonEmpty(action.profile),
                  configManager.config.profiles[profileName] != nil else {
                return (false, "Target profile is unavailable")
            }
            guard activateProfile(profileName) else {
                return (false, "Could not save the profile change")
            }
            return (true, "Profile → \(profileName)")
        }
    }

    /// Activates a profile through the same feedback-safe path used by MIDI
    /// actions. UI profile pickers should use this instead of mutating the
    /// configuration directly so stale LEDs and CC state are cleared.
    @discardableResult
    func activateProfile(_ profileName: String) -> Bool {
        guard let newProfile = configManager.config.profiles[profileName] else {
            return false
        }

        let previousName = configManager.config.activeProfile
        let oldProfile = configManager.activeProfile
        let previousDestination = lastFeedbackDestination
            ?? configManager.config.midi.feedbackDestination
        guard configManager.switchProfile(profileName) else {
            return false
        }

        invalidatePendingFeedback()
        if previousName != profileName, let oldProfile {
            clearLEDs(
                profile: oldProfile,
                defaultDestination: previousDestination
            )
        }
        clearPendingControls()
        lastProfileName = profileName
        sendInitialLEDStates(profile: newProfile)
        return true
    }

    // MARK: - Feedback

    private var defaultFeedbackDestination: MIDIEndpointReference? {
        configManager.config.midi.feedbackDestination
    }

    private func sendFeedback(mapping: Mapping) {
        let midiOut = midiOutput
        let destination = defaultFeedbackDestination
        let copiedMapping = mapping
        let scheduledProfile = configManager.config.activeProfile
        let scheduledGeneration = feedbackGeneration
        let taskID = UUID()

        pendingFeedbackTasks[taskID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self else { return }
            defer { pendingFeedbackTasks.removeValue(forKey: taskID) }
            guard !Task.isCancelled,
                  feedbackGeneration == scheduledGeneration,
                  configManager.config.activeProfile == scheduledProfile else {
                return
            }

            if copiedMapping.feedback != nil {
                midiOut.sendFeedback(mapping: copiedMapping, defaultDestination: destination)
            }
            guard let led = copiedMapping.led else { return }
            switch led.behavior {
            case .solid:
                midiOut.sendLEDState(mapping: copiedMapping, on: true, defaultDestination: destination)
            case .blink:
                midiOut.sendLEDState(mapping: copiedMapping, on: true, defaultDestination: destination)
                do {
                    try await Task.sleep(nanoseconds: 180_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      feedbackGeneration == scheduledGeneration,
                      configManager.config.activeProfile == scheduledProfile else {
                    return
                }
                midiOut.sendLEDState(mapping: copiedMapping, on: false, defaultDestination: destination)
            case .toggleOnMute:
                break
            }
        }
    }

    private func invalidatePendingFeedback() {
        feedbackGeneration &+= 1
        let tasks = Array(pendingFeedbackTasks.values)
        pendingFeedbackTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private func sendMuteLED(mapping: Mapping, muted: Bool) {
        guard mapping.led?.behavior == .toggleOnMute else { return }
        midiOutput.sendLEDState(
            mapping: mapping,
            on: muted,
            defaultDestination: defaultFeedbackDestination
        )
    }

    func sendInitialLEDStates() {
        guard let profile = configManager.activeProfile else { return }
        sendInitialLEDStates(profile: profile)
    }

    private func sendInitialLEDStates(profile: Profile) {
        for mapping in profile.mappings {
            // Arbitrary CC feedback often represents mutually exclusive state
            // (for example, which audio interface is active). Rehydrate only a
            // mapping whose configured target actually matches macOS now.
            if mapping.feedback != nil, mappingRepresentsCurrentSystemState(mapping) {
                midiOutput.sendFeedback(
                    mapping: mapping,
                    defaultDestination: defaultFeedbackDestination
                )
            }

            guard let led = mapping.led else { continue }
            switch led.behavior {
            case .solid:
                midiOutput.sendLEDState(
                    mapping: mapping,
                    on: true,
                    defaultDestination: defaultFeedbackDestination
                )
            case .blink:
                midiOutput.sendLEDState(
                    mapping: mapping,
                    on: false,
                    defaultDestination: defaultFeedbackDestination
                )
            case .toggleOnMute:
                let device = nonEmpty(mapping.action.device) ?? "default"
                let muted = AudioDeviceManager.shared.muteState(deviceName: device) ?? false
                midiOutput.sendLEDState(
                    mapping: mapping,
                    on: muted,
                    defaultDestination: defaultFeedbackDestination
                )
            }
        }
        lastFeedbackProfile = profile
        lastFeedbackDestination = defaultFeedbackDestination
    }

    private func mappingRepresentsCurrentSystemState(_ mapping: Mapping) -> Bool {
        let action = mapping.action
        let audio = AudioDeviceManager.shared

        switch action.type {
        case .setAudioOutput:
            guard let name = nonEmpty(action.device),
                  let target = audio.outputDevice(named: name),
                  let current = audio.defaultOutputDevice() else { return false }
            return target.id == current.id

        case .setAudioInput:
            guard let name = nonEmpty(action.device),
                  let target = audio.inputDevice(named: name),
                  let current = audio.defaultInputDevice() else { return false }
            return target.id == current.id

        case .switchAudioDevice:
            var matchedTarget = false
            if let outputName = nonEmpty(action.device) {
                guard let target = audio.outputDevice(named: outputName),
                      let current = audio.defaultOutputDevice(),
                      target.id == current.id else { return false }
                matchedTarget = true
            }
            if let inputName = nonEmpty(action.inputDevice) {
                guard let target = audio.inputDevice(named: inputName),
                      let current = audio.defaultInputDevice(),
                      target.id == current.id else { return false }
                matchedTarget = true
            }
            return matchedTarget

        case .setMicMute:
            let device = nonEmpty(action.device) ?? "default"
            return audio.muteState(deviceName: device) == (action.muted ?? true)

        case .openApp, .setVolume, .setInputVolume, .toggleMicMute, .switchProfile:
            return false
        }
    }

    private func clearLEDs(
        profile: Profile,
        defaultDestination: MIDIEndpointReference?
    ) {
        for mapping in profile.mappings where mapping.led != nil {
            midiOutput.sendLEDState(
                mapping: mapping,
                on: false,
                defaultDestination: defaultDestination
            )
        }
    }

    // MARK: - Activity and notification UI

    private func record(
        mapping: Mapping,
        source: MIDIEndpointReference,
        detail: String,
        succeeded: Bool
    ) {
        let mappingName = nonEmpty(mapping.description) ?? mapping.action.type.rawValue
        lastActivity = ActionActivity(
            sourceName: source.name,
            mappingName: mappingName,
            detail: detail,
            succeeded: succeeded
        )
        actionError = succeeded ? nil : detail
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func showNotification(title: String, body: String) {
        showToast("\(title): \(body)")
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()

        let window: NSWindow
        if let existing = toastWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 50),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.ignoresMouseEvents = true
            toastWindow = window
        }

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.addSubview(label)

        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        window.contentView = container
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrame(
                NSRect(x: frame.midX - 170, y: frame.maxY - 70, width: 340, height: 50),
                display: true
            )
        }

        window.alphaValue = 1
        window.orderFrontRegardless()

        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.toastWindow?.orderOut(nil)
        }
    }
}
