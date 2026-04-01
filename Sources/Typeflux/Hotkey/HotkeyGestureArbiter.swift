import Foundation

enum HotkeyGestureEvent: Equatable {
    case begin(HotkeyAction)
    case end(HotkeyAction)
    case personaRequested
}

struct HotkeyGestureArbiter {
    enum Phase: Equatable {
        case idle
        case pendingModifierActivation
        case active(HotkeyAction)
    }

    private(set) var phase: Phase = .idle

    var hasPendingModifierActivation: Bool {
        phase == .pendingModifierActivation
    }

    mutating func handleKeyDown(
        keyCode: Int,
        modifierFlags: UInt,
        isRepeat: Bool,
        activationHotkey: HotkeyBinding,
        askHotkey: HotkeyBinding,
        personaHotkey: HotkeyBinding
    ) -> [HotkeyGestureEvent] {
        guard !isRepeat else { return [] }

        if askHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            phase = .active(.ask)
            return [.begin(.ask)]
        }

        if !activationHotkey.isModifierOnlyTrigger,
           activationHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags),
           phase == .idle {
            phase = .active(.activation)
            return [.begin(.activation)]
        }

        if personaHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            return [.personaRequested]
        }

        return []
    }

    mutating func handleKeyUp(
        keyCode: Int,
        activationHotkey: HotkeyBinding,
        askHotkey: HotkeyBinding
    ) -> [HotkeyGestureEvent] {
        switch phase {
        case .active(.activation):
            guard !activationHotkey.isModifierOnlyTrigger else { return [] }
            guard activationHotkey.keyCode == keyCode else { return [] }
            phase = .idle
            return [.end(.activation)]
        case .active(.ask):
            guard askHotkey.keyCode == keyCode else { return [] }
            phase = .idle
            return [.end(.ask)]
        default:
            return []
        }
    }

    mutating func handleFlagsChanged(
        keyCode: Int,
        modifierFlags: UInt,
        activationHotkey: HotkeyBinding,
        askHotkey: HotkeyBinding
    ) -> [HotkeyGestureEvent] {
        guard activationHotkey.isModifierOnlyTrigger else { return [] }

        let isActivationModifierEvent = keyCode == activationHotkey.keyCode
        let activationModifierDown = isActivationModifierEvent && modifierFlags == activationHotkey.modifierFlags

        if activationModifierDown, phase == .idle {
            if shouldDeferModifierActivation(activationHotkey: activationHotkey, askHotkey: askHotkey) {
                phase = .pendingModifierActivation
                return []
            }

            phase = .active(.activation)
            return [.begin(.activation)]
        }

        guard isActivationModifierEvent, !activationModifierDown else { return [] }

        switch phase {
        case .pendingModifierActivation:
            phase = .idle
            return []
        case .active(.activation):
            phase = .idle
            return [.end(.activation)]
        default:
            return []
        }
    }

    mutating func handlePendingModifierActivationTimeout() -> [HotkeyGestureEvent] {
        guard phase == .pendingModifierActivation else { return [] }
        phase = .active(.activation)
        return [.begin(.activation)]
    }

    private func shouldDeferModifierActivation(
        activationHotkey: HotkeyBinding,
        askHotkey: HotkeyBinding
    ) -> Bool {
        activationHotkey.isModifierOnlyTrigger
            && askHotkey.modifierFlags == activationHotkey.modifierFlags
            && askHotkey.keyCode != activationHotkey.keyCode
    }
}
