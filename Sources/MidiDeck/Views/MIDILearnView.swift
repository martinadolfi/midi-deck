import AppKit
import SwiftUI

struct MIDILearnView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var midiEngine: MIDIEngine
    let profileName: String

    @Environment(\.dismiss) private var dismiss
    @State private var capturedInput: MIDIInputEvent?
    @State private var draftMapping: Mapping?
    @State private var listenTask: Task<Void, Never>?

    init(appState: AppState, profileName: String) {
        self.appState = appState
        _midiEngine = ObservedObject(wrappedValue: appState.midiEngine)
        self.profileName = profileName
    }

    var body: some View {
        Group {
            if let capturedInput, let draftMapping {
                MappingEditor(
                    mapping: draftMapping,
                    appState: appState,
                    profileName: profileName,
                    isNew: true,
                    learnedInput: capturedInput,
                    onRelearn: resetAndListen
                )
            } else {
                listeningView
            }
        }
        .onAppear {
            appState.beginLearning()
            startListening()
        }
        .onDisappear {
            listenTask?.cancel()
            appState.endLearning()
        }
    }

    private var listeningView: some View {
        VStack(spacing: 22) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 108, height: 108)
                if midiEngine.initializationError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.red)
                } else if midiEngine.connectedSources.isEmpty {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 42))
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(listeningTitle)
                    .font(.title2.weight(.semibold))
                Text(listeningDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }

            if let initializationError = midiEngine.initializationError {
                VStack(spacing: 10) {
                    Text(initializationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            retryMIDI()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Open Audio MIDI Setup") {
                            openAudioMIDISetup()
                        }
                    }
                }
                .frame(maxWidth: 420)
            } else if !midiEngine.connectedSources.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Listening to \(midiEngine.connectedSources.count == 1 ? midiEngine.connectedSources[0].name : "all \(midiEngine.connectedSources.count) connected controllers")…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    listenTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Profile: \(profileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(26)
        .frame(minWidth: 520, minHeight: 440)
    }

    private var listeningTitle: String {
        if midiEngine.initializationError != nil { return "MIDI could not start" }
        if midiEngine.connectedSources.isEmpty { return "Connect a MIDI controller" }
        return "Move the control you want to map"
    }

    private var listeningDescription: String {
        if midiEngine.initializationError != nil {
            return "Retry the MIDI connection. If it still fails, inspect your devices in Audio MIDI Setup."
        }
        if midiEngine.connectedSources.isEmpty {
            return "MidiDeck will start listening automatically when a controller appears."
        }
        return "Press a pad or key, or move a knob or fader. Normal actions are paused while learning."
    }

    private func startListening() {
        listenTask?.cancel()
        listenTask = Task { [midiEngine] in
            for await input in midiEngine.events(bufferLimit: 32) {
                guard !Task.isCancelled else { return }
                switch input.event {
                case .noteOn, .controlChange:
                    capturedInput = input
                    draftMapping = makeDraft(from: input)
                    return
                case .noteOff:
                    continue
                }
            }
        }
    }

    private func resetAndListen() {
        capturedInput = nil
        draftMapping = nil
        startListening()
    }

    private func retryMIDI() {
        midiEngine.start()
        startListening()
    }

    private func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    private func makeDraft(from input: MIDIInputEvent) -> Mapping {
        let trigger: Trigger
        let action: Action
        let led: LEDConfig?

        switch input.event {
        case .noteOn(let channel, let note, _):
            trigger = Trigger(type: .noteOn, channel: channel, note: note)
            action = Action(type: .openApp)
            led = LEDConfig(color: .blue, behavior: .solid)
        case .controlChange(let channel, let controller, _):
            trigger = Trigger(type: .controlChange, channel: channel, controller: controller)
            action = Action(type: .setVolume, device: "default")
            led = nil
        case .noteOff(let channel, let note, _):
            trigger = Trigger(type: .noteOff, channel: channel, note: note)
            action = Action(type: .openApp)
            led = LEDConfig(color: .blue, behavior: .solid)
        }

        return Mapping(
            description: "",
            source: input.source,
            trigger: trigger,
            action: action,
            led: led
        )
    }
}
