# Lelap

A tiny macOS menu bar app for display sleep and system sleep, without the Terminal.
*Lelap* is Indonesian for "sound asleep".

## Download

[**Download Lelap.zip**](https://github.com/singhamlagatari/Lelap/releases/latest/download/Lelap.zip) from the [latest release](https://github.com/singhamlagatari/Lelap/releases/latest).

1. Unzip it and move `Lelap.app` to your Applications folder.
2. Open Lelap. The app is not notarized by Apple, so macOS blocks the first launch. Go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to the message about Lelap, and confirm.
3. A desk lamp appears in the menu bar. Lelap has no Dock icon.

Requires macOS 13 Ventura or later. Runs natively on Apple Silicon and Intel.

## What it does

Click the desk lamp to open the panel.

- **On charger / On battery**: pick when the display turns off. On charger: ∞ (never), 5, 10, 15 or 30 minutes. On battery: 1, 2, 5, 10 or 15 minutes. The battery row only appears on Macs with a battery.
- **Keep display on**: keeps the screen awake until you turn it off, without changing any settings. The lamp in the menu bar lights up while it is on.
- **Prevent all sleep**: stops the Mac from sleeping, including when the lid is closed.
- **Restore original settings**: puts everything back in one click. On charger, the display turns off after 10 minutes and the Mac never sleeps when idle. On battery, the display turns off after 2 minutes, the Mac sleeps after 1 minute, and Low Power Mode is on. Prevent all sleep is turned off.
- **Open at login**: starts Lelap when you log in.

Changing a sleep setting asks for your administrator password in the standard macOS dialog. Lelap never sees or stores the password. Keep display on and Open at login need no password.

## How it works

- Reads the current settings with `pmset -g`, which needs no password.
- Writes them with `pmset`, run through the macOS administrator password dialog.
- Keep display on runs `caffeinate -d`, which stops when you turn the switch off or quit Lelap.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```bash
bash build.sh               # this Mac's architecture
bash build.sh --universal   # Apple Silicon and Intel
```

This creates `Lelap.app` next to the script. The whole app is one file, `Lelap.swift`.

## Uninstall

Turn off **Open at login**, quit Lelap (⌘Q), and move `Lelap.app` to the Trash. Sleep settings you changed stay as they are, so use **Restore original settings** first if you want them back.
