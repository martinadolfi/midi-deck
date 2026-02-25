import SwiftUI

struct MIDILearnView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var midiEngine: MIDIEngine
    let profileName: String
    @Environment(\.dismiss) private var dismiss

    @State private var capturedEvent: MIDIEvent?
    @State private var listenTask: Task<Void, Never>?
    @State private var isListening = true
    @State private var selectedActionType: Action.ActionType = .openApp
    @State private var actionBundleId: String = ""
    @State private var actionDevice: String = "default"
    @State private var actionProfile: String = ""
    @State private var description: String = ""
    @State private var ledEnabled: Bool = true
    @State private var ledColor: LEDConfig.LEDColor = .red

    var body: some View {
        VStack(spacing: 16) {
            Text("MIDI Learn")
                .font(.title2)

            // Step 1: Capture
            GroupBox("Step 1: Press a pad or move a fader") {
                if isListening {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Listening for MIDI input...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if let event = capturedEvent {
                    VStack(spacing: 4) {
                        Text("Captured:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.description)
                            .font(.system(.body, design: .monospaced))
                        Button("Re-listen") {
                            capturedEvent = nil
                            isListening = true
                            startListening()
                        }
                        .controlSize(.small)
                    }
                    .padding()
                }
            }

            // Step 2: Assign action
            if capturedEvent != nil {
                GroupBox("Step 2: Assign an action") {
                    Form {
                        TextField("Description", text: $description)

                        Picker("Action", selection: $selectedActionType) {
                            ForEach(Action.ActionType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }

                        switch selectedActionType {
                        case .openApp:
                            TextField("Bundle ID", text: $actionBundleId)
                        case .setAudioOutput, .setAudioInput, .setVolume, .setInputVolume, .switchAudioDevice, .toggleMicMute, .setMicMute:
                            TextField("Device name", text: $actionDevice)
                        case .switchProfile:
                            Picker("Profile", selection: $actionProfile) {
                                ForEach(configManager.profileNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        }

                        Toggle("Enable LED", isOn: $ledEnabled)
                        if ledEnabled {
                            Picker("LED Color", selection: $ledColor) {
                                ForEach(LEDConfig.LEDColor.allCases, id: \.self) { color in
                                    Text(color.rawValue).tag(color)
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }

            // Buttons
            HStack {
                Button("Cancel") {
                    listenTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if capturedEvent != nil {
                    Button("Add Mapping") {
                        addMapping()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isActionValid)
                }
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 350)
        .onAppear {
            startListening()
        }
        .onDisappear {
            listenTask?.cancel()
        }
    }

    private var isActionValid: Bool {
        switch selectedActionType {
        case .openApp: return !actionBundleId.isEmpty
        case .switchProfile: return !actionProfile.isEmpty
        default: return true
        }
    }

    private func startListening() {
        listenTask?.cancel()
        listenTask = Task {
            for await event in midiEngine.eventStream {
                if Task.isCancelled { break }
                // Only capture noteOn and CC events
                switch event {
                case .noteOn, .controlChange:
                    await MainActor.run {
                        capturedEvent = event
                        isListening = false
                        prefillFromEvent(event)
                    }
                    return
                default:
                    continue
                }
            }
        }
    }

    private func prefillFromEvent(_ event: MIDIEvent) {
        switch event {
        case .controlChange:
            selectedActionType = .setVolume
        default:
            break
        }
    }

    private func addMapping() {
        guard let event = capturedEvent else { return }

        let trigger: Trigger
        switch event {
        case .noteOn(let ch, let note, _):
            trigger = Trigger(type: .noteOn, channel: ch, note: note)
        case .controlChange(let ch, let cc, _):
            trigger = Trigger(type: .controlChange, channel: ch, controller: cc)
        default:
            return
        }

        var action = Action(type: selectedActionType)
        switch selectedActionType {
        case .openApp:
            action.bundleId = actionBundleId
        case .setAudioOutput, .setAudioInput, .setVolume, .setInputVolume, .switchAudioDevice, .toggleMicMute, .setMicMute:
            action.device = actionDevice
        case .switchProfile:
            action.profile = actionProfile
        }

        let led: LEDConfig? = ledEnabled ? LEDConfig(color: ledColor, behavior: .solid) : nil

        let mapping = Mapping(
            description: description,
            trigger: trigger,
            action: action,
            led: led
        )

        configManager.addMapping(mapping, toProfile: profileName)
    }
}
