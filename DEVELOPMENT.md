# MidiDeck Development Guide

## Tech Stack

- **Language:** Swift 5.10
- **Build system:** Swift Package Manager
- **Target:** macOS 14 (Sonoma) and later
- **Frameworks:** CoreMIDI, CoreAudio, AudioToolbox, SwiftUI, AppKit

## Project Structure

```
Sources/MidiDeck/
├── MidiDeckApp.swift           # App entry point, menu bar setup, event loop
├── Config/
│   ├── Configuration.swift     # Data models (Profile, Mapping, Trigger, Action, LEDConfig)
│   └── ConfigManager.swift     # Config loading, saving, and live file watching
├── MIDI/
│   ├── MIDIEngine.swift        # MIDI input handling, async event stream
│   ├── MIDIEvent.swift         # MIDI event parsing (UMP and legacy protocols)
│   └── MIDIOutputManager.swift # MIDI output for sending LED feedback
├── Audio/
│   └── AudioDeviceManager.swift # Audio device enumeration, switching, volume control
├── Actions/
│   ├── ActionExecutor.swift    # Core mapping logic — matches triggers to actions
│   ├── AppActions.swift        # Application launching via bundle ID
│   └── AudioActions.swift      # Audio device and volume helpers
└── Views/
    ├── MenuBarView.swift       # Menu bar dropdown UI
    ├── SettingsView.swift      # Settings window with profile and mapping editors
    └── MIDILearnView.swift     # MIDI learn mode UI
```

## Architecture

### Data Flow

```
MIDI Controller
    │
    ▼
MIDIEngine (CoreMIDI input → AsyncStream<MIDIEvent>)
    │
    ▼
MidiDeckApp (event loop consumes the stream)
    │
    ▼
ActionExecutor (matches event against active profile mappings)
    │
    ├──▶ AppActions        (launch apps)
    ├──▶ AudioActions       (switch devices, set volume, toggle mute)
    ├──▶ Profile switching  (change active profile, resend LEDs)
    │
    ▼
MIDIOutputManager (send LED feedback to controller)
```

### Key Design Decisions

- **Menu bar app** — runs as an accessory (`NSApplication.ActivationPolicy.accessory`), no dock icon.
- **Async streams** — MIDI events are delivered via Swift's `AsyncStream` and consumed in an async loop.
- **CC throttling** — Control change messages (faders/knobs) are throttled with a 30ms `DispatchSourceTimer` to avoid flooding the audio system.
- **Live config reload** — `ConfigManager` watches the config file with `DispatchSource.makeFileSystemObjectSource` and reloads on changes, so edits take effect without restarting.
- **Profile system** — Mappings are organized into named profiles. Switching profiles resends all LED states to the controller.

## Building

```bash
# Debug build
swift build

# Release build
swift build -c release
```

## Running

```bash
# Run debug build
swift run MidiDeck

# Or run the binary directly
.build/debug/MidiDeck
.build/release/MidiDeck
```

The app looks for configuration in this order:
1. `./config.json` (current working directory)
2. `~/.config/midideck/config.json`

Copy `config.example.json` to `config.json` and edit it to match your MIDI controller.

## Configuration Schema

The config file is JSON with this structure:

```jsonc
{
  "version": 1,
  "activeProfile": "default",
  "profiles": {
    "profile-name": {
      "mappings": [
        {
          "id": "UUID",
          "description": "Human-readable label",
          "device": "MIDI device name (optional, matches any if omitted)",
          "trigger": {
            "type": "noteOn | controlChange",
            "channel": 1-16,
            "note": 0-127,        // for noteOn
            "controller": 0-127   // for controlChange
          },
          "action": {
            "type": "openApp | setAudioOutput | setAudioInput | setVolume | toggleMicMute | switchProfile",
            // action-specific fields...
          },
          "led": {
            "color": "red | green | blue | cyan | magenta | yellow | white",
            "behavior": "solid | toggleOnMute"
          }
        }
      ]
    }
  }
}
```

### Action Types

| Action | Required Fields | Description |
|--------|----------------|-------------|
| `openApp` | `bundleId` | Launch or focus an application |
| `setAudioOutput` | `device` | Switch the system audio output device |
| `setAudioInput` | `device` | Switch the system audio input device |
| `setVolume` | `device` | Map a fader/knob CC value to device volume |
| `toggleMicMute` | `device` (`"default"` for system default) | Toggle microphone mute on/off |
| `switchProfile` | `profile` | Switch to a different mapping profile |

### Trigger Types

| Trigger | Fields | Use Case |
|---------|--------|----------|
| `noteOn` | `channel`, `note` | Pads, keys, buttons |
| `controlChange` | `channel`, `controller` | Faders, knobs, sliders |

## Adding a New Action Type

1. Add the case to the `ActionType` enum in `Configuration.swift`
2. Add any new fields to the `Action` struct
3. Handle the new type in `ActionExecutor.execute(action:event:mapping:)`
4. If it needs LED feedback, update the LED logic in `ActionExecutor`
