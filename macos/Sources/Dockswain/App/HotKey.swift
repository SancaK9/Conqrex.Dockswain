import AppKit
import Carbon.HIToolbox

/// A single global hotkey via Carbon's RegisterEventHotKey. Works system-wide with
/// no Accessibility permission. Stores keyCode + Cocoa modifier flags; re-register to
/// change it. `keyCode == nil` means "no shortcut".
final class HotKey {
    static let shared = HotKey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onFire: (() -> Void)?

    private init() {}

    /// (keyCode, modifierFlags) persisted in UserDefaults, or nil if unset.
    static var stored: (keyCode: UInt32, modifiers: NSEvent.ModifierFlags)? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "hotkeyKeyCode") != nil else { return nil }
            let code = UInt32(d.integer(forKey: "hotkeyKeyCode"))
            let mods = NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "hotkeyMods")))
            return (code, mods)
        }
        set {
            let d = UserDefaults.standard
            if let v = newValue {
                d.set(Int(v.keyCode), forKey: "hotkeyKeyCode")
                d.set(Int(v.modifiers.rawValue), forKey: "hotkeyMods")
            } else {
                d.removeObject(forKey: "hotkeyKeyCode")
                d.removeObject(forKey: "hotkeyMods")
            }
        }
    }

    func setCallback(_ cb: @escaping () -> Void) { onFire = cb }

    /// (Re)register from the stored shortcut. Unregisters first; no-op if unset.
    func reload() {
        unregister()
        guard let (keyCode, mods) = HotKey.stored else { return }
        register(keyCode: keyCode, carbonMods: HotKey.carbonFlags(from: mods))
    }

    private func register(keyCode: UInt32, carbonMods: UInt32) {
        // Install the app-wide handler once.
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let this = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
                DispatchQueue.main.async { me.onFire?() }
                return noErr
            }, 1, &spec, this, &handler)
        }
        var id = EventHotKeyID(signature: OSType(0x434E5148 /* 'CNQH' */), id: 1)
        RegisterEventHotKey(keyCode, carbonMods, id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }

    /// Cocoa modifier flags → Carbon modifier mask.
    static func carbonFlags(from f: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if f.contains(.command) { c |= UInt32(cmdKey) }
        if f.contains(.option)  { c |= UInt32(optionKey) }
        if f.contains(.control) { c |= UInt32(controlKey) }
        if f.contains(.shift)   { c |= UInt32(shiftKey) }
        return c
    }

    /// Human-readable like "⌘⇧D" for the settings UI.
    static func describe(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (keyName(keyCode) ?? "Key\(keyCode)")
    }

    private static func keyName(_ code: UInt32) -> String? {
        let map: [UInt32: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",
            12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",
            37:"L",38:"J",40:"K",45:"N",46:"M",
            18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
            49:"Space",36:"↩",53:"Esc",48:"⇥",
            122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
            101:"F9",109:"F10",103:"F11",111:"F12"
        ]
        return map[code]
    }
}
