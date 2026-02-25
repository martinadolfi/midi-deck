import AppKit
import Foundation

final class ActionExecutor {
    let configManager: ConfigManager
    let midiOutput: MIDIOutputManager

    private var latestCC: [String: (mapping: Mapping, value: UInt8)] = [:]
    private var appliedCC: [String: UInt8] = [:]
    private var ccTimer: DispatchSourceTimer?
    private var toastWindow: NSWindow?
    private var toastDismissWork: DispatchWorkItem?

    init(configManager: ConfigManager, midiOutput: MIDIOutputManager) {
        self.configManager = configManager
        self.midiOutput = midiOutput
        startCCTimer()
    }

    deinit {
        ccTimer?.cancel()
    }

    // MARK: - Toast Notification

    private func showNotification(title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            self?.showToast("\(title): \(body)")
        }
    }

    private func showToast(_ message: String) {
        toastDismissWork?.cancel()

        // Reuse or create toast window
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

        // Build content
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

        // Position top-center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 170
            let y = screenFrame.maxY - 70
            window.setFrame(NSRect(x: x, y: y, width: 340, height: 50), display: true)
        }

        window.alphaValue = 1
        window.orderFrontRegardless()

        // Auto-dismiss after 2 seconds
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self?.toastWindow?.animator().alphaValue = 0
            } completionHandler: {
                self?.toastWindow?.orderOut(nil)
            }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - CC Timer

    private func startCCTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            self?.flushCC()
        }
        timer.resume()
        ccTimer = timer
    }

    private func flushCC() {
        for (key, pending) in latestCC {
            if appliedCC[key] != pending.value {
                appliedCC[key] = pending.value
                log("[Action] \(pending.mapping.description) → val:\(pending.value)")
                executeCC(action: pending.mapping.action, value: pending.value)
            }
        }
    }

    // MARK: - Event Handling

    func handle(event: MIDIEvent) {
        guard let profile = configManager.activeProfile else { return }

        for mapping in profile.mappings {
            if mapping.trigger.matches(event) {
                if case .controlChange(_, _, let value) = event {
                    let key = mapping.trigger.matchKey
                    latestCC[key] = (mapping: mapping, value: value)
                } else {
                    log("[Action] Matched: \(mapping.description) → \(mapping.action.type.rawValue)")
                    execute(action: mapping.action, event: event)
                    sendFeedback(mapping: mapping, event: event)
                }
                return
            }
        }

        log("[MIDI] Unmatched: \(event.description)")
    }

    // MARK: - CC Execution (called from timer)

    private func executeCC(action: Action, value: UInt8) {
        switch action.type {
        case .setVolume:
            guard let device = action.device else { return }
            AudioActions.setVolume(deviceName: device, ccValue: value)
        case .setInputVolume:
            guard let device = action.device else { return }
            AudioActions.setInputVolume(deviceName: device, ccValue: value)
        default:
            break
        }
    }

    // MARK: - Action Execution (non-CC)

    private func execute(action: Action, event: MIDIEvent) {
        switch action.type {
        case .openApp:
            guard let bundleId = action.bundleId else {
                log("[Action] openApp missing bundleId")
                return
            }
            AppActions.openApp(bundleId: bundleId)

        case .setAudioOutput:
            guard let device = action.device else {
                log("[Action] setAudioOutput missing device")
                return
            }
            AudioActions.setAudioOutput(deviceName: device)

        case .setAudioInput:
            guard let device = action.device else {
                log("[Action] setAudioInput missing device")
                return
            }
            AudioActions.setAudioInput(deviceName: device)

        case .switchAudioDevice:
            AudioActions.switchAudioDevice(outputName: action.device, inputName: action.inputDevice)
            if let msg = action.notify {
                showNotification(title: "MidiDeck", body: msg)
            }

        case .setVolume, .setInputVolume:
            break

        case .toggleMicMute:
            let device = action.device ?? "default"
            let newState = AudioActions.toggleMicMute(deviceName: device)
            if let muted = newState {
                handleMuteLED(event: event, muted: muted)
            }

        case .setMicMute:
            let device = action.device ?? "default"
            let muted = action.muted ?? true
            AudioActions.setMicMute(deviceName: device, muted: muted)

        case .switchProfile:
            guard let profileName = action.profile else {
                log("[Action] switchProfile missing profile name")
                return
            }
            configManager.switchProfile(profileName)
            if let newProfile = configManager.activeProfile {
                midiOutput.sendAllLEDStates(profile: newProfile)
            }
        }
    }

    // MARK: - Feedback (LED + CC)

    private func sendFeedback(mapping: Mapping, event: MIDIEvent) {
        // Delay feedback 200ms so the controller finishes processing the button press first
        let midiOut = midiOutput
        let m = mapping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if m.feedback != nil {
                midiOut.sendFeedback(mapping: m)
            }
            if let led = m.led {
                switch led.behavior {
                case .solid, .blink:
                    midiOut.sendLEDState(mapping: m, on: true)
                case .toggleOnMute:
                    break
                }
            }
        }
    }

    private func handleMuteLED(event: MIDIEvent, muted: Bool) {
        guard let profile = configManager.activeProfile else { return }
        for mapping in profile.mappings {
            if mapping.trigger.matches(event), let led = mapping.led {
                if led.behavior == .toggleOnMute {
                    midiOutput.sendLEDState(mapping: mapping, on: muted)
                }
                break
            }
        }
    }

    func sendInitialLEDStates() {
        guard let profile = configManager.activeProfile else { return }
        midiOutput.sendAllLEDStates(profile: profile)
    }
}
