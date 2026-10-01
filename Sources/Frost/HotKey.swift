import AppKit
import Carbon.HIToolbox

/// Global shortcut via Carbon's RegisterEventHotKey — needs no Accessibility permission.
final class HotKey {
    static let shared = HotKey()

    var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var installed = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns false if the system refused the combo (usually: another app owns it).
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        installHandler()
        unregister()
        let id = EventHotKeyID(signature: OSType(0x46525354), id: 1) // 'FRST'
        let status = RegisterEventHotKey(combo.keyCode, carbonModifiers(combo.flags), id,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}

enum KeyNames {
    static func display(for event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName(event)
    }

    static func keyName(_ event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return chars.uppercased()
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        let fKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                               kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                               kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return fKeys.contains(Int(keyCode))
    }
}
