import AppKit
import Carbon.HIToolbox

struct KeyChoice: Codable, Equatable {
    var enabled = true, control = true, option = true, shift = false, command = false
    var key = "A"
    var text: String {
        [control ? "⌃" : "", option ? "⌥" : "", shift ? "⇧" : "", command ? "⌘" : "", key].joined()
    }
    func displayText(registered: Bool) -> String {
        guard enabled else { return "Disabled" }
        return registered ? text : "\(text) (unavailable)"
    }
    var modifiers: UInt32 {
        UInt32(
            (control ? controlKey : 0) | (option ? optionKey : 0) | (shift ? shiftKey : 0) | (command ? cmdKey : 0)
        )
    }
    var isVoiceOverReadAll: Bool { key == "A" && modifiers == UInt32(controlKey | optionKey) }
    static let keys: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7,
        "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "Space": kVK_Space,
    ]
}

final class GlobalKey {
    private static let signature: OSType = 0x4249_434E
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    var isRegistered: Bool { registration != nil }
    private var active: KeyChoice?
    private let fire: () -> Void
    init(fire: @escaping () -> Void) {
        self.fire = fire
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, raw in
                guard let event, let raw else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<GlobalKey>.fromOpaque(raw).takeUnretainedValue().pressed(event)
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    private func pressed(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard let active, let code = KeyChoice.keys[active.key],
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
            id.signature == Self.signature, id.id == UInt32(code) + active.modifiers,
            !(active.isVoiceOverReadAll && NSWorkspace.shared.isVoiceOverEnabled)
        else { return OSStatus(eventNotHandledErr) }
        fire()
        return noErr
    }
    private func register(_ code: UInt32, modifiers: UInt32) throws -> EventHotKeyRef {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let shortcuts = list?.takeRetainedValue() as? [[String: Any]]
        else { throw Problem("Could not check macOS keyboard shortcuts. Try again.") }
        if shortcuts.contains(where: {
            $0[kHISymbolicHotKeyEnabled as String] as? Bool == true
                && $0[kHISymbolicHotKeyCode as String] as? UInt32 == code
                && $0[kHISymbolicHotKeyModifiers as String] as? UInt32 == modifiers
        }) {
            throw Problem("macOS uses that shortcut. Choose another combination.")
        }
        let id = EventHotKeyID(signature: Self.signature, id: code + modifiers)
        let target = GetApplicationEventTarget()
        // Probe for exclusive owners, then share the shortcut so other apps keep receiving it.
        var probe: EventHotKeyRef?
        guard RegisterEventHotKey(code, modifiers, id, target, UInt32(kEventHotKeyExclusive), &probe) == noErr,
            let probe
        else { throw Problem("That shortcut is already in use. Choose another combination.") }
        UnregisterEventHotKey(probe)
        var token: EventHotKeyRef?
        guard RegisterEventHotKey(code, modifiers, id, target, UInt32(kEventHotKeyNoOptions), &token) == noErr,
            let token
        else { throw Problem("Could not register that shortcut. Choose another combination.") }
        return token
    }
    func use(_ choice: KeyChoice, voiceOverEnabled: Bool = NSWorkspace.shared.isVoiceOverEnabled) throws -> String {
        guard choice.enabled else {
            release()
            return "The global shortcut is disabled."
        }
        if choice.isVoiceOverReadAll && voiceOverEnabled {
            release()
            return "VoiceOver is using ⌃⌥A for Read All. You can open BetterIcon from the menu bar."
        }
        if active != choice {
            guard handler != nil, let code = KeyChoice.keys[choice.key],
                choice.option || choice.control || choice.command
            else { throw Problem("Choose Control, Option, or Command and a key.") }
            let replacement = try register(UInt32(code), modifiers: choice.modifiers)
            release()
            registration = replacement
            active = choice
        }
        return "Registered \(choice.text)"
    }
    private func release() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        active = nil
    }
    deinit {
        release()
        if let handler { RemoveEventHandler(handler) }
    }
}
