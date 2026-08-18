import AppKit
import SwiftUI

struct ControllerSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var configManager: ConfigManager
    @ObservedObject private var midiEngine: MIDIEngine

    init(appState: AppState) {
        self.appState = appState
        _configManager = ObservedObject(wrappedValue: appState.configManager)
        _midiEngine = ObservedObject(wrappedValue: appState.midiEngine)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Controllers")
                        .font(.title2.weight(.semibold))
                    Text("Choose exactly where commands come from and where feedback goes.")
                        .foregroundStyle(.secondary)
                }

                inputRoutingCard
                feedbackCard
                liveMonitorCard
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var inputRoutingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Input mode", selection: inputModeBinding) {
                    Text("Automatic").tag(MIDIInputMode.automatic)
                    Text("Choose one").tag(MIDIInputMode.selected)
                    Text("Any controller").tag(MIDIInputMode.all)
                }
                .pickerStyle(.segmented)

                Text(inputModeExplanation)
                    .font(.caption)
                    .foregroundStyle(inputModeColor)

                if let initializationError = midiEngine.initializationError {
                    ConfigurationBanner(
                        title: "MIDI could not start",
                        message: initializationError,
                        color: .red,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                } else if needsControllerChoice {
                    ConfigurationBanner(
                        title: "Choose a controller",
                        message: "MidiDeck is waiting instead of merging identical notes and CCs from \(midiEngine.connectedSources.count) devices.",
                        color: .orange,
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                } else if configManager.config.midi.inputMode == .all,
                          midiEngine.connectedSources.count > 1 {
                    ConfigurationBanner(
                        title: "Collision protection is off",
                        message: "Any connected controller can trigger an unscoped mapping. Choose one controller unless this is intentional.",
                        color: .orange,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                Divider()

                if availableSources.isEmpty {
                    ContentUnavailableView {
                        Label(
                            midiEngine.initializationError == nil ? "No MIDI controllers" : "MIDI unavailable",
                            systemImage: midiEngine.initializationError == nil ? "cable.connector.slash" : "exclamationmark.triangle"
                        )
                    } description: {
                        Text(midiEngine.initializationError == nil
                            ? "Connect a USB or Bluetooth MIDI controller, then it will appear here automatically."
                            : "Quit and reopen MidiDeck. If the problem continues, check Audio MIDI Setup.")
                    } actions: {
                        Button("Open Audio MIDI Setup") { openAudioMIDISetup() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(availableSources.enumerated()), id: \.element.id) { index, source in
                            controllerRow(source)
                            if index < availableSources.count - 1 { Divider() }
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            Label("Respond to MIDI input", systemImage: "pianokeys")
                .font(.headline)
        }
    }

    private var feedbackCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Send LEDs and feedback to", selection: feedbackSelection) {
                    Text(midiEngine.connectedDestinations.count == 1 ? "The only connected output" : "No explicit output")
                        .tag("implicit")
                    ForEach(availableDestinations) { destination in
                        Text(endpointLabel(destination, connected: midiEngine.connectedDestinations))
                            .tag(endpointTag(destination))
                    }
                }
                .pickerStyle(.menu)

                if midiEngine.connectedDestinations.count > 1,
                   configManager.config.midi.feedbackDestination == nil {
                    Label("Feedback is paused until you choose an output, so MidiDeck cannot light the wrong controller.", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let selected = configManager.config.midi.feedbackDestination,
                          !midiEngine.connectedDestinations.contains(where: { $0.uniqueID == selected.uniqueID }) {
                    Label("Waiting for \(selected.name). MidiDeck will not fall back to another output.", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("This is the default for mappings with LED or CC feedback. A mapping can override it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Refresh LEDs") {
                        appState.actionExecutor.sendInitialLEDStates()
                    }
                    .disabled(midiEngine.connectedDestinations.isEmpty)
                    Spacer()
                    Button("Open Audio MIDI Setup") { openAudioMIDISetup() }
                }
                .controlSize(.small)
            }
            .padding(6)
        } label: {
            Label("Controller feedback", systemImage: "lightbulb")
                .font(.headline)
        }
    }

    private var liveMonitorCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: midiEngine.lastEvent == nil ? "waveform.slash" : "waveform")
                    .font(.title2)
                    .foregroundStyle(midiEngine.lastEvent == nil ? Color.secondary : Color.green)
                    .frame(width: 32)
                if let input = midiEngine.lastEvent {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(input.event.friendlyDescription)
                            .font(.body.weight(.medium))
                        Text("From \(input.source.name) · ID \(input.source.uniqueID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Waiting for MIDI input")
                            .font(.body.weight(.medium))
                        Text("Press a pad or move a control to verify the connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(8)
        } label: {
            Label("Live input monitor", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
        }
    }

    private func controllerRow(_ source: MIDIEndpointReference) -> some View {
        let connected = midiEngine.connectedSources.contains { $0.uniqueID == source.uniqueID }
        let selected = configManager.config.midi.inputMode == .selected
            && configManager.config.midi.inputSources.contains { $0.uniqueID == source.uniqueID }

        return Button {
            _ = configManager.selectExclusiveInput(source)
            appState.actionExecutor.clearPendingControls()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Image(systemName: "pianokeys")
                    .font(.title3)
                    .foregroundStyle(connected ? .primary : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disambiguatedName(source, among: availableSources))
                        .font(.body.weight(.medium))
                    Text(connected ? "Connected · MIDI ID \(source.uniqueID)" : "Disconnected · selection is remembered")
                        .font(.caption)
                        .foregroundStyle(connected ? Color.secondary : Color.orange)
                }
                Spacer()
                if selected { Text("Selected").font(.caption).foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(source.name), MIDI ID \(source.uniqueID), \(connected ? "connected" : "disconnected"), \(selected ? "selected" : "not selected")"
        )
    }

    private var inputModeBinding: Binding<MIDIInputMode> {
        Binding(
            get: { configManager.config.midi.inputMode },
            set: { mode in
                if mode == .selected {
                    if let remembered = configManager.config.midi.inputSources.first {
                        _ = configManager.selectExclusiveInput(remembered)
                    } else if let first = midiEngine.connectedSources.first {
                        _ = configManager.selectExclusiveInput(first)
                    }
                } else {
                    _ = configManager.setMIDIInputMode(mode)
                }
                appState.actionExecutor.clearPendingControls()
            }
        )
    }

    private var feedbackSelection: Binding<String> {
        Binding(
            get: { configManager.config.midi.feedbackDestination.map(endpointTag) ?? "implicit" },
            set: { value in
                let destination = value == "implicit"
                    ? nil
                    : availableDestinations.first(where: { endpointTag($0) == value })
                _ = configManager.setFeedbackDestination(destination)
            }
        )
    }

    private var needsControllerChoice: Bool {
        configManager.config.midi.inputMode == .automatic && midiEngine.connectedSources.count > 1
    }

    private var inputModeExplanation: String {
        switch configManager.config.midi.inputMode {
        case .automatic:
            return "Uses a controller automatically only when exactly one is connected."
        case .selected:
            return "Only the selected controller can run mappings; the choice survives reconnects."
        case .all:
            return "Every connected controller can run mappings. Use this only when their controls do not overlap."
        }
    }

    private var inputModeColor: Color {
        (needsControllerChoice || (configManager.config.midi.inputMode == .all && midiEngine.connectedSources.count > 1))
            ? .orange
            : .secondary
    }

    private var availableSources: [MIDIEndpointReference] {
        mergedEndpoints(midiEngine.connectedSources, configManager.config.midi.inputSources)
    }

    private var availableDestinations: [MIDIEndpointReference] {
        mergedEndpoints(
            midiEngine.connectedDestinations,
            configManager.config.midi.feedbackDestination.map { [$0] } ?? []
        )
    }

    private func mergedEndpoints(
        _ connected: [MIDIEndpointReference],
        _ saved: [MIDIEndpointReference]
    ) -> [MIDIEndpointReference] {
        var byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.uniqueID, $0) })
        for endpoint in connected { byID[endpoint.uniqueID] = endpoint }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func endpointTag(_ endpoint: MIDIEndpointReference) -> String {
        "endpoint:\(endpoint.uniqueID)"
    }

    private func endpointLabel(
        _ endpoint: MIDIEndpointReference,
        connected: [MIDIEndpointReference]
    ) -> String {
        let isConnected = connected.contains { $0.uniqueID == endpoint.uniqueID }
        let name = disambiguatedName(endpoint, among: availableDestinations)
        return isConnected ? name : "\(name) — disconnected"
    }

    private func disambiguatedName(
        _ endpoint: MIDIEndpointReference,
        among endpoints: [MIDIEndpointReference]
    ) -> String {
        endpoints.filter { $0.name == endpoint.name }.count > 1
            ? "\(endpoint.name) · \(endpoint.uniqueID)"
            : endpoint.name
    }

    private func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }
}
