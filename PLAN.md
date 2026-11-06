# Lelap — Implementation Plan

A tiny macOS menu bar app for controlling display sleep and system sleep without the Terminal. *Lelap* is Indonesian for "sound asleep".

This document is the full spec. Build exactly what is described here; where something is not specified, choose the simplest option that matches the existing behavior and note the choice in the final summary.

---

## 1. Goal

The user owns a MacBook and a Mac mini. They want one small app that:

- shows, at a glance, whether the display will turn off and when;
- sets how long the display waits before turning off, separately for "on charger" and "on battery";
- keeps the display on temporarily without changing any saved settings;
- can disable system sleep completely (including lid closed) and turn it back on;
- restores their original settings in one click;
- can open automatically at login.

The app must feel like part of macOS: quiet, native, no Dock icon, no main window.

## 2. Constraints

- **Language:** Swift 5.9+, SwiftUI with `MenuBarExtra` (`.window` style). AppKit only where SwiftUI has no equivalent.
- **Target:** macOS 13 Ventura or later. Must run on both Apple Silicon and Intel.
- **No dependencies.** No Swift packages, no Xcode project required. Build with `swiftc` from Xcode Command Line Tools.
- **Single source file:** `Lelap.swift`, plus `build.sh` that produces `Lelap.app`.
- **No Dock icon:** `LSUIElement = true` in `Info.plist`.
- **No persistent background helpers.** No LaunchDaemons, no privileged helper tools. "Open at login" registers the app itself with `SMAppService.mainApp`, not a helper.
- **All UI text in English.** Sentence case, plain verbs.

## 3. File layout

```
Lelap/
├── Lelap.swift        # entire app
├── build.sh           # compiles and bundles Lelap.app
└── PLAN.md            # this file
```

## 4. System interface

All settings are read and written through `/usr/bin/pmset`. Keep this logic in plain functions, separate from the UI.

### 4.1 Reading state (no admin rights needed)

| Value | Command | How to parse |
|---|---|---|
| Display sleep on charger | `pmset -g custom` | `displaysleep N` inside the `AC Power:` section |
| Display sleep on battery | `pmset -g custom` | `displaysleep N` inside the `Battery Power:` section |
| System sleep disabled | `pmset -g` | line `SleepDisabled N`, `1` means disabled |
| Current power source | `pmset -g ps` | output contains `AC Power` → on charger |

Parsing rules (important — the previous version had a bug here):

- `pmset` separates keys and values with **tabs and/or spaces**. Split on all whitespace (`CharacterSet.whitespaces`) and drop empty pieces. Never split on `" "` only.
- Section headers are lines ending in `Power:`. Track the current section while iterating.
- Only accept a `displaysleep` line with exactly two tokens when reading `pmset -g custom`.
- In `pmset -g`, the `displaysleep` line may have a trailing note, e.g. `displaysleep 10 (display sleep prevented by UniversalControl)`. Take the second token only.
- **Desktop Macs** (Mac mini) have no `Battery Power:` section. Treat battery value as `nil` and hide all battery UI. If no `AC Power:` section exists either, fall back to the `displaysleep` value from `pmset -g`.
- If `SleepDisabled` is absent, treat it as `false`.

### 4.2 Writing state (admin rights needed)

Run commands through `NSAppleScript`:

```
do shell script "<command>" with administrator privileges
```

This shows the standard macOS password dialog. Do not cache or store the password.

| Action | Command |
|---|---|
| Set display sleep on charger | `pmset -c displaysleep N` |
| Set display sleep on battery | `pmset -b displaysleep N` |
| Disable all system sleep | `pmset -a disablesleep 1` |
| Re-enable system sleep | `pmset -a disablesleep 0` |
| Restore original settings (MacBook) | `pmset -a disablesleep 0; pmset -b displaysleep 2 sleep 1 lowpowermode 1; pmset -c lowpowermode 0; pmset -c displaysleep 10 sleep 0` |
| Restore original settings (desktop) | `pmset -a disablesleep 0; pmset -c displaysleep 10 sleep 0` |

Rules:

- Only interpolate integers and fixed strings into commands. Never interpolate user-typed text.
- If the user cancels the password dialog, do nothing and leave the UI showing the real current state.
- After every write attempt (success or cancel), re-read state from `pmset`.

### 4.3 Keep display awake temporarily (no admin rights)

- Start `/usr/bin/caffeinate -d -w <app pid>` as a child `Process`. `-w` makes caffeinate end on its own if the app is killed or crashes.
- Stop it by calling `terminate()` on that process.
- Always terminate it on `NSApplication.willTerminateNotification`, so nothing keeps running after the app quits.
- The "on" state is `process?.isRunning == true`, never a separate stored flag.

### 4.4 Open at login (no admin rights)

- On/off state: `SMAppService.mainApp.status == .enabled`, read on every `refresh()`.
- Turn on: `SMAppService.mainApp.register()`. Turn off: `SMAppService.mainApp.unregister()`.
- If the status is `.requiresApproval` after turning on (the user switched it off in System Settings earlier), open System Settings → Login Items with `SMAppService.openSystemSettingsLoginItems()`.
- After every attempt, re-read the status so the switch shows the real state.

## 5. Architecture

```
PowerStatus (struct)      current values read from pmset
pmset helpers (funcs)     shell(), words(), parseStatus(), readStatus(), runAdmin()
PowerModel (ObservableObject)
    status: PowerStatus
    keepAwake: Bool
    opensAtLogin: Bool
    refresh()
    setDisplaySleep(minutes:onCharger:)
    setSleepDisabled(_:)
    setKeepAwake(_:)
    restoreDefaults()
    setOpensAtLogin(_:)
Views
    PanelView
      StatusHeader
      MinutePicker (x2)
      SwitchRow (x2)
      RestoreButton
      AppSection (SwitchRow "Open at login" + Quit)
LelapApp (@main)          MenuBarExtra { PanelView } label: { icon }
```

- `PowerModel.refresh()` runs whenever the panel appears and whenever its window becomes key (`NSWindow.didBecomeKeyNotification`), so the panel always reflects the real state, including changes made in System Settings or the Terminal.
- Model state is the single source of truth. Controls never hold their own state; they render from the model and call model methods.

## 6. Design

### 6.1 Concept: "desk lamp"

The app answers one question: *will my screen turn off?* The whole panel is calm and monochrome. Exactly one element carries color: the Mac icon in the header, which glows warm amber like a lamp when the display is being kept on, and is grey when behavior is normal. Status should be readable with a glance, without reading numbers.

### 6.2 Tokens

| Token | Value | Use |
|---|---|---|
| Background | system `.window` material from `MenuBarExtra` | panel surface, follows light/dark |
| Text primary | `Color.primary` | titles, labels |
| Text secondary | `Color.secondary` | descriptions, footer |
| Text tertiary | `.tertiary` style | "minutes" unit label |
| Glow | `#F5AD33` (`Color(red: 0.96, green: 0.68, blue: 0.20)`) | the **only** accent; means "kept awake" |
| Selected chip | `Color.primary.opacity(0.85)` fill, window background color text | selected minute value |
| Unselected chip | `Color.primary.opacity(0.06)` fill | other minute values |

Rule: the glow color appears only for "awake" meanings — header icon, its soft shadow, the two awake switches (Keep display on, Prevent all sleep) when on, and the "System sleep is disabled" note. Minute chips never use it. The "Open at login" switch is not an awake meaning, so it uses the neutral `.secondary` tint.

### 6.3 Typography

System font (SF Pro) only.

| Role | Size / weight |
|---|---|
| Status title | 15 pt semibold |
| Row title | 13 pt regular |
| Section label | 12 pt medium |
| Description, footer | 11–12 pt regular, secondary |
| Chip numbers | 12 pt, monospaced digits; selected chip semibold |

### 6.4 Layout (panel width 300 pt, padding 18 pt, section spacing 16 pt)

```
┌────────────────────────────────────┐
│  [mac]  Display turns off in 10 min │  status title
│         When idle on charger        │  status detail
│         System sleep is disabled    │  only when SleepDisabled = 1
├────────────────────────────────────┤
│  On charger                minutes │
│  [ ∞ ][ 5 ][■10■][ 15 ][ 30 ]      │
│                                    │
│  On battery                minutes │  hidden on desktop Macs
│  [ 1 ][■2■][ 5 ][ 10 ][ 15 ]       │
├────────────────────────────────────┤
│  Keep display on             ( ●) │
│  Temporarily, settings unchanged   │
│  Prevent all sleep           (● ) │
│  Including when the lid is closed  │
│  ↺ Restore original settings       │  power settings action
├────────────────────────────────────┤
│  Open at login               (● ) │  app settings, neutral switch
│  Quit Lelap                    ⌘Q │
└────────────────────────────────────┘
```

Order follows frequency of use: status (seen every time), minute settings (changed sometimes), switches and restore (situational), app section (rare, quietest). Restore and Quit are different kinds of action, so they never share a row: Restore sits with the power settings it resets, Quit sits with the app settings.

### 6.5 Components

**Menu bar icon**
- A desk lamp, matching the concept: SF Symbol `lamp.desk` normally; `lamp.desk.fill` (the lamp is lit) while "Keep display on" is active.

**StatusHeader**
- Icon: `laptopcomputer` if the Mac has a battery, otherwise `display`. 30 pt, light weight, 44 pt column.
- "Awake" = keep-awake is active, or the display sleep value for the current power source is `0`.
- Awake: icon in glow color with a soft glow shadow (glow at ~55% opacity, radius 10). Not awake: secondary color, no shadow.
- Animate the change with `.easeOut(duration: 0.3)`. This is the only animation in the app.

**MinutePicker**
- Row of equal-width chips, 5 pt gaps, height 26 pt, continuous corner radius 7 pt.
- Charger values: `0, 5, 10, 15, 30`. Battery values: `1, 2, 5, 10, 15`.
- `0` is displayed as `∞` with tooltip "Never". Other chips get tooltip "N minutes".
- Tapping the already-selected chip does nothing (no password prompt).
- If the current value is not in the list (e.g. 3), no chip is selected; the header still states the real value.

**SwitchRow**
- Title and an optional description on the left, a small `.switch` toggle on the right. Tinted with the glow color for the two awake switches, neutral otherwise.
- The toggle binding reads from the model and calls a model method on change.

**RestoreButton**
- Plain text button with the `arrow.counterclockwise` icon, 12 pt, secondary, on its own row right under the two awake switches.
- Tooltip lists the values it restores (MacBook or desktop).

**AppSection**
- "Open at login": a SwitchRow without description, neutral tint.
- "Quit Lelap": plain text button, 12 pt, secondary, with a tertiary "⌘Q" hint on the right. ⌘Q works while the panel is open.

### 6.6 Copy

| Situation | Title | Detail |
|---|---|---|
| Keep display on is active | Display stays on | Until you turn it off |
| Current source value is 0 | Display never turns off | While on charger / While on battery |
| Current source value is N | Display turns off in N min | When idle on charger / When idle on battery |
| State could not be read | Couldn't read display settings | Open this panel again to retry |

| Element | Text |
|---|---|
| Charger section | On charger |
| Battery section | On battery |
| Unit label | minutes |
| Keep-awake switch | Keep display on — detail: Temporarily, settings unchanged |
| Disable-sleep switch | Prevent all sleep — detail: Including when the lid is closed |
| Sleep-disabled note | System sleep is disabled |
| Restore button | Restore original settings |
| Login switch | Open at login |
| Quit button | Quit Lelap (hint: ⌘Q) |

## 7. Behavior and edge cases

- **Password dialog closes the panel.** This is expected with `MenuBarExtra`. When the user reopens it, `refresh()` shows the new state. Do not try to keep the panel open.
- **Password cancelled.** No error alert. State re-reads and controls snap back.
- **Power source changes while panel is open.** The next refresh (reopen or key-window event) updates the header text.
- **Changes made outside the app** (System Settings, Terminal) appear on next open.
- **Desktop Mac.** No battery picker, header icon is `display`, restore uses the desktop command.
- **App quits.** `caffeinate` child process is terminated. `pmset` settings persist, which is intended.
- **Open at login was switched off in System Settings.** Turning it on opens System Settings → Login Items so the user can allow it there; the switch shows the real status on the next refresh.
- **Open at login points at the copy that turned it on.** Turn it on from the installed copy (`~/Applications/Lelap.app`), not from the build folder.

## 8. Build script (`build.sh`)

1. `set -e`, `cd` to the script's folder.
2. Remove any old `Lelap.app`, create `Lelap.app/Contents/MacOS`.
3. Compile (`-target` keeps the minimum at macOS 13; without it `swiftc` requires the macOS version of the build Mac):
   ```
   swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13" Lelap.swift -o Lelap.app/Contents/MacOS/Lelap
   ```
4. Write `Contents/Info.plist` with: `CFBundleName` Lelap, `CFBundleIdentifier` com.user.lelap, `CFBundleExecutable` Lelap, `CFBundlePackageType` APPL, `CFBundleShortVersionString` 1.0, `LSMinimumSystemVersion` 13.0, `LSUIElement` true.
5. Ad-hoc sign: `codesign --force --sign - Lelap.app`.
6. Print the path of the finished app.

Optional flag `--universal`: compile twice with `-target arm64-apple-macos13` and `-target x86_64-apple-macos13`, then merge with `lipo -create`.

## 9. Acceptance checklist

Verify each item on a real Mac before calling the work done. Report any item that could not be verified.

- [ ] `bash build.sh` completes with no errors or warnings.
- [ ] App launches with a menu bar icon and no Dock icon.
- [ ] Header and chips match `pmset -g custom` exactly on first open.
- [ ] `sudo pmset -a disablesleep 1` in Terminal → reopen panel → switch is on and "System sleep is disabled" note appears. (Regression test for the tab-parsing bug.)
- [ ] Selecting a chip prompts for a password, then `pmset -g custom` shows the new value.
- [ ] Cancelling the password prompt leaves the setting unchanged and the UI correct.
- [ ] Tapping the already-selected chip does not prompt for a password.
- [ ] "Keep display on" starts `caffeinate -d` (visible in `pmset -g assertions` as `PreventUserIdleDisplaySleep 1`), the menu bar lamp becomes `lamp.desk.fill`, header glows.
- [ ] Turning it off, or quitting the app, ends the `caffeinate` process.
- [ ] "Restore original settings" produces: battery `displaysleep 2`, `sleep 1`, `lowpowermode 1`; charger `displaysleep 10`, `sleep 0`, `lowpowermode 0`; `SleepDisabled` 0.
- [ ] On a Mac without a battery, the battery picker is hidden and restore does not fail.
- [ ] Panel looks correct in both light and dark mode.
- [ ] Restore and Quit sit in different sections; ⌘Q quits while the panel is open.
- [ ] "Open at login" on → Lelap appears in System Settings → General → Login Items; off → it is removed.

## 10. Out of scope

- Privileged helper tool or SMAppService daemon to avoid repeated password prompts.
- Automatic switching based on power source, per-display control, screen saver settings, localization.
