import AppKit
import Foundation

enum HotkeyFormat {
    static func display(_ binding: HotkeyBinding) -> String {
        components(binding).joined(separator: " ")
    }

    static func components(_ binding: HotkeyBinding) -> [String] {
        if binding.isRightCommandTrigger {
            return ["⌘(R)"]
        }
        if binding.isRightOptionTrigger {
            return ["⌥(R)"]
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

        parts.append(keyCodeDisplayName(binding.keyCode))
        return parts
    }

    private static func keyCodeDisplayName(_ keyCode: Int) -> String {
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
        case 36: "↩"
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
        case 48: "⇥"
        case 49: "Space"
        case 50: "`"
        case 51: "⌫"
        case 53: "Esc"
        case 64: "F17"
        case 65: "."
        case 67: "*"
        case 69: "+"
        case 71: "Clear"
        case 72: "Vol+"
        case 73: "Vol-"
        case 74: "Mute"
        case 75: "/"
        case 76: "Enter"
        case 78: "-"
        case 79: "F18"
        case 80: "F19"
        case 81: "="
        case 82: "0"
        case 83: "1"
        case 84: "2"
        case 85: "3"
        case 86: "4"
        case 87: "5"
        case 88: "6"
        case 89: "7"
        case 90: "F20"
        case 91: "8"
        case 92: "9"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 105: "F13"
        case 106: "F16"
        case 107: "F14"
        case 109: "F10"
        case 111: "F12"
        case 113: "F15"
        case 114: "Help"
        case 115: "Home"
        case 116: "PgUp"
        case 117: "⌦"
        case 118: "F4"
        case 119: "End"
        case 120: "F2"
        case 121: "PgDn"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key\(keyCode)"
        }
    }
}
