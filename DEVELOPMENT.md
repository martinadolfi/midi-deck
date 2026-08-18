# MidiDeck Development Guide

## Toolchain

- Swift 5.10
- Swift Package Manager
- macOS 14 (Sonoma) or later
- SwiftUI, AppKit, CoreMIDI, CoreAudio, AudioToolbox, and ApplicationServices

## Build, test, and run

```bash
# Compile a debug build
swift build

# Run the complete XCTest suite
swift test

# Run from Swift Package Manager
swift run MidiDeck

# Compile and run a release build directly
swift build -c release
.build/release/MidiDeck

# Build, install in /Applications, and relaunch
./scripts/install.sh
```

The install script copies SwiftPM's architecture-independent release product, so it works on Apple silicon and Intel hosts. Direct SwiftPM commands are preferable for routine development and tests.

## Project structure

```text
Sources/MidiDeck/
├── MidiDeckApp.swift                 # App state, routing gate, menu bar and settings scenes
├── Actions/
│   ├── ActionExecutor.swift          # Matching, CC throttling, actions, activity, and feedback
│   ├── AppActions.swift              # App launch, focus, and visible-window cycling
│   └── AudioActions.swift            # Action-level audio helpers
├── Audio/
│   └── AudioDeviceManager.swift      # CoreAudio discovery and mutations
├── Config/
│   ├── Configuration.swift           # Schema v2 models, compatibility, and validation
│   └── ConfigManager.swift           # Canonical file, transactions, watching, and backups
├── MIDI/
│   ├── MIDIEngine.swift              # Endpoint topology and broadcast event streams
│   ├── MIDIEvent.swift               # MIDI 1.0 UMP parsing
│   └── MIDIOutputManager.swift       # Fail-closed note and CC output routing
└── Views/
    ├── MenuBarView.swift             # Compact status and common controls
    ├── SettingsView.swift            # Control Center shell and mapping/profile UI
    ├── ControllerSettingsView.swift  # Input/output routing and live monitor
    ├── ConfigurationSettingsView.swift # File operations, diagnostics, and permissions
    ├── MappingEditor.swift           # Validated visual mapping editor
    ├── MIDILearnView.swift           # Capture flow
    └── ViewSupport.swift             # Display names, summaries, and shared UI helpers

Tests/MidiDeckTests/
├── ConfigurationTests.swift          # Decoding, v1 migration, validation, example config
├── ConfigManagerTests.swift           # Routing, persistence, backup, last-known-good behavior
├── MIDIEngineTests.swift              # Multicast delivery and subscriber isolation
├── MIDIEventTests.swift               # UMP parsing and channel normalization
└── MIDIOutputManagerTests.swift       # Fail-closed destination resolution
```

## Runtime data flow

```text
CoreMIDI sources
    │
    ▼
MIDIEngine ───────────────▶ MIDI Learn subscriber
    │                       (all sources; capture only)
    ▼
AppState routing gate
    │  paused/learning? stop
    │  automatic/selected/all policy
    ▼
ActionExecutor
    │  mapping source + trigger match
    ├────────▶ AppActions
    ├────────▶ AudioActions
    ├────────▶ ConfigManager profile switch
    └────────▶ MIDIOutputManager
                    │
                    ▼
              selected MIDI destination
```

`MIDIEngine.events()` is a broadcast stream: the application route loop and MIDI Learn can subscribe independently. `AppState` suppresses normal execution while paused or learning, but the Learn subscriber continues receiving raw input from all sources.

## Input routing and collision policy

`MIDIEndpointReference` stores a CoreMIDI `uniqueID` and the last known display `name`. Equality and hashing use only `uniqueID`. This is the persisted identity for both sources and destinations.

The global `MIDIConfiguration.inputMode` supplies the policy for unscoped mappings:

- `automatic` accepts a source only when exactly one source is connected. Multiple sources fail closed.
- `selected` accepts exactly one ID in `inputSources`.
- `all` accepts every source and deliberately disables global collision protection.

A mapping-specific `source` (or uniquely resolved legacy v1 `device` name) is an explicit override for that mapping only. It can opt a secondary controller into a small set of actions even when another controller is globally selected. `ActionExecutor` evaluates matching scoped mappings before unscoped mappings, making same-trigger overrides deterministic rather than array-order dependent.

`MIDIEngine` refreshes source and destination topology after CoreMIDI setup/object/property notifications. It disconnects and reconnects sources during refresh, attaches each source endpoint as the connection refcon, and publishes the stable source reference with every parsed event.

## Event and action rules

MIDI channels are normalized to `1...16`. Notes, controller numbers, and values are `0...127`. MIDI Note On with velocity zero is parsed as Note Off.

`noteOn` and `noteOff` triggers support:

- `openApp`
- `setAudioOutput`
- `setAudioInput`
- `switchAudioDevice`
- `toggleMicMute`
- `setMicMute`
- `switchProfile`

`controlChange` triggers support only:

- `setVolume`
- `setInputVolume`

CC execution is coalesced per profile, mapping, and source on a 30 ms main-queue timer. Repeated identical values are not applied again. Pending CC state is cleared when routing, profiles, pause state, or configuration changes.

Only the highest-priority matching mapping in the active profile runs: an exact source scope wins over an unscoped mapping, while configuration order remains the tiebreaker within a scope. Validation rejects duplicate mapping UUIDs and duplicate source-scope/trigger pairs in a profile, as well as invalid action fields and trigger/action combinations.

## Feedback routing

`MIDIOutputManager` chooses a destination in this order:

1. Mapping `feedbackDestination`
2. Global `midi.feedbackDestination`
3. Legacy mapping `device` name
4. Implicit output when exactly one destination exists

Stable references require one connected endpoint with the requested `uniqueID`; an absent explicit endpoint does not fall back. Legacy names first require a unique case/diacritic-insensitive exact match, then a unique partial match. Implicit routing requires exactly one destination. Zero, duplicate, missing, or ambiguous matches do not send anything.

This fail-closed behavior applies to Note On/Off LED state and configured CC `feedback`. A successful note-triggered action schedules its configured CC feedback; failed actions do not assert success state. Initialization never blindly replays every arbitrary message: state-selecting output, input, paired-audio, and explicit-mute mappings send feedback only when their target matches current macOS state. LED initialization still runs after launch, destination topology changes, profile changes, successful reload/import/restore and mapping saves, and manual refresh. Toggle-on-mute LEDs are derived from the current microphone state.

LED behavior is implemented as follows:

- `solid`: on during profile initialization; re-sent 200 ms after a trigger.
- `blink`: off during initialization; on 200 ms after a trigger and off about 180 ms later.
- `toggleOnMute`: initialized from the configured microphone's mute state and updated by `toggleMicMute` or `setMicMute`.

Colors map to fixed controller velocities in `LEDConfig.velocity`: `off=0`, `red=5`, `green=17`, `cyan=37`, `yellow=41`, `blue=45`, `magenta=53`, and `white=127`. Hardware palettes may interpret these values differently.

## Configuration lifecycle

The one active path is always:

```text
~/.config/midideck/config.json
```

`ConfigManager` never silently chooses a file based on the process working directory. A detected project-local `config.json` is exposed as an explicit import candidate. Import reads and validates the source, backs up the current canonical file, writes the imported configuration to the canonical path, and leaves the source unchanged.

Loads and saves are validated transactions:

1. Decode the candidate and reject schema versions newer than `Configuration.currentVersion`.
2. Run semantic validation.
3. On save, encode schema v2 with stable formatting.
4. Back up changed existing data when the mutation requests a backup.
5. Atomically replace the canonical file and publish the new in-memory configuration.

A failed load or save never replaces the last-known-good in-memory configuration. The UI exposes the error, validation issues, save state, migration notice, and whether the last-known-good state is in use.

The file watcher observes the canonical directory, debounces changes for 350 ms, and ignores data just written or already loaded by the app.

### Backups

Before structural mutations, MIDI preference changes, mapping/profile edits, or imports replace prior validated content, `ConfigManager` writes both:

```text
~/.config/midideck/config.json.bak
~/.config/midideck/backups/config-YYYYMMDD-HHmmss-SSS-<id>.json
```

If the canonical file is unreadable when a visual mutation replaces it, `ConfigManager` additionally preserves the raw bytes as:

```text
~/.config/midideck/backups/config-invalid-YYYYMMDD-HHmmss-SSS-<id>.json
```

The 10 newest timestamped snapshots are retained across validated and raw-recovery copies. An unreadable canonical file is copied to `config-invalid-*` before any visual mutation overwrites it; malformed bytes never replace trusted `.bak`. Active-profile switching skips a new backup only after the on-disk schema is already current. `restoreLastBackup()` validates both configurations and rotates the current canonical data into `config.json.bak`, so running Restore again undoes the restore.

## Schema v2 reference

The authoritative model is `Configuration.swift`; `config.example.json` is executable documentation and is decoded by the test suite.

```jsonc
{
  "version": 2,
  "activeProfile": "default",
  "midi": {
    "inputMode": "automatic | selected | all",
    "inputSources": [
      { "uniqueID": 123456789, "name": "Controller input" }
    ],
    "feedbackDestination": {
      "uniqueID": 987654321,
      "name": "Controller output"
    }
  },
  "profiles": {
    "profile-name": {
      "mappings": [
        {
          "id": "UUID",
          "description": "Human-readable label",
          "source": { "uniqueID": 123456789, "name": "Controller input" },
          "feedbackDestination": { "uniqueID": 987654321, "name": "Controller output" },
          "trigger": {
            "type": "noteOn | noteOff | controlChange",
            "channel": 1,
            "note": 36,
            "controller": 1
          },
          "action": {
            "type": "openApp | setAudioOutput | setAudioInput | setVolume | setInputVolume | switchAudioDevice | toggleMicMute | setMicMute | switchProfile",
            "bundleId": "com.apple.Safari",
            "device": "default or output/input device name",
            "inputDevice": "input device name",
            "profile": "target profile name",
            "muted": true,
            "notify": "optional switchAudioDevice success message"
          },
          "led": {
            "color": "off | red | green | yellow | blue | magenta | cyan | white",
            "behavior": "solid | blink | toggleOnMute"
          },
          "feedback": [
            { "channel": 1, "controller": 20, "value": 127 }
          ]
        }
      ]
    }
  }
}
```

Omit action fields that do not apply. For `noteOn`/`noteOff`, omit `controller`; for `controlChange`, omit `note`. `source`, `feedbackDestination`, `led`, and `feedback` are optional.

`led` and configured CC `feedback` require a note trigger. `toggleOnMute` LED behavior additionally requires `toggleMicMute` or `setMicMute`; validation rejects combinations the runtime cannot represent.

## Version 1 compatibility

The custom decoder treats a missing `version` as v1 and upgrades supported v1 data in memory to `Configuration.currentVersion`. Core keys `activeProfile` and `profiles`, plus each profile's `mappings` key, are required. Mapping IDs and descriptions retain compatibility defaults; the optional v2 `midi` object and its routing fields default to safe automatic input routing with no explicit feedback destination. The next save emits v2 and normally backs up the v1 file first.

The legacy mapping `device` field remains readable and retains its original dual purpose:

- A case/diacritic-insensitive partial source-name filter
- A legacy feedback destination name when neither a mapping nor global stable destination is set

When `source` is also present, its stable ID wins for input matching and validation reports that the legacy field is redundant. New UI edits should use `source` and `feedbackDestination`.

## Adding an action type

1. Add the case and any fields in `Configuration.swift`.
2. Define trigger compatibility in `ActionType.isCompatible(with:)`.
3. Add semantic validation in `ConfigurationValidator.mappingIssues`.
4. Implement execution in `ActionExecutor`.
5. Add its label, icon, summary, fields, and help text in `ViewSupport.swift` and `MappingEditor.swift`.
6. Add focused tests plus an example or schema documentation update.

## Window cycling scope

`openApp` cycles non-minimized `AXStandardWindow` windows visible through the Accessibility API. Full-screen windows on other macOS Spaces remain a separate research objective; see [docs/fullscreen-space-cycling-spec.md](docs/fullscreen-space-cycling-spec.md).
