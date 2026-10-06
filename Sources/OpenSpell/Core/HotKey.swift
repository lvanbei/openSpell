import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: virtual key code + Carbon modifier mask.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultCombo = KeyCombo(keyCode: UInt32(kVK_Space),
                                       carbonModifiers: UInt32(cmdKey | shiftKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        // Require a "real" modifier unless it's a function key.
        let isFunctionKey = KeyCombo.functionKeyNames[Int(code)] != nil
        let hasStrongModifier = mods & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasStrongModifier || isFunctionKey else { return nil }
        self.init(keyCode: code, carbonModifiers: mods)
    }

    var modifierString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var keyString: String {
        if let name = KeyCombo.specialKeyNames[Int(keyCode)] { return name }
        if let name = KeyCombo.functionKeyNames[Int(keyCode)] { return name }
        return KeyCombo.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    var displayString: String { modifierString + keyString }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Translate a key code with the current keyboard layout (so AZERTY etc. display correctly).
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// Registers a single system-wide hotkey through the Carbon Event Manager.
/// (Doesn't require any permission, unlike an event tap.)
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onTrigger: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var current: KeyCombo?

    /// Last RegisterEventHotKey result (non-nil = failed, e.g. another app owns the combo).
    private(set) var registrationError: OSStatus?
    var isRegistered: Bool { hotKeyRef != nil }
    var currentCombo: KeyCombo? { current }

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyCenter.shared.onTrigger?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    func register(_ combo: KeyCombo?) {
        unregister()
        current = combo
        registrationError = nil
        guard let combo else { return }
        let id = EventHotKeyID(signature: OSType(0x4F53_504C) /* 'OSPL' */, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            registrationError = status
            NSLog("OpenSpell: RegisterEventHotKey failed (\(status)) for \(combo.displayString)")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// Temporarily disable while the user records a new shortcut.
    func suspend() { unregister() }
    func resume() { register(current) }
}
