import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var selectedID: UUID?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var selectedIndex: Int? {
        let id = selectedID ?? store.defaultID
        return store.presets.firstIndex { $0.id == id } ?? (store.presets.isEmpty ? nil : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Outside the Form so it never scrolls — the preview pane is a child
            // window pinned over this rect and wouldn't follow a scroll.
            if let i = selectedIndex {
                PresetPreview(preset: store.presets[i])
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            form
        }
        .frame(minWidth: 520, minHeight: 690)
    }

    private var form: some View {
        Form {
            Section("General") {
                LabeledContent("New filter shortcut") { ShortcutRecorder() }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                presetPicker
                if let i = selectedIndex {
                    PresetEditor(preset: $store.presets[i])
                    presetActions(for: store.presets[i])
                }
            } header: {
                HStack {
                    Text("Presets")
                    Spacer()
                    Text("\(store.presets.count) of \(Preset.maxCount)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } footer: {
                Text("New filters open with the default preset. Hover a filter to switch presets, or click it and press Tab or 1–\(Preset.maxCount).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private var presetPicker: some View {
        HStack(spacing: 6) {
            ForEach(store.presets) { p in
                let isSelected = p.id == (selectedID ?? store.defaultID)
                Button {
                    selectedID = p.id
                } label: {
                    HStack(spacing: 4) {
                        if p.id == store.defaultID {
                            Image(systemName: "star.fill").font(.system(size: 9))
                        }
                        Text(p.name.isEmpty ? "Untitled" : p.name).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 110)
                    .background(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1),
                                in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button {
                if let i = selectedIndex, let p = store.addPreset(copying: store.presets[i]) {
                    selectedID = p.id
                }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!store.canAdd)
            .help(store.canAdd ? "New preset (copies the selected one)" : "Up to \(Preset.maxCount) presets")
        }
    }

    private func presetActions(for p: Preset) -> some View {
        HStack {
            Button("Make Default") { store.defaultID = p.id }
                .disabled(p.id == store.defaultID)
            Button("Open a Filter") { (NSApp.delegate as? AppDelegate)?.newFilter() }
            Spacer()
            Button("Delete", role: .destructive) {
                store.deletePreset(p.id)
                selectedID = store.defaultID
            }
            .disabled(!store.canDelete)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this. Try again after moving Frost to Applications."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PresetEditor: View {
    @Binding var preset: Preset

    var body: some View {
        TextField("Name", text: $preset.name)

        // No `step:` — that draws a tick mark per value. Round on write instead.
        SliderRow(title: "Blur",
                  value: Binding(get: { preset.blur }, set: { preset.blur = $0.rounded() }),
                  range: 0...Preset.maxBlur, format: { "\(Int($0))" })

        LabeledContent("Tint") {
            HStack {
                Slider(value: $preset.tintOpacity, in: 0...1)
                Text(percent(preset.tintOpacity)).monospacedDigit().frame(width: 40, alignment: .trailing)
                ColorPicker("", selection: tintBinding, supportsOpacity: false).labelsHidden()
            }
        }
    }

    private var tintBinding: Binding<Color> {
        Binding(get: { Color(nsColor: preset.tint.nsColor) },
                set: { preset.tint = RGBA(NSColor($0)) })
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct ShortcutRecorder: View {
    @EnvironmentObject var store: Store
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button(recording ? "Type a shortcut…" : store.hotKey.display) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 120)
                if store.hotKey != .default && !recording {
                    Button("Reset") { store.resetHotKey(); message = nil }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        HotKey.shared.unregister()
        recording = true
        message = "Press Esc to cancel."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); message = nil; return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty || KeyNames.isFunctionKey(event.keyCode) else {
                message = "Include ⌘, ⌥, or ⌃."
                NSSound.beep()
                return nil
            }
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue,
                                 display: KeyNames.display(for: event))
            if HotKey.shared.register(combo) {
                store.hotKey = combo
                message = nil
            } else {
                message = "That shortcut is taken by another app."
            }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotKey.shared.register(store.hotKey)
        }
    }
}
