import Foundation

/// Tracks physical modifiers separately from voice gestures and Carbon key chords.
/// A modifier used with any other key cancels the ring without running its selection.
struct RingModifierHotkey {
    enum Event: Equatable {
        case began
        case ended
        case cancelled
    }

    private var modifiersDown = Set<Int>()
    private var keysDown = Set<Int>()
    private(set) var isActive = false

    mutating func handle(type: HotkeyPhysicalEventType, keyCode: Int, flags: UInt,
                         binding: HotkeyBinding?) -> Event? {
        switch type {
        case .keyDown:
            keysDown.insert(keyCode)
            return cancel()
        case .keyUp:
            keysDown.remove(keyCode)
            return nil
        case .flagsChanged:
            let mask = HotkeyBinding.modifierFlag(for: keyCode)
            guard mask != 0 else { return nil }
            let released = flags & mask == 0 || modifiersDown.contains(keyCode)
            if released { modifiersDown.remove(keyCode) } else { modifiersDown.insert(keyCode) }
            modifiersDown = modifiersDown.filter { flags & HotkeyBinding.modifierFlag(for: $0) != 0 }
            guard let binding, binding.isSingleModifierTrigger else { return cancel() }
            if isActive {
                if released, keyCode == binding.keyCode {
                    isActive = false
                    return .ended
                }
                return cancel()
            }
            guard !released, keyCode == binding.keyCode, flags == binding.modifierFlags,
                  modifiersDown == [keyCode], keysDown.isEmpty else { return nil }
            isActive = true
            return .began
        }
    }

    private mutating func cancel() -> Event? {
        guard isActive else { return nil }
        isActive = false
        return .cancelled
    }
}
