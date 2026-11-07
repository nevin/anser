import Foundation

/// A global shortcut written like "ctrl+`", "alt+space" or "cmd+shift+f12",
/// turned into a macOS virtual key code and Carbon modifier bits.
public struct HotKey: Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier flags: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096.
    public var modifiers: UInt32
    /// The shortcut as people read it: "⌃`".
    public var display: String

    public static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "enter": 36, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "backspace": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    /// nil when the text isn't a usable global shortcut (unknown key, or a
    /// plain key with no modifier, which would steal typing from every app).
    public static func parse(_ text: String) -> HotKey? {
        let norm = AnserConfig.normalizeKey(text.trimmingCharacters(in: .whitespaces))
        let parts = norm.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, !key.isEmpty, let code = keyCodes[key] else { return nil }
        var mods: UInt32 = 0
        var label = ""
        for m in parts.dropLast() {
            switch m {
            case "ctrl": mods |= 4096; label += "⌃"
            case "alt": mods |= 2048; label += "⌥"
            case "shift": mods |= 512; label += "⇧"
            case "cmd": mods |= 256; label += "⌘"
            default: return nil
            }
        }
        let isFunctionKey = key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
        guard mods != 0 || isFunctionKey else { return nil }
        // Shift alone would block typing capitals or symbols everywhere.
        guard mods != 512 || isFunctionKey else { return nil }
        let names = ["space": "Space", "enter": "↩", "return": "↩", "tab": "⇥", "backspace": "⌫", "escape": "⎋"]
        return HotKey(keyCode: code, modifiers: mods, display: label + (names[key] ?? key.uppercased()))
    }
}
