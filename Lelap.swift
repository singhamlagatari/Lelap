// Lelap — a tiny menu bar app for display sleep and system sleep.
//
// Single source file, SwiftUI MenuBarExtra, macOS 13+. Build: `bash build.sh`.
// Reads settings with /usr/bin/pmset (no admin rights needed) and writes them
// through the standard macOS administrator password dialog. See README.md.

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Power status

/// Current values read from `pmset`. Minutes are `nil` when not available.
struct PowerStatus: Equatable {
    /// `displaysleep` on charger. `nil` means the settings could not be read.
    var chargerMinutes: Int?
    /// `displaysleep` on battery. `nil` on Macs without a battery (Mac mini).
    var batteryMinutes: Int?
    /// `SleepDisabled 1` in `pmset -g`, set by `pmset -a disablesleep 1`.
    var sleepDisabled = false
    var onCharger = true

    var hasBattery: Bool { batteryMinutes != nil }

    /// Display sleep for the power source in use right now. 0 means never.
    var currentMinutes: Int? { onCharger ? chargerMinutes : batteryMinutes }
}

// MARK: - pmset helpers

let pmset = "/usr/bin/pmset"

/// Runs a tool and returns its standard output, or `nil` if it failed to run or exited non-zero.
func shell(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

/// Splits a pmset line into tokens. pmset separates keys and values with tabs
/// and/or spaces, so split on all whitespace and drop the empty pieces.
func words(_ line: String) -> [String] {
    line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
}

/// Builds the status from the output of `pmset -g custom`, `pmset -g` and `pmset -g ps`.
func parseStatus(custom: String, general: String, powerSource: String) -> PowerStatus {
    // `pmset -g custom`: one `displaysleep N` line per "… Power:" section.
    var displaySleep: [String: Int] = [:]
    var section = ""
    for line in custom.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let tokens = words(line)
        if trimmed.hasSuffix("Power:") {
            section = trimmed
        } else if tokens.count == 2, tokens[0] == "displaysleep", let minutes = Int(tokens[1]) {
            displaySleep[section] = minutes
        }
    }

    // `pmset -g`: a value may be followed by a note, as in
    // "displaysleep 10 (display sleep prevented by UniversalControl)", so read the second token.
    var activeDisplaySleep: Int?
    var sleepDisabled = false
    for line in general.components(separatedBy: .newlines) {
        let tokens = words(line)
        guard tokens.count >= 2 else { continue }
        if tokens[0] == "displaysleep" { activeDisplaySleep = Int(tokens[1]) }
        if tokens[0] == "SleepDisabled" { sleepDisabled = tokens[1] == "1" }
    }

    // Desktop Macs have no "Battery Power:" section.
    let battery = displaySleep["Battery Power:"]
    return PowerStatus(
        chargerMinutes: displaySleep["AC Power:"] ?? activeDisplaySleep,
        batteryMinutes: battery,
        sleepDisabled: sleepDisabled,
        onCharger: battery == nil || powerSource.contains("AC Power")
    )
}

/// Reads the current state. Needs no admin rights.
func readStatus() -> PowerStatus {
    parseStatus(
        custom: shell(pmset, ["-g", "custom"]) ?? "",
        general: shell(pmset, ["-g"]) ?? "",
        powerSource: shell(pmset, ["-g", "ps"]) ?? ""
    )
}

/// Runs a shell command as root behind the standard macOS password dialog.
/// The app never sees or stores the password. Build `command` from fixed
/// strings and integers only, never from user-typed text. Cancelling or
/// failing is silent on purpose: callers re-read the real state afterwards.
func runAdmin(_ command: String) {
    NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?
        .executeAndReturnError(nil)
}

// MARK: - Model

/// Single source of truth. Views render from it and call its methods.
final class PowerModel: ObservableObject {
    @Published private(set) var status = PowerStatus()
    /// "Open at login": whether this app is one of the user's login items.
    @Published private(set) var opensAtLogin = false

    /// The `caffeinate -d` child process behind "Keep display on".
    private var caffeinate: Process?
    private var quitObserver: NSObjectProtocol?

    /// On exactly while our caffeinate process runs. There is no separate flag.
    var keepAwake: Bool { caffeinate?.isRunning == true }

    init() {
        refresh()
        // Nothing may keep running after the app quits.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setKeepAwake(false)
        }
    }

    func refresh() {
        status = readStatus()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setDisplaySleep(minutes: Int, onCharger: Bool) {
        // Picking the value that is already set writes nothing, so no password prompt.
        guard minutes != (onCharger ? status.chargerMinutes : status.batteryMinutes) else { return }
        runAdmin("\(pmset) \(onCharger ? "-c" : "-b") displaysleep \(minutes)")
        refresh()
    }

    func setSleepDisabled(_ disabled: Bool) {
        guard disabled != status.sleepDisabled else { return }
        runAdmin("\(pmset) -a disablesleep \(disabled ? 1 : 0)")
        refresh()
    }

    func setKeepAwake(_ on: Bool) {
        if on, !keepAwake {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            // `-w <pid>`: caffeinate also ends if this app is killed or crashes.
            process.arguments = ["-d", "-w", String(ProcessInfo.processInfo.processIdentifier)]
            // If caffeinate ends by itself, let the UI catch up.
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            }
            if (try? process.run()) != nil { caffeinate = process }
        } else if !on, keepAwake {
            caffeinate?.terminate()
            caffeinate?.waitUntilExit()
        }
        // Always re-render, so a switch that could not change snaps back.
        objectWillChange.send()
    }

    func restoreDefaults() {
        let p = pmset
        runAdmin(status.hasBattery
            ? "\(p) -a disablesleep 0; \(p) -b displaysleep 2 sleep 1 lowpowermode 1; \(p) -c lowpowermode 0; \(p) -c displaysleep 10 sleep 0"
            : "\(p) -a disablesleep 0; \(p) -c displaysleep 10 sleep 0")
        refresh()
    }

    /// Adds or removes this app itself (not a helper) from the user's login items.
    /// Needs no admin rights.
    func setOpensAtLogin(_ on: Bool) {
        let app = SMAppService.mainApp
        if on { try? app.register() } else { try? app.unregister() }
        // Switched off earlier in System Settings: it has to be allowed there again.
        if on, app.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        opensAtLogin = app.status == .enabled
    }
}

// MARK: - Design tokens

extension Color {
    /// #F5AD33, the only accent. It always means "kept awake".
    static let glow = Color(red: 0.96, green: 0.68, blue: 0.20)
}

// MARK: - Views

struct PanelView: View {
    @ObservedObject var model: PowerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusHeader(status: model.status, keepAwake: model.keepAwake)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                MinutePicker(title: "On charger", values: [0, 5, 10, 15, 30],
                             selected: model.status.chargerMinutes) {
                    model.setDisplaySleep(minutes: $0, onCharger: true)
                }
                if model.status.hasBattery {
                    MinutePicker(title: "On battery", values: [1, 2, 5, 10, 15],
                                 selected: model.status.batteryMinutes) {
                        model.setDisplaySleep(minutes: $0, onCharger: false)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                SwitchRow(title: "Keep display on", detail: "Temporarily, settings unchanged",
                          isOn: model.keepAwake, onChange: model.setKeepAwake)
                SwitchRow(title: "Prevent all sleep", detail: "Including when the lid is closed",
                          isOn: model.status.sleepDisabled, onChange: model.setSleepDisabled)
                RestoreButton(hasBattery: model.status.hasBattery, action: model.restoreDefaults)
            }
            Divider()
            AppSection(opensAtLogin: model.opensAtLogin, onLoginChange: model.setOpensAtLogin)
        }
        .padding(18)
        .frame(width: 300)
        .onAppear(perform: model.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }
}

/// Answers "will my screen turn off?". The Mac icon glows while the display is kept on.
struct StatusHeader: View {
    let status: PowerStatus
    let keepAwake: Bool

    private var isAwake: Bool { keepAwake || status.currentMinutes == 0 }

    private var text: (title: String, detail: String) {
        let source = status.onCharger ? "on charger" : "on battery"
        if keepAwake { return ("Display stays on", "Until you turn it off") }
        guard let minutes = status.currentMinutes else {
            return ("Couldn't read display settings", "Open this panel again to retry")
        }
        if minutes == 0 { return ("Display never turns off", "While \(source)") }
        return ("Display turns off in \(minutes) min", "When idle \(source)")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.hasBattery ? "laptopcomputer" : "display")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isAwake ? Color.glow : Color.secondary)
                .shadow(color: isAwake ? Color.glow.opacity(0.55) : .clear, radius: 10)
                .frame(width: 44)
                .animation(.easeOut(duration: 0.3), value: isAwake)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).font(.system(size: 15, weight: .semibold))
                Text(text.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                if status.sleepDisabled {
                    Text("System sleep is disabled").font(.system(size: 12)).foregroundStyle(Color.glow)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row of equal-width minute chips. 0 is shown as ∞ ("Never").
struct MinutePicker: View {
    let title: String
    let values: [Int]
    let selected: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("minutes").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 5) {
                ForEach(values, id: \.self) { chip($0) }
            }
        }
    }

    private func chip(_ minutes: Int) -> some View {
        let isSelected = minutes == selected
        let name = minutes == 0 ? "Never" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Button {
            if !isSelected { onSelect(minutes) }
        } label: {
            Text(minutes == 0 ? "∞" : String(minutes))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(shape.fill(Color.primary.opacity(isSelected ? 0.85 : 0.06)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Title (and an optional description) on the left, a small switch on the right.
struct SwitchRow: View {
    let title: String
    var detail: String?
    let isOn: Bool
    /// Glow means "kept awake". Switches with any other meaning stay neutral.
    var tint: Color = .glow
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(get: { isOn }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(tint)
        }
    }
}

/// Puts every power setting above back to the original values (asks for the password).
struct RestoreButton: View {
    let hasBattery: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Restore original settings", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .help(hasBattery
            ? "On charger: display off after 10 min, Mac never sleeps when idle. On battery: display off after 2 min, Mac sleeps after 1 min, Low Power Mode on. Prevent all sleep off."
            : "Display off after 10 min, Mac never sleeps when idle. Prevent all sleep off.")
    }
}

/// App-level controls, kept apart from the power settings above.
struct AppSection: View {
    let opensAtLogin: Bool
    let onLoginChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SwitchRow(title: "Open at login", isOn: opensAtLogin, tint: .secondary, onChange: onLoginChange)
            HStack {
                Button("Quit Lelap") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                Spacer()
                Text("⌘Q").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - App

@main
struct LelapApp: App {
    @StateObject private var model = PowerModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // A desk lamp, lit while "Keep display on" is active.
            Image(systemName: model.keepAwake ? "lamp.desk.fill" : "lamp.desk")
                .accessibilityLabel("Lelap")
        }
        .menuBarExtraStyle(.window)
    }
}
