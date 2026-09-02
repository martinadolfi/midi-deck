import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var configManager: ConfigManager
    @ObservedObject private var midiEngine: MIDIEngine
    @ObservedObject private var actionExecutor: ActionExecutor
    @Environment(\.openWindow) private var openWindow

    init(appState: AppState) {
        self.appState = appState
        _configManager = ObservedObject(wrappedValue: appState.configManager)
        _midiEngine = ObservedObject(wrappedValue: appState.midiEngine)
        _actionExecutor = ObservedObject(wrappedValue: appState.actionExecutor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            inputSection
            profileSection

            if let error = configManager.configError {
                errorBanner(error)
            } else if let notice = appState.routingNotice {
                noticeBanner(notice)
            }

            activitySection
            primaryActions
            utilityActions

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 350)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("MidiDeck")
                    .font(.headline)
                Text("MIDI command surface")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(title: operationalStatus.title, color: operationalStatus.color)
        }
    }

    private var inputSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Picker("Respond to", selection: inputSelection) {
                    Text("Automatic (one controller)").tag("automatic")
                    Text("Any controller").tag("all")

                    if configManager.config.midi.inputMode == .selected,
                       configManager.config.midi.inputSources.count > 1 {
                        Text("Multiple selected").tag("selected-multiple")
                    }

                    ForEach(availableInputSources) { source in
                        Text(inputSourceLabel(source))
                            .tag(sourceTag(source))
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 5) {
                    Image(systemName: controllerStatusSymbol)
                    Text(controllerSummary)
                }
                .font(.caption)
                .foregroundStyle(controllerSummaryColor)
            }
        } label: {
            Label("MIDI input", systemImage: "pianokeys")
                .font(.subheadline.weight(.semibold))
        }
    }

    private var profileSection: some View {
        Picker("Active profile", selection: Binding(
            get: { configManager.config.activeProfile },
            set: { name in
                _ = actionExecutor.activateProfile(name)
            }
        )) {
            ForEach(configManager.profileNames, id: \.self) { name in
                Text("\(name) · \(configManager.config.profiles[name]?.mappings.count ?? 0) mappings")
                    .tag(name)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var activitySection: some View {
        if let activity = actionExecutor.lastActivity {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: activity.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(activity.succeeded ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.mappingName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(activity.detail) · \(activity.sourceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        } else if let lastEvent = midiEngine.lastEvent {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lastEvent.event.friendlyDescription)
                        .font(.caption)
                    Text(lastEvent.source.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var primaryActions: some View {
        HStack {
            Button {
                openControlCenter()
            } label: {
                Label("Control Center", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(",")

            Button {
                appState.setPaused(!appState.actionsPaused)
            } label: {
                Label(appState.actionsPaused ? "Resume" : "Pause", systemImage: appState.actionsPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    private var utilityActions: some View {
        HStack(spacing: 8) {
            Button {
                actionExecutor.sendInitialLEDStates()
            } label: {
                Label("Refresh LEDs", systemImage: "lightbulb")
            }
            .help("Resend the active profile's LED state")

            Spacer()

            Button {
                _ = appState.reloadConfiguration()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Reload the configuration file")
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Label(configManager.saveState.label, systemImage: configManager.configError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(configManager.isUsingLastKnownGood ? "Using last working setup" : "Configuration problem", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Button("Open Control Center") { openControlCenter() }
                .controlSize(.small)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private func noticeBanner(_ message: String) -> some View {
        Label(message, systemImage: appState.isLearning ? "dot.radiowaves.left.and.right" : "info.circle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var inputSelection: Binding<String> {
        Binding(
            get: {
                switch configManager.config.midi.inputMode {
                case .automatic: return "automatic"
                case .all: return "all"
                case .selected:
                    guard configManager.config.midi.inputSources.count == 1,
                          let source = configManager.config.midi.inputSources.first else {
                        return "selected-multiple"
                    }
                    return sourceTag(source)
                }
            },
            set: { selection in
                switch selection {
                case "automatic": _ = configManager.setMIDIInputMode(.automatic)
                case "all": _ = configManager.setMIDIInputMode(.all)
                case "selected-multiple": break
                default:
                    guard let id = Int32(selection.replacingOccurrences(of: "source:", with: "")),
                          let source = (midiEngine.connectedSources + configManager.config.midi.inputSources)
                            .first(where: { $0.uniqueID == id }) else { return }
                    _ = configManager.selectExclusiveInput(source)
                }
                actionExecutor.clearPendingControls()
            }
        )
    }

    private var operationalStatus: (title: String, color: Color) {
        if configManager.configError != nil { return ("Config error", .red) }
        if midiEngine.initializationError != nil { return ("MIDI error", .red) }
        if appState.isLearning { return ("Learning", .blue) }
        if appState.actionsPaused { return ("Paused", .orange) }
        if midiEngine.connectedSources.isEmpty { return ("No controller", .secondary) }
        if configManager.config.midi.inputMode == .automatic, midiEngine.connectedSources.count > 1 {
            return ("Choose input", .orange)
        }
        if configManager.config.midi.inputMode == .all, midiEngine.connectedSources.count > 1 {
            return ("All inputs", .orange)
        }
        if configManager.config.midi.inputMode == .selected {
            let connectedIDs = Set(midiEngine.connectedSources.map(\.uniqueID))
            if configManager.config.midi.inputSources.allSatisfy({ !connectedIDs.contains($0.uniqueID) }) {
                return ("Waiting", .orange)
            }
        }
        return ("Ready", .green)
    }

    private var controllerSummary: String {
        if let initializationError = midiEngine.initializationError {
            return initializationError
        }
        if midiEngine.connectedSources.isEmpty {
            return "Connect a controller to begin"
        }
        if configManager.config.midi.inputMode == .automatic, midiEngine.connectedSources.count > 1 {
            return "\(midiEngine.connectedSources.count) connected — choose one to prevent collisions"
        }
        if configManager.config.midi.inputMode == .all, midiEngine.connectedSources.count > 1 {
            return "Listening to all \(midiEngine.connectedSources.count) — controls may collide"
        }
        if configManager.config.midi.inputMode == .selected,
           let selected = configManager.config.midi.inputSources.first,
           !midiEngine.connectedSources.contains(where: { $0.uniqueID == selected.uniqueID }) {
            return "Waiting for \(selected.name)"
        }
        return midiEngine.connectedSources.count == 1
            ? "1 controller connected"
            : "\(midiEngine.connectedSources.count) controllers connected"
    }

    private var controllerStatusSymbol: String {
        operationalStatus.color == .green ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private var controllerSummaryColor: Color {
        if midiEngine.initializationError != nil { return .red }
        if midiEngine.connectedSources.isEmpty { return .secondary }
        if operationalStatus.color == .orange { return .orange }
        return .secondary
    }

    private var availableInputSources: [MIDIEndpointReference] {
        var byID = Dictionary(uniqueKeysWithValues: configManager.config.midi.inputSources.map { ($0.uniqueID, $0) })
        for source in midiEngine.connectedSources {
            byID[source.uniqueID] = source
        }
        return byID.values.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.uniqueID < $1.uniqueID : comparison == .orderedAscending
        }
    }

    private func inputSourceLabel(_ source: MIDIEndpointReference) -> String {
        let name = disambiguatedName(source, among: availableInputSources)
        let connected = midiEngine.connectedSources.contains { $0.uniqueID == source.uniqueID }
        return connected ? name : "\(name) — disconnected"
    }

    private func sourceTag(_ source: MIDIEndpointReference) -> String {
        "source:\(source.uniqueID)"
    }

    private func disambiguatedName(_ source: MIDIEndpointReference, among endpoints: [MIDIEndpointReference]) -> String {
        let duplicates = endpoints.filter { $0.name == source.name }
        return duplicates.count > 1 ? "\(source.name) · \(source.uniqueID)" : source.name
    }

    private func openControlCenter() {
        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
