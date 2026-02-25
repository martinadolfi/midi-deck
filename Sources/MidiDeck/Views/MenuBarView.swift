import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var midiEngine: MIDIEngine
    let onSendLEDs: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            Label {
                Text("MidiDeck")
                    .font(.headline)
            } icon: {
                Image(systemName: "square.grid.3x3.fill")
            }
            .padding(.bottom, 4)

            Divider()

            // MIDI Devices
            if midiEngine.connectedDeviceNames.isEmpty {
                Label("No MIDI devices", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            } else {
                Text("MIDI Devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(midiEngine.connectedDeviceNames, id: \.self) { name in
                    Label(name, systemImage: "pianokeys")
                }
            }

            Divider()

            // Active Profile
            Text("Profile")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(configManager.profileNames, id: \.self) { name in
                Button {
                    configManager.switchProfile(name)
                    onSendLEDs()
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        if name == configManager.config.activeProfile {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            // Config error
            if let error = configManager.configError {
                Label("Config error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Divider()
            }

            // Actions
            Button("Refresh LEDs") {
                onSendLEDs()
            }
            .keyboardShortcut("r")

            Button("Reload Config") {
                configManager.load()
                onSendLEDs()
            }
            .keyboardShortcut("l")

            Button("Settings...") {
                onOpenSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit MidiDeck") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
    }
}
