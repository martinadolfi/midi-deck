# Tech Spec: Window Cycling Across Full-Screen Spaces

## Current State (working)

File: `Sources/MidiDeck/Actions/AppActions.swift`

The `cycleWindows` method uses the Accessibility (AX) API to cycle through an app's windows on the **current Space**:

1. Gets windows via `AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute)`
2. Filters to `AXStandardWindow` subrole, excludes minimized
3. Raises `eligibleWindows.last!` (backmost window) to cycle through all of them
4. Calls `app.activate()`

This works correctly for any number of windows **on the same desktop/Space**.

## Objective

When an app has windows across multiple Spaces (specifically, one or more windows in **macOS full-screen mode** — the green button, which creates a dedicated Space), cycling should switch between those Spaces. Currently, full-screen windows on other Spaces are completely invisible and ignored.

## Key Findings From Testing

### 1. The AX API cannot see full-screen windows on other Spaces

When a window enters macOS full-screen (its own Space), `kAXWindowsAttribute` does **not** include it. Tested with Chrome, Slack, and Cursor:

```
[App] Total AX windows: 1        <-- only the window on the current Space
[App]   window[0]: title=... subrole=AXStandardWindow minimized=false fullScreen=false
```

The full-screen window simply doesn't exist as far as AX is concerned.

### 2. CGWindowListCopyWindowInfo CAN see all windows

`CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)` returns windows across all Spaces, including full-screen ones. Filter by:
- `kCGWindowOwnerPID` matching the app's PID
- `kCGWindowLayer == 0` (normal window layer)
- Size >= 100x100 (to skip tiny helper windows)

**CRITICAL PROBLEM**: This filter is NOT sufficient. Chrome (and likely other Chromium apps) has helper/GPU windows that:
- Belong to the main process PID
- Are on layer 0
- Are >= 100x100 in size
- Report being on Space 0 or other non-user Spaces via CGS APIs

These phantom windows cause false positives when comparing CG count vs AX count. Any approach that relies on "CG has more windows than AX, therefore there are windows on other Spaces" is unreliable.

### 3. Private CGS APIs for Space switching DO work (partially)

The following private CoreGraphics SPI functions are available and functional on macOS 16 (Darwin 25.3.0):

```swift
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray
// mask 0x7 = all spaces including full-screen

@_silgen_name("CGSCopyManagedDisplayForSpace")
func CGSCopyManagedDisplayForSpace(_ cid: Int32, _ space: UInt64) -> CFString

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: Int32, _ display: CFString, _ space: UInt64)

@_silgen_name("CGSShowSpaces")
func CGSShowSpaces(_ cid: Int32, _ spaces: CFArray)

@_silgen_name("CGSHideSpaces")
func CGSHideSpaces(_ cid: Int32, _ spaces: CFArray)
```

**What works:**
- `_CGSDefaultConnection()` returns a valid connection ID
- `CGSGetActiveSpace()` correctly returns the current Space ID
- `CGSCopySpacesForWindows()` correctly maps window IDs to Space IDs (e.g., window 73 -> Space 24, window 3660 -> Space 1)
- `CGSCopyManagedDisplayForSpace()` returns the proper display UUID string for a Space
- The Space switch sequence (Set -> Show -> Hide) **does switch Spaces** when targeting a full-screen Space

**The sequence that worked (tested with Slack and Cursor):**
```swift
let display = CGSCopyManagedDisplayForSpace(cid, targetSpace)
CGSManagedDisplaySetCurrentSpace(cid, display, targetSpace)
CGSShowSpaces(cid, [NSNumber(value: targetSpace)] as CFArray)
CGSHideSpaces(cid, [NSNumber(value: currentSpace)] as CFArray)
// 50ms delay needed before activating
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
    app.activate()
}
```

**What didn't work:**
- `CGSManagedDisplaySetCurrentSpace` alone (without Show/Hide) — no visible effect
- Show -> Hide -> Set order — no visible effect
- Constructing the display UUID manually from `NSScreen`/`CGDisplayCreateUUIDFromDisplayID` instead of using `CGSCopyManagedDisplayForSpace` — no visible effect
- `app.activate()` immediately after (without the 50ms delay) — inconsistent

### 4. The real unsolved problem: reliably detecting which CG windows are "real"

The Space switching mechanism works. The problem is deciding WHEN to use it vs the AX raise path. Approaches that failed:

- **Comparing CG window count vs AX window count**: Chrome has helper windows (same PID, layer 0, large enough) that inflate the CG count. CG always reports more than AX even when all real windows are on the same Space.
- **Filtering CG windows with `space > 0`**: Some Chrome helper windows report non-zero spaces that differ from the current space.
- **Always trying Space switch first, falling back to AX**: `switchToNextSpace` returns `true` for Chrome due to helper windows on phantom spaces, so AX raise path never runs. Same-desktop cycling breaks completely.

### 5. Other approaches that were tried and failed

- **Simulating Cmd+` via CGEvent**: Posted the event but nothing happened. Cmd+` doesn't cross full-screen Spaces anyway.
- **Simulating Cmd+` via NSAppleScript/System Events**: `key code 50 using command down` — same result, no effect.
- **AppleScript app scripting** (`tell application id "..." to set index of last window to 1`): Worked for Chrome but not for Slack or Cursor (not all apps are scriptable). Also ~100-200ms overhead.

### 6. AX reports extra windows on full-screen Spaces

When you switch TO a full-screen Space, AX suddenly reports 2 eligible windows (even though only the full-screen window is visible). This caused the AX raise path to fire instead of Space switching back, resulting in every-other-press behavior. The fix was to prioritize Space switching when windows exist on other Spaces — but that leads back to problem #4 (detecting reliably).

## Recommended Approach for Next Attempt

The Space switching mechanism (CGS APIs) is proven to work. The core problem to solve is **reliably distinguishing real app windows from helper windows in CGWindowListCopyWindowInfo**. Possible angles:

1. **Use `kCGWindowName`** (requires Screen Recording permission) — real windows usually have titles, helper windows don't. Verify this holds for Chrome, Slack, Cursor.

2. **Use `kCGWindowIsOnscreen`** — might filter out offscreen helper windows while keeping full-screen windows on other Spaces. Needs testing.

3. **Use `CGSCopySpacesForWindows` to validate spaces** — filter to windows whose space is in a known set of user spaces (via `CGSCopySpaces` or similar). Skip windows on space 0 or system spaces.

4. **Match CG windows to AX windows** — use the private `_AXUIElementGetWindow` to get CGWindowIDs from AXUIElements, then identify which CG windows have no AX counterpart and are on a different space. This would precisely identify "real windows on other Spaces."

5. **Hybrid approach**: Use AX for same-Space cycling (proven to work). Only invoke CGS Space switching when `eligibleWindows.count <= 1` AND after validating that a CG window is on a real different user Space (not space 0, not a system space).

The safest architecture: **never let the Space-switching code path interfere with same-Space AX cycling**. The AX raise path should be the default when multiple AX windows exist. Space switching should only activate when AX sees 0-1 windows and there's strong evidence of a window on another Space.
