# MidiDeck

MidiDeck is a macOS menu bar app that turns a MIDI controller into a command surface. Pads, keys, knobs, and faders can launch or cycle apps, switch audio devices, control output or microphone volume, mute a microphone, and change mapping profiles.

## What it does

- Launches, focuses, and cycles visible windows for applications
- Switches the macOS audio output, input, or both together
- Maps CC controls to output or input volume
- Toggles or explicitly sets microphone mute
- Organizes mappings into switchable profiles
- Sends note LED state and arbitrary CC feedback to a chosen MIDI output
- Detects MIDI devices as they connect and disconnect
- Prevents two controllers from accidentally triggering the same unscoped controls
- Provides MIDI Learn plus a visual editor for mappings and profiles
- Reloads valid external JSON edits while retaining the last working setup after an invalid edit
- Creates automatic rollback copies before configuration changes

## Requirements

- macOS 14 (Sonoma) or later
- A USB or Bluetooth MIDI controller
- Swift 5.10 or later when building from source

## Install

```bash
git clone https://github.com/martinadolfi/midi-deck.git
cd midi-deck
./scripts/install.sh
```

The installer builds a release binary, installs `/Applications/MidiDeck.app`, and launches it. Run the same script after pulling an update.

To run without installing:

```bash
swift run MidiDeck
```

MidiDeck appears in the menu bar and does not add a Dock icon.

## First setup

Click the MidiDeck menu bar icon, then open **Control Center**. The three tabs are:

- **Mappings** — create, search, edit, duplicate, and remove mappings; create and switch profiles; start MIDI Learn.
- **Controllers** — choose accepted MIDI inputs, select a feedback output, and inspect live MIDI input.
- **Configuration** — open, reveal, export, reload, import, diagnose, or restore the JSON file; manage Accessibility permission.

MidiDeck always uses this canonical configuration file:

```text
~/.config/midideck/config.json
```

You can configure everything from Control Center. The file is created when the first change is saved or when **Open JSON** is used. To start from the tracked example instead:

```bash
mkdir -p ~/.config/midideck
cp config.example.json ~/.config/midideck/config.json
```

Edit the copied device names and mappings, then choose **Reload**. Valid file changes also reload automatically.

Project-local `./config.json` files are no longer loaded implicitly. If one exists when MidiDeck starts from that directory, the Configuration tab offers it directly; **Import…** can choose any other JSON file. Imports are validated and copied into the canonical path without changing the source. This keeps behavior independent of how the app was launched.

## Multiple MIDI controllers

The menu bar's **Respond to** picker offers the common routing choices. The Controllers tab explains the current state and remembers disconnected selections.

| Mode | Behavior |
|---|---|
| `automatic` | Respond only when exactly one MIDI input is connected. With zero or multiple inputs, no mapping runs. This is the safe default. |
| `selected` | Respond only to one saved CoreMIDI endpoint ID. Both the UI and configuration validator require exactly one controller. |
| `all` | Respond to every connected input. This is an explicit opt-in and overlapping notes or CCs can trigger the same mapping. |

Automatic mode fails closed when a second controller appears, so identical notes or controller numbers cannot collide. Choose a controller from the menu bar or Controllers tab to continue, or choose **Any controller** only when merging devices is intentional.

Each mapping can optionally set a `source`. This is an explicit, narrow override of the global input policy: it opts that controller in for that mapping only. This is useful when one primary controller handles unscoped mappings while a second device owns a few dedicated controls. A source-scoped mapping takes deterministic precedence over an unscoped mapping with the same trigger. Endpoint references contain both a display `name` and CoreMIDI `uniqueID`; matching uses `uniqueID`, so a renamed device remains selected. If two connected endpoints have the same name, the UI shows their IDs.

```json
{
  "source": {
    "uniqueID": 123456789,
    "name": "My Controller"
  }
}
```

Choose endpoints in Control Center instead of guessing IDs. Saved, disconnected endpoints remain visible and MidiDeck waits for the same ID to reconnect.

## MIDI Learn

In **Control Center → Mappings**, select a profile and choose **MIDI Learn**. Press a pad/key or move a knob/fader, then choose its action and save.

While learning:

- Normal actions are paused, so the control being learned cannot launch or change anything.
- Learn listens to all connected inputs, independent of the normal input-routing mode.
- The first Note On or Control Change is captured together with its stable source endpoint ID.
- Note Off messages are ignored by Learn; release-triggered mappings can still be created manually.

Closing MIDI Learn resumes normal routing.

## Configuration schema

`config.example.json` is a complete, valid schema-v2 starting point. A shortened example is shown below:

```json
{
  "version": 2,
  "activeProfile": "default",
  "midi": {
    "inputMode": "automatic",
    "inputSources": [],
    "feedbackDestination": null
  },
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
          "id": "A0000001-0000-0000-0000-000000000009",
          "description": "Fader 1: Master volume",
          "trigger": { "type": "controlChange", "channel": 10, "controller": 1 },
          "action": { "type": "setVolume", "device": "default" }
        }
      ]
    }
  }
}
```

MIDI channels are written as `1` through `16`; notes, controller numbers, CC values, and velocities are `0` through `127`. Mapping IDs must be unique UUIDs. Within one profile, two mappings cannot use the same trigger for the same source scope.

### Trigger types

| Type | Fields | Typical control |
|---|---|---|
| `noteOn` | `channel`, `note` | Pad, key, or button press |
| `noteOff` | `channel`, `note` | Pad, key, or button release |
| `controlChange` | `channel`, `controller` | Knob, fader, or slider |

Only `setVolume` and `setInputVolume` are valid for `controlChange`. All other actions require `noteOn` or `noteOff`.

### Action types

| Action | Fields | Behavior |
|---|---|---|
| `openApp` | `bundleId` | Launch the app, focus it if running, or cycle its non-minimized standard windows if already focused. |
| `setAudioOutput` | `device` | Make the named device the macOS default output. |
| `setAudioInput` | `device` | Make the named device the macOS default input. |
| `setVolume` | `device` | Map CC `0...127` to output volume `0...100%`; use `"default"` for the current default output. |
| `setInputVolume` | `device` | Map CC `0...127` to input volume `0...100%`; use `"default"` for the current default input. |
| `switchAudioDevice` | `device`, `inputDevice` | Switch output and input together. At least one must be present. Optional `notify` shows an on-screen message after success. |
| `toggleMicMute` | `device` | Toggle the named microphone; use `"default"` for the current default input. |
| `setMicMute` | `device`, `muted` | Set an explicit mute state. `muted` defaults to `true`; `device` defaults to `"default"`. |
| `switchProfile` | `profile` | Activate the named profile, clear the old profile's LEDs, and initialize the new profile's LED state. |

Audio device names must match the names reported by macOS. Control Center populates its pickers from currently available devices and preserves unavailable configured names.

### LED and CC feedback

For note triggers, `led` sends feedback on the trigger's channel and note. Supported colors are:

`off`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`

Color values are controller-specific Note On velocities (`off` sends Note Off). Supported behaviors are:

| Behavior | Result |
|---|---|
| `solid` | On during initialization and sent on again after the mapping fires. |
| `blink` | Off during initialization, then pulses for about 180 ms after the mapping fires. |
| `toggleOnMute` | Reflects the microphone's current mute state and updates after `toggleMicMute` or `setMicMute`. |

Arbitrary CC feedback can also be attached to a note-triggered mapping. It is sent only after that mapping's action succeeds. At launch or refresh, MidiDeck does not blindly replay every message: for audio-output, audio-input, paired-audio, and explicit-mute actions, it sends feedback only for mappings whose target matches the current macOS state. Other arbitrary feedback waits until its action succeeds:

```json
"feedback": [
  { "channel": 10, "controller": 20, "value": 127 }
]
```

LED state and safely derived state feedback initialize at launch, after an output reconnects, when profiles change, and when **Refresh LEDs** is chosen.

### Feedback output safety

Feedback destination precedence is:

1. The mapping's `feedbackDestination`
2. Global `midi.feedbackDestination`
3. The mapping's legacy v1 `device` name
4. Implicit routing, but only when exactly one MIDI output exists

Explicit endpoint references match by `uniqueID`. If the selected endpoint is disconnected, MidiDeck waits for it and does not fall back to another output. With no explicit destination and multiple outputs, feedback is not sent. Legacy names must resolve to exactly one exact or partial name match. These fail-closed rules prevent LEDs or CC feedback from reaching the wrong controller.

Select the global output in **Control Center → Controllers**. A mapping-specific output can be chosen under **Controller feedback → Advanced** in its editor.

## Profiles and editing

The menu bar can switch the active profile immediately. In Control Center you can create, duplicate, rename, delete, search, and activate profiles or mappings. Renaming a profile updates `switchProfile` mappings that target it; deleting a profile retargets those mappings to a remaining replacement. MidiDeck always keeps at least one profile.

The menu bar also shows routing state and recent activity, and offers **Pause**, **Reload**, and **Refresh LEDs**. Pause stops actions without disconnecting MIDI input.

## Backups, restore, and invalid edits

The canonical file is written atomically. Before a structural save or import replaces prior validated content, MidiDeck creates:

- `~/.config/midideck/config.json.bak` — the most recent rollback copy
- `~/.config/midideck/backups/config-<timestamp>-<id>.json` — timestamped history; the newest 10 are retained

If the canonical file is unreadable when a visual change replaces it, MidiDeck separately creates `~/.config/midideck/backups/config-invalid-<timestamp>-<id>.json` as a raw recovery copy.

Profile activation alone does not normally create a backup. Use **Configuration → Restore Last Backup** to swap the canonical file with `config.json.bak`. MidiDeck first validates both sides and rotates the configuration being replaced into the backup, so choosing Restore again undoes the restore.

Malformed JSON, unsupported future schema versions, and semantic validation errors never replace the in-memory last-known-good setup. Control Center reports the problem; correct the file and reload it. If you instead make a visual edit while the on-disk file is unreadable, MidiDeck preserves its raw bytes in a `config-invalid-*` recovery snapshot before writing the valid setup.

## Version 1 compatibility

Schema-v1 files still decode. Missing v2 MIDI settings default to safe `automatic` input routing with no explicit feedback destination. The file remains untouched until a save; the next save writes schema v2 after first creating a backup.

The v1 mapping field `device` is also supported. It acts as a case-insensitive partial input-name filter and, historically, as the feedback-output name. In v2, prefer `source` and `feedbackDestination`, which use stable endpoint IDs. A v2 `source` takes precedence for input matching. MidiDeck retains the legacy field until feedback has an explicit stable destination, avoiding a silent loss of controller LEDs during migration.

## Permissions

Accessibility permission is optional. Launching and focusing apps works without it; cycling an already-focused app's visible windows requires **System Settings → Privacy & Security → Accessibility**. Control Center can request the permission and open the relevant settings page.

## Troubleshooting

- **No mappings run** — Check the status in the menu bar. In `automatic` mode, connect exactly one input or explicitly select a controller.
- **The wrong controller triggers a mapping** — Use `selected` input mode and, if needed, set a mapping-specific source. Avoid `all` when controls overlap.
- **MIDI Learn sees input but actions do not run** — This is expected while Learn is open; normal actions are paused.
- **Audio switching fails** — Choose the device in the mapping editor or match its macOS name exactly.
- **LEDs do not respond** — Confirm the controller accepts MIDI output, then select the correct feedback destination. Multiple implicit outputs intentionally disable feedback.
- **A selected device is shown as disconnected** — MidiDeck matches the saved CoreMIDI ID, not only its display name. Re-select the endpoint if the hardware now exposes a different ID.
- **JSON edits do not apply** — Open Configuration diagnostics. Invalid changes leave the last-known-good configuration active.

## Build and test

```bash
swift build
swift test
swift build -c release
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for architecture and contributor notes.
