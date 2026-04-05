import AppKit
import Foundation

enum HotkeyFormat {
    static func display(_ binding: HotkeyBinding) -> String {
        components(binding).joined(separator: " ")
    }

    static func components(_ binding: HotkeyBinding) -> [String] {
        if binding.isRightCommandTrigger {
            return ["Right Command"]
        }
        if binding.isFunctionTrigger {
            return ["Fn"]
        }

        let flags = NSEvent.ModifierFlags(rawValue: binding.modifierFlags)
        var parts = [
            flags.contains(.function) ? "Fn" : nil,
            flags.contains(.control) ? "⌃" : nil,
            flags.contains(.option) ? "⌥" : nil,
            flags.contains(.shift) ? "⇧" : nil,
            flags.contains(.command) ? "⌘" : nil,
        ].compactMap(\.self)

        parts.append(keyCodeToName(binding.keyCode))
        return parts
    }

    private static func keyCodeToName(_ keyCode: Int) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "Return"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "Tab"
        case 49: "Space"
        case 50: "`"
        case 51: "Delete"
        case 53: "Escape"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 109: "F10"
        case 111: "F12"
        case 118: "F4"
        case 120: "F2"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key\(keyCode)"
        }
    }
}
