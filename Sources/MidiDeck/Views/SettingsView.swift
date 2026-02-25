import SwiftUI

struct SettingsView: View {
    @ObservedObject var configManager: ConfigManager
    @State private var selectedProfile: String = "default"
    @State private var editingMapping: Mapping?
    @State private var showingAddMapping = false
    @State private var showingMIDILearn = false
    @ObservedObject var midiEngine: MIDIEngine

    var body: some View {
        HSplitView {
            // Left: Profile list
            VStack(alignment: .leading) {
                Text("Profiles")
                    .font(.headline)
                    .padding(.bottom, 4)

                List(configManager.profileNames, id: \.self, selection: $selectedProfile) { name in
                    HStack {
                        Text(name)
                        if name == configManager.config.activeProfile {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .listStyle(.sidebar)

                HStack {
                    Button(action: addProfile) {
                        Image(systemName: "plus")
                    }
                    Button(action: deleteSelectedProfile) {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedProfile == "default")
                }
                .padding(.top, 4)
            }
            .frame(minWidth: 150, maxWidth: 200)
            .padding()

            // Right: Mappings for selected profile
            VStack(alignment: .leading) {
                HStack {
                    Text("Mappings — \(selectedProfile)")
                        .font(.headline)
                    Spacer()
                    Button("MIDI Learn") {
                        showingMIDILearn = true
                    }
                    Button(action: { showingAddMapping = true }) {
                        Image(systemName: "plus")
                    }
                }
                .padding(.bottom, 4)

                if let profile = configManager.config.profiles[selectedProfile] {
                    if profile.mappings.isEmpty {
                        Text("No mappings configured.\nClick + or use MIDI Learn to add one.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(profile.mappings) { mapping in
                                MappingRow(mapping: mapping)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingMapping = mapping
                                    }
                                    .contextMenu {
                                        Button("Delete", role: .destructive) {
                                            configManager.removeMapping(id: mapping.id, fromProfile: selectedProfile)
                                        }
                                    }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    let mapping = profile.mappings[index]
                                    configManager.removeMapping(id: mapping.id, fromProfile: selectedProfile)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 400)
            .padding()
        }
        .frame(minWidth: 650, minHeight: 400)
        .sheet(item: $editingMapping) { mapping in
            MappingEditor(mapping: mapping, configManager: configManager, profileName: selectedProfile)
        }
        .sheet(isPresented: $showingAddMapping) {
            MappingEditor(
                mapping: Mapping(
                    trigger: Trigger(type: .noteOn, channel: 10, note: 36),
                    action: Action(type: .openApp)
                ),
                configManager: configManager,
                profileName: selectedProfile,
                isNew: true
            )
        }
        .sheet(isPresented: $showingMIDILearn) {
            MIDILearnView(
                configManager: configManager,
                midiEngine: midiEngine,
                profileName: selectedProfile
            )
        }
        .onAppear {
            selectedProfile = configManager.config.activeProfile
        }
    }

    private func addProfile() {
        let name = "profile-\(configManager.profileNames.count + 1)"
        configManager.config.profiles[name] = Profile()
        selectedProfile = name
    }

    private func deleteSelectedProfile() {
        guard selectedProfile != "default" else { return }
        configManager.config.profiles.removeValue(forKey: selectedProfile)
        if configManager.config.activeProfile == selectedProfile {
            configManager.config.activeProfile = "default"
        }
        selectedProfile = "default"
    }
}

// MARK: - Mapping Row

struct MappingRow: View {
    let mapping: Mapping

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.description.isEmpty ? triggerDescription : mapping.description)
                    .font(.body)
                Text(actionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let led = mapping.led {
                Circle()
                    .fill(ledSwiftUIColor(led.color))
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.vertical, 2)
    }

    private var triggerDescription: String {
        let t = mapping.trigger
        switch t.type {
        case .noteOn: return "Note On ch:\(t.channel) note:\(t.note ?? 0)"
        case .noteOff: return "Note Off ch:\(t.channel) note:\(t.note ?? 0)"
        case .controlChange: return "CC ch:\(t.channel) cc:\(t.controller ?? 0)"
        }
    }

    private var actionDescription: String {
        let a = mapping.action
        switch a.type {
        case .openApp: return "Open \(a.bundleId ?? "?")"
        case .setAudioOutput: return "Output → \(a.device ?? "?")"
        case .setAudioInput: return "Input → \(a.device ?? "?")"
        case .setVolume: return "Volume → \(a.device ?? "default")"
        case .setInputVolume: return "Input volume → \(a.device ?? "default")"
        case .switchAudioDevice: return "Audio → \(a.device ?? "?") / \(a.inputDevice ?? "?")"
        case .toggleMicMute: return "Toggle mic mute (\(a.device ?? "default"))"
        case .setMicMute: return "Set mic \(a.muted == true ? "muted" : "unmuted")"
        case .switchProfile: return "Switch to profile: \(a.profile ?? "?")"
        }
    }

    private func ledSwiftUIColor(_ color: LEDConfig.LEDColor) -> Color {
        switch color {
        case .off: return .gray
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .blue: return .blue
        case .magenta: return .purple
        case .cyan: return .cyan
        case .white: return .white
        }
    }
}

// MARK: - Mapping Editor

struct MappingEditor: View {
    @State var mapping: Mapping
    @ObservedObject var configManager: ConfigManager
    let profileName: String
    var isNew: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Description") {
                TextField("Description", text: $mapping.description)
            }

            Section("Trigger") {
                Picker("Type", selection: $mapping.trigger.type) {
                    ForEach(Trigger.TriggerType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                HStack {
                    Text("Channel")
                    TextField("Channel", value: $mapping.trigger.channel, format: .number)
                        .frame(width: 60)
                }
                if mapping.trigger.type == .controlChange {
                    HStack {
                        Text("Controller")
                        TextField("CC#", value: Binding(
                            get: { mapping.trigger.controller ?? 0 },
                            set: { mapping.trigger.controller = $0 }
                        ), format: .number)
                        .frame(width: 60)
                    }
                } else {
                    HStack {
                        Text("Note")
                        TextField("Note", value: Binding(
                            get: { mapping.trigger.note ?? 0 },
                            set: { mapping.trigger.note = $0 }
                        ), format: .number)
                        .frame(width: 60)
                    }
                }
            }

            Section("Action") {
                Picker("Type", selection: $mapping.action.type) {
                    ForEach(Action.ActionType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }

                switch mapping.action.type {
                case .openApp:
                    TextField("Bundle ID", text: Binding(
                        get: { mapping.action.bundleId ?? "" },
                        set: { mapping.action.bundleId = $0.isEmpty ? nil : $0 }
                    ))
                case .setAudioOutput, .setAudioInput, .setVolume, .setInputVolume:
                    TextField("Device name", text: Binding(
                        get: { mapping.action.device ?? "default" },
                        set: { mapping.action.device = $0 }
                    ))
                case .switchAudioDevice:
                    TextField("Output device", text: Binding(
                        get: { mapping.action.device ?? "" },
                        set: { mapping.action.device = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Input device", text: Binding(
                        get: { mapping.action.inputDevice ?? "" },
                        set: { mapping.action.inputDevice = $0.isEmpty ? nil : $0 }
                    ))
                case .toggleMicMute:
                    TextField("Device name", text: Binding(
                        get: { mapping.action.device ?? "default" },
                        set: { mapping.action.device = $0 }
                    ))
                case .setMicMute:
                    TextField("Device name", text: Binding(
                        get: { mapping.action.device ?? "default" },
                        set: { mapping.action.device = $0 }
                    ))
                    Toggle("Muted", isOn: Binding(
                        get: { mapping.action.muted ?? true },
                        set: { mapping.action.muted = $0 }
                    ))
                case .switchProfile:
                    Picker("Profile", selection: Binding(
                        get: { mapping.action.profile ?? "" },
                        set: { mapping.action.profile = $0 }
                    )) {
                        ForEach(configManager.profileNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            }

            Section("LED") {
                Toggle("Enable LED", isOn: Binding(
                    get: { mapping.led != nil },
                    set: { enabled in
                        if enabled {
                            mapping.led = LEDConfig(color: .red, behavior: .solid)
                        } else {
                            mapping.led = nil
                        }
                    }
                ))

                if mapping.led != nil {
                    Picker("Color", selection: Binding(
                        get: { mapping.led?.color ?? .off },
                        set: { mapping.led?.color = $0 }
                    )) {
                        ForEach(LEDConfig.LEDColor.allCases, id: \.self) { color in
                            Text(color.rawValue).tag(color)
                        }
                    }

                    Picker("Behavior", selection: Binding(
                        get: { mapping.led?.behavior ?? .solid },
                        set: { mapping.led?.behavior = $0 }
                    )) {
                        ForEach(LEDConfig.LEDBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.rawValue).tag(behavior)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 350)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    if isNew {
                        configManager.addMapping(mapping, toProfile: profileName)
                    } else {
                        configManager.updateMapping(mapping, inProfile: profileName)
                    }
                    dismiss()
                }
            }
        }
    }
}
