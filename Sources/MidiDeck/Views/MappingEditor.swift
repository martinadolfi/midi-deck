import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MappingEditor: View {
    @State var mapping: Mapping
    @ObservedObject var appState: AppState
    @ObservedObject private var configManager: ConfigManager
    @ObservedObject private var midiEngine: MIDIEngine
    let profileName: String
    var isNew = false
    var learnedInput: MIDIInputEvent?
    var onRelearn: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var outputDevices: [AudioDevice] = []
    @State private var inputDevices: [AudioDevice] = []
    @State private var showAdvanced = false
    @State private var saveError: String?

    init(
        mapping: Mapping,
        appState: AppState,
        profileName: String,
        isNew: Bool = false,
        learnedInput: MIDIInputEvent? = nil,
        onRelearn: (() -> Void)? = nil
    ) {
        _mapping = State(initialValue: mapping)
        self.appState = appState
        _configManager = ObservedObject(wrappedValue: appState.configManager)
        _midiEngine = ObservedObject(wrappedValue: appState.midiEngine)
        self.profileName = profileName
        self.isNew = isNew
        self.learnedInput = learnedInput
        self.onRelearn = onRelearn
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                triggerSection
                actionSection
                feedbackSection

                if let saveError {
                    Section("Could not save") {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if !draftErrors.isEmpty {
                    Section("Needs attention") {
                        ForEach(draftErrors) { issue in
                            Label(issue.message, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Mapping" : "Edit Mapping")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add Mapping" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draftErrors.isEmpty)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 590)
        .onAppear {
            refreshAudioDevices()
            normalizeActionForTrigger()
            normalizeTriggerFields()
            normalizeFeedbackForAction()
            clearLegacyDeviceIfFeedbackIsExplicit()
        }
        .onChange(of: mapping.trigger.type) { _, _ in
            normalizeActionForTrigger()
            normalizeTriggerFields()
            if mapping.trigger.type == .controlChange {
                mapping.led = nil
                mapping.feedback = nil
            }
        }
        .onChange(of: mapping.action.type) { _, _ in
            normalizeFeedbackForAction()
        }
    }

    private var identitySection: some View {
        Section {
            if let learnedInput {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Captured \(learnedInput.event.friendlyDescription)")
                            .font(.subheadline.weight(.medium))
                        Text("From \(learnedInput.source.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onRelearn {
                        Button("Try Again", action: onRelearn)
                            .controlSize(.small)
                    }
                }
            }

            TextField("Name", text: $mapping.description, prompt: Text("e.g. Pad 1 · Open Safari"))

            Picker("MIDI source", selection: sourceSelection) {
                Text("Follow global controller selection").tag("global")
                ForEach(availableSources) { source in
                    Text(endpointLabel(source, connected: midiEngine.connectedSources))
                        .tag(sourceTag(source))
                }
            }
            .pickerStyle(.menu)

            if mapping.device != nil, mapping.source == nil {
                Label("This version-1 mapping still filters by the legacy device name. Choosing a source above upgrades its input to a stable device ID.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let legacyDevice = mapping.device,
                      mapping.source != nil,
                      mapping.feedbackDestination == nil,
                      configManager.config.midi.feedbackDestination == nil {
                Label("Legacy feedback still routes to \(legacyDevice). Choose an explicit feedback output to complete the upgrade safely.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Mapping")
        } footer: {
            Text("A mapping-specific source is optional. Without one, the controller selection in the Controllers tab applies.")
        }
    }

    private var triggerSection: some View {
        Section("When this control moves") {
            Picker("Control type", selection: $mapping.trigger.type) {
                ForEach(Trigger.TriggerType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.systemImage).tag(type)
                }
            }
            .pickerStyle(.menu)

            Stepper(value: channelBinding, in: 1...16) {
                LabeledContent("Channel", value: "\(mapping.trigger.channel)")
            }

            if mapping.trigger.type == .controlChange {
                Stepper(value: controllerBinding, in: 0...127) {
                    LabeledContent("Controller (CC)", value: "\(mapping.trigger.controller ?? 0)")
                }
            } else {
                Stepper(value: noteBinding, in: 0...127) {
                    LabeledContent("Note", value: "\(mapping.trigger.note ?? 0)")
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Picker("Action", selection: $mapping.action.type) {
                ForEach(compatibleActionTypes, id: \.self) { type in
                    Label(type.displayName, systemImage: type.systemImage).tag(type)
                }
            }
            .pickerStyle(.menu)

            actionFields
        } header: {
            Text("Do this")
        } footer: {
            Text(actionHelp)
        }
    }

    @ViewBuilder
    private var actionFields: some View {
        switch mapping.action.type {
        case .openApp:
            HStack {
                TextField("Bundle ID", text: optionalBinding(\.bundleId))
                    .textContentType(.none)
                Button("Choose App…") { chooseApplication() }
            }

        case .setAudioOutput:
            audioPicker("Output device", selection: optionalBinding(\.device), devices: outputDevices, includesDefault: false)

        case .setAudioInput:
            audioPicker("Input device", selection: optionalBinding(\.device), devices: inputDevices, includesDefault: false)

        case .setVolume:
            audioPicker("Output device", selection: optionalBinding(\.device, defaultValue: "default"), devices: outputDevices, includesDefault: true)

        case .setInputVolume:
            audioPicker("Input device", selection: optionalBinding(\.device, defaultValue: "default"), devices: inputDevices, includesDefault: true)

        case .switchAudioDevice:
            audioPicker("Output device", selection: optionalBinding(\.device), devices: outputDevices, includesDefault: false)
            audioPicker("Input device", selection: optionalBinding(\.inputDevice), devices: inputDevices, includesDefault: false)

        case .toggleMicMute:
            audioPicker("Microphone", selection: optionalBinding(\.device, defaultValue: "default"), devices: inputDevices, includesDefault: true)

        case .setMicMute:
            audioPicker("Microphone", selection: optionalBinding(\.device, defaultValue: "default"), devices: inputDevices, includesDefault: true)
            Toggle("Muted", isOn: Binding(
                get: { mapping.action.muted ?? true },
                set: { mapping.action.muted = $0 }
            ))

        case .switchProfile:
            Picker("Profile", selection: optionalBinding(\.profile)) {
                Text("Choose a profile").tag("")
                ForEach(configManager.profileNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var feedbackSection: some View {
        Section {
            if mapping.trigger.type != .controlChange {
                Toggle("LED feedback", isOn: Binding(
                    get: { mapping.led != nil },
                    set: { enabled in
                        mapping.led = enabled ? LEDConfig(color: .blue, behavior: .solid) : nil
                    }
                ))

                if mapping.led != nil {
                    Picker("Color", selection: Binding(
                        get: { mapping.led?.color ?? .blue },
                        set: { mapping.led?.color = $0 }
                    )) {
                        ForEach(LEDConfig.LEDColor.allCases, id: \.self) { color in
                            HStack {
                                Circle().fill(color.swiftUIColor).frame(width: 9, height: 9)
                                Text(color.displayName)
                            }
                            .tag(color)
                        }
                    }
                    Picker("Behavior", selection: Binding(
                        get: { mapping.led?.behavior ?? .solid },
                        set: { mapping.led?.behavior = $0 }
                    )) {
                        ForEach(compatibleLEDBehaviors, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                }
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Picker("Feedback output", selection: feedbackDestinationSelection) {
                    Text("Use global feedback output").tag("global")
                    ForEach(availableDestinations) { destination in
                        Text(endpointLabel(destination, connected: midiEngine.connectedDestinations))
                            .tag(sourceTag(destination))
                    }
                }
                .pickerStyle(.menu)

                if mapping.trigger.type != .controlChange {
                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CC state feedback")
                                .font(.subheadline.weight(.medium))
                            Text("Send controller values after this action succeeds.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add Message", systemImage: "plus") {
                            if mapping.feedback == nil { mapping.feedback = [] }
                            mapping.feedback?.append(
                                MIDIFeedback(
                                    channel: mapping.trigger.channel,
                                    controller: 0,
                                    value: 127
                                )
                            )
                        }
                        .controlSize(.small)
                    }

                    ForEach(feedbackIndices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Message \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Button(role: .destructive) {
                                    removeFeedback(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove feedback message \(index + 1)")
                                .help("Remove this CC feedback message")
                            }

                            HStack(spacing: 16) {
                                feedbackNumberControl(
                                    "Channel",
                                    value: feedbackBinding(at: index, \.channel),
                                    range: 1...16
                                )
                                feedbackNumberControl(
                                    "Controller",
                                    value: feedbackBinding(at: index, \.controller),
                                    range: 0...127
                                )
                                feedbackNumberControl(
                                    "Value",
                                    value: feedbackBinding(at: index, \.value),
                                    range: 0...127
                                )
                            }
                        }
                        .padding(9)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if mapping.action.type == .switchAudioDevice {
                    TextField("On-screen message (optional)", text: optionalBinding(\.notify))
                }

                HStack {
                    Text("Mapping ID")
                    Spacer()
                    Text(mapping.id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Controller feedback")
        } footer: {
            if midiEngine.connectedDestinations.count > 1,
               mapping.feedbackDestination == nil,
               configManager.config.midi.feedbackDestination == nil {
                Text("Choose a global feedback output in Controllers to avoid sending to the wrong device.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var compatibleActionTypes: [Action.ActionType] {
        Action.ActionType.allCases.filter { $0.isCompatible(with: mapping.trigger.type) }
    }

    private var compatibleLEDBehaviors: [LEDConfig.LEDBehavior] {
        supportsMuteFollowing ? LEDConfig.LEDBehavior.allCases : [.solid, .blink]
    }

    private var supportsMuteFollowing: Bool {
        mapping.action.type == .toggleMicMute || mapping.action.type == .setMicMute
    }

    private var actionHelp: String {
        switch mapping.action.type {
        case .openApp: return "Launches the app, focuses it, or cycles its visible windows when it is already active."
        case .setAudioOutput: return "Makes this the macOS default output."
        case .setAudioInput: return "Makes this the macOS default input."
        case .setVolume: return "Maps the full fader or knob range to output volume."
        case .setInputVolume: return "Maps the full fader or knob range to microphone input volume."
        case .switchAudioDevice: return "Changes the output and input together."
        case .toggleMicMute: return "Flips the current microphone mute state."
        case .setMicMute: return "Always applies the selected mute state."
        case .switchProfile: return "Activates another set of mappings."
        }
    }

    private var draftErrors: [ConfigurationIssue] {
        var issues = ConfigurationValidator.mappingIssues(
            mapping,
            configuration: configManager.config
        ).filter { $0.severity == .error }

        let otherMappings = configManager.config.profiles[profileName]?.mappings.filter { $0.id != mapping.id } ?? []
        if otherMappings.contains(where: { other in
            other.trigger == mapping.trigger && sourceIdentity(other) == sourceIdentity(mapping)
        }) {
            issues.append(ConfigurationIssue(
                severity: .error,
                message: "Another mapping in this profile uses the same source and trigger.",
                location: nil
            ))
        }
        return issues
    }

    private var availableSources: [MIDIEndpointReference] {
        mergedEndpoints(midiEngine.connectedSources, mapping.source.map { [$0] } ?? [])
    }

    private var availableDestinations: [MIDIEndpointReference] {
        mergedEndpoints(midiEngine.connectedDestinations, mapping.feedbackDestination.map { [$0] } ?? [])
    }

    private var sourceSelection: Binding<String> {
        Binding(
            get: { mapping.source.map(sourceTag) ?? "global" },
            set: { value in
                if value == "global" {
                    mapping.source = nil
                } else if let endpoint = availableSources.first(where: { sourceTag($0) == value }) {
                    mapping.source = endpoint
                    clearLegacyDeviceIfFeedbackIsExplicit()
                }
            }
        )
    }

    private var feedbackDestinationSelection: Binding<String> {
        Binding(
            get: { mapping.feedbackDestination.map(sourceTag) ?? "global" },
            set: { value in
                mapping.feedbackDestination = value == "global"
                    ? nil
                    : availableDestinations.first(where: { sourceTag($0) == value })
                clearLegacyDeviceIfFeedbackIsExplicit()
            }
        )
    }

    private var channelBinding: Binding<Int> {
        Binding(get: { Int(mapping.trigger.channel) }, set: { mapping.trigger.channel = UInt8($0) })
    }

    private var noteBinding: Binding<Int> {
        Binding(get: { Int(mapping.trigger.note ?? 0) }, set: { mapping.trigger.note = UInt8($0) })
    }

    private var controllerBinding: Binding<Int> {
        Binding(get: { Int(mapping.trigger.controller ?? 0) }, set: { mapping.trigger.controller = UInt8($0) })
    }

    private var feedbackIndices: [Int] {
        Array((mapping.feedback ?? []).indices)
    }

    private func feedbackBinding(
        at index: Int,
        _ keyPath: WritableKeyPath<MIDIFeedback, UInt8>
    ) -> Binding<Int> {
        Binding(
            get: {
                guard let feedback = mapping.feedback, feedback.indices.contains(index) else { return 0 }
                return Int(feedback[index][keyPath: keyPath])
            },
            set: { value in
                guard mapping.feedback?.indices.contains(index) == true else { return }
                mapping.feedback?[index][keyPath: keyPath] = UInt8(value)
            }
        )
    }

    private func feedbackNumberControl(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
            }
            .accessibilityLabel(title)
            .accessibilityValue("\(value.wrappedValue)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removeFeedback(at index: Int) {
        guard mapping.feedback?.indices.contains(index) == true else { return }
        mapping.feedback?.remove(at: index)
        if mapping.feedback?.isEmpty == true {
            mapping.feedback = nil
        }
    }

    private func optionalBinding(
        _ keyPath: WritableKeyPath<Action, String?>,
        defaultValue: String = ""
    ) -> Binding<String> {
        Binding(
            get: { mapping.action[keyPath: keyPath] ?? defaultValue },
            set: { mapping.action[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func audioPicker(
        _ title: String,
        selection: Binding<String>,
        devices: [AudioDevice],
        includesDefault: Bool
    ) -> some View {
        let names = devices.map(\.name)
        let current = selection.wrappedValue
        return Picker(title, selection: selection) {
            if includesDefault {
                Text("System default").tag("default")
            } else {
                Text("Choose a device").tag("")
            }
            if !current.isEmpty, current != "default", !names.contains(current) {
                Text("\(current) — unavailable").tag(current)
            }
            ForEach(devices, id: \.uid) { device in
                Text(device.name).tag(device.name)
            }
        }
        .pickerStyle(.menu)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        mapping.action.bundleId = bundleID
        if mapping.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mapping.description = "Open \(url.deletingPathExtension().lastPathComponent)"
        }
    }

    private func refreshAudioDevices() {
        outputDevices = AudioDeviceManager.shared.outputDevices()
        inputDevices = AudioDeviceManager.shared.inputDevices()
    }

    private func normalizeActionForTrigger() {
        guard !mapping.action.type.isCompatible(with: mapping.trigger.type) else { return }
        mapping.action = mapping.trigger.type == .controlChange
            ? Action(type: .setVolume, device: "default")
            : Action(type: .openApp)
    }

    private func normalizeTriggerFields() {
        switch mapping.trigger.type {
        case .noteOn, .noteOff:
            if mapping.trigger.note == nil {
                mapping.trigger.note = 0
            }
        case .controlChange:
            if mapping.trigger.controller == nil {
                mapping.trigger.controller = 0
            }
        }
    }

    private func normalizeFeedbackForAction() {
        if !supportsMuteFollowing, mapping.led?.behavior == .toggleOnMute {
            mapping.led?.behavior = .solid
        }
    }

    private func clearLegacyDeviceIfFeedbackIsExplicit() {
        guard mapping.source != nil,
              mapping.feedbackDestination != nil || configManager.config.midi.feedbackDestination != nil else {
            return
        }
        mapping.device = nil
    }

    private func save() {
        saveError = nil
        let succeeded = isNew
            ? configManager.addMapping(mapping, toProfile: profileName)
            : configManager.updateMapping(mapping, inProfile: profileName)
        if succeeded {
            dismiss()
        } else {
            saveError = configManager.configError ?? "The mapping could not be saved."
        }
    }

    private func sourceIdentity(_ mapping: Mapping) -> String {
        if let source = mapping.source { return "id:\(source.uniqueID)" }
        if let legacy = mapping.device { return "legacy:\(legacy.lowercased())" }
        return "global"
    }

    private func sourceTag(_ endpoint: MIDIEndpointReference) -> String {
        "endpoint:\(endpoint.uniqueID)"
    }

    private func mergedEndpoints(
        _ connected: [MIDIEndpointReference],
        _ saved: [MIDIEndpointReference]
    ) -> [MIDIEndpointReference] {
        var byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.uniqueID, $0) })
        for endpoint in connected { byID[endpoint.uniqueID] = endpoint }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func endpointLabel(
        _ endpoint: MIDIEndpointReference,
        connected: [MIDIEndpointReference]
    ) -> String {
        let isConnected = connected.contains { $0.uniqueID == endpoint.uniqueID }
        let duplicateCount = connected.filter { $0.name == endpoint.name }.count
        let name = duplicateCount > 1 ? "\(endpoint.name) · \(endpoint.uniqueID)" : endpoint.name
        return isConnected ? name : "\(name) — disconnected"
    }
}
