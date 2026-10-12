import AppKit

enum TypefluxSpotlightKey: Equatable {
    case move(Int)
    case activate(plainText: Bool)
    case quick(Int)
    case dismiss

    static func resolve(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Self? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if flags.isEmpty {
            switch keyCode {
            case 126: return .move(-1)
            case 125: return .move(1)
            case 36, 76: return .activate(plainText: false)
            case 53: return .dismiss
            default: return nil
            }
        }
        guard flags == .command else { return nil }
        if keyCode == 36 || keyCode == 76 {
            return .activate(plainText: true)
        }
        if let characters, characters.count == 1, let number = Int(characters), (1 ... 9).contains(number) {
            return .quick(number)
        }
        return nil
    }
}
