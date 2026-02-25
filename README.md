# MidiDeck

A macOS menu bar app that maps MIDI controller inputs to system actions. Use your MIDI pads, keys, and faders to launch apps, switch audio devices, control volume, toggle mic mute, and more.

## Features

- **Launch applications** — Trigger app launches from MIDI pads or keys
- **Audio device switching** — Instantly switch between speakers, headphones, and microphones
- **Volume control** — Map MIDI faders/knobs to system volume
- **Mic mute toggle** — One-button mute/unmute with LED feedback
- **Profiles** — Define multiple mapping profiles and switch between them on the fly
- **LED feedback** — Send color and state information back to your MIDI controller
- **Live config reload** — Edit your config file and changes apply immediately
- **MIDI Learn** — Use the settings UI to capture MIDI events and build mappings

## Requirements

- macOS 14 (Sonoma) or later
- A MIDI controller connected via USB or Bluetooth
- Swift 5.10+ (for building from source)

## Installation

```bash
git clone <repo-url>
cd midi-deck
swift build -c release
```

The built binary will be at `.build/release/MidiDeck`.

## Setup

1. Copy the example configuration:
   ```bash
   cp config.example.json config.json
   ```

2. Edit `config.json` to match your MIDI controller and desired mappings. See the example file for the full format.

3. Run the app:
   ```bash
   .build/release/MidiDeck
   ```

MidiDeck will appear as an icon in your menu bar (no dock icon).

## Configuration

MidiDeck is configured through a JSON file. It looks for config in this order:

1. `./config.json` (current working directory)
2. `~/.config/midideck/config.json`

### Quick Example

```json
{
  "version": 1,
  "activeProfile": "default",
  "profiles": {
    "default": {
      "mappings": [
        {
          "id": "A0000001-0000-0000-0000-000000000001",
          "description": "Pad 1: Open Safari",
          "trigger": { "type": "noteOn", "channel": 10, "note": 36 },
          "action": { "type": "openApp", "bundleId": "com.apple.Safari" },
          "led": { "color": "blue", "behavior": "solid" }
        },
        {
          "id": "A0000001-0000-0000-0000-000000000002",
          "description": "Fader: Master volume",
          "trigger": { "type": "controlChange", "channel": 10, "controller": 1 },
          "action": { "type": "setVolume", "device": "default" }
        }
      ]
    }
  }
}
```

### Available Actions

| Action | What it does | Key fields |
|--------|-------------|------------|
| `openApp` | Launch or focus an app | `bundleId` |
| `setAudioOutput` | Switch output device | `device` (device name) |
| `setAudioInput` | Switch input device | `device` (device name) |
| `setVolume` | Control volume with a fader/knob | `device` (`"default"` or device name) |
| `toggleMicMute` | Toggle mic mute on/off | `device` (`"default"` or device name) |
| `switchProfile` | Switch to another profile | `profile` (profile name) |

### LED Colors

`red`, `green`, `blue`, `cyan`, `magenta`, `yellow`, `white`

### LED Behaviors

- `solid` — Always on
- `toggleOnMute` — Reflects mute state (useful for mic mute buttons)

### Profiles

You can define multiple profiles (e.g., "default" and "streaming") and switch between them with a `switchProfile` action. Each profile has its own set of mappings and LED states.

### Device Filtering

Add a `"device"` field to any mapping to restrict it to a specific MIDI controller by name. If omitted, the mapping responds to events from any connected device.

## Settings UI

Click the menu bar icon to access the settings window, where you can:

- View and edit mappings
- Use MIDI Learn to capture events from your controller
- Switch profiles
- See connected MIDI devices

## Troubleshooting

- **No MIDI events detected** — Make sure your controller is connected and recognized by macOS (check Audio MIDI Setup.app).
- **Audio device not switching** — The device name in your config must exactly match the system device name. Check System Settings > Sound for the exact name.
- **LEDs not responding** — Not all controllers support LED feedback. The controller must accept MIDI output on the same port it sends input.
- **Config changes not applying** — Ensure the JSON is valid. MidiDeck watches the file for changes but will silently ignore malformed JSON.
