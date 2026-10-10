import Foundation

enum HotkeyPhysicalEventType: Equatable {
    case keyDown
    case keyUp
    case flagsChanged
}

enum HotkeyGestureEvent: Equatable {
    case auxiliaryPromoted
    case activationTapped
    case begin(HotkeyAction)
    case end(HotkeyAction)
    case cancel(HotkeyAction)
    case personaRequested
    case historyRequested
    case screenshotRequested
}

struct HotkeyGestureArbiter {
    static let doubleTapMaximumInterval: TimeInterval = 0.45

    enum Phase: Equatable {
        case idle
        case pendingModifierActivation
        case active(HotkeyAction)
    }

    private(set) var phase: Phase = .idle
    private var pressedModifierKeys = Set<Int>()
    private var auxiliaryIsDown = false
    private var auxiliaryLastTap: TimeInterval?
    private var auxiliaryReleaseKeys = Set<Int>()
    private var auxiliaryConsumedModifierKeys = Set<Int>()
    private var activationSettled = false
    private var lastModifierTap: ModifierTap?
    private var suppressCurrentModifierTap = false

    mutating func settleActivationGesture() {
        lastModifierTap = nil
        auxiliaryLastTap = nil
        activationSettled = true
        suppressCurrentModifierTap = phase != .idle
    }

    var hasPendingModifierActivation: Bool {
        phase == .pendingModifierActivation
    }

    private struct ModifierTap: Equatable {
        let keyCode: Int
        let modifierFlags: UInt
        let timestamp: TimeInterval
    }

    func shouldConsume(
        eventType: HotkeyPhysicalEventType,
        keyCode: Int,
        modifierFlags: UInt,
        activationHotkey: HotkeyBinding?,
        askHotkey: HotkeyBinding?,
        personaHotkey: HotkeyBinding?,
        historyHotkey: HotkeyBinding? = nil,
        screenshotHotkey: HotkeyBinding? = nil,
        auxiliaryHotkey: HotkeyBinding? = nil
    ) -> Bool {
        if let auxiliaryHotkey {
            if eventType == .flagsChanged,
               auxiliaryHotkey.physicalModifierKeys.contains(keyCode) {
                let keys = Set(auxiliaryHotkey.physicalModifierKeys)
                let completesChord = modifierFlags == auxiliaryHotkey.modifierFlags
                    && !pressedModifierKeys.contains(keyCode)
                    && keys.subtracting([keyCode]).isSubset(of: pressedModifierKeys)
                // If Shift went through before Fn, its release must go through too.
                if completesChord || auxiliaryConsumedModifierKeys.contains(keyCode) { return true }
            }
            if eventType != .flagsChanged, auxiliaryHotkey.keyCode == keyCode,
               auxiliaryHotkey.physicalModifierKeys.isEmpty,
               (modifierFlags == auxiliaryHotkey.modifierFlags || auxiliaryIsDown) { return true }
        }
        switch eventType {
        case .flagsChanged:
            if let activationHotkey,
               activationHotkey.isModifierOnlyTrigger,
               keyCode == activationHotkey.keyCode {
                return true
            }
            if let askHotkey,
               askHotkey.isModifierOnlyTrigger,
               keyCode == askHotkey.keyCode {
                return true
            }
            if let askHotkey,
               askHotkey.isModifierDoubleTapTrigger,
               keyCode == askHotkey.keyCode {
                return true
            }
            // One-shot shortcuts: the persona picker, history and screenshot.
            return [personaHotkey, historyHotkey, screenshotHotkey].contains { hotkey in
                hotkey.map { $0.isModifierOnlyTrigger && keyCode == $0.keyCode } ?? false
            }
        case .keyDown:
            if let askHotkey, askHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
                return true
            }
            if let activationHotkey,
               !activationHotkey.isModifierOnlyTrigger,
               activationHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
                return true
            }
            if [personaHotkey, historyHotkey, screenshotHotkey].contains(where: {
                $0?.matches(keyCode: keyCode, modifierFlags: modifierFlags) == true
            }) {
                return true
            }
            if case .active(.ask) = phase, let askHotkey, askHotkey.keyCode == keyCode {
                return true
            }
            if case .active(.activation) = phase,
               let activationHotkey,
               !activationHotkey.isModifierOnlyTrigger,
               activationHotkey.keyCode == keyCode {
                return true
            }
            return false
        case .keyUp:
            if case .active(.ask) = phase, let askHotkey, askHotkey.keyCode == keyCode {
                return true
            }
            if case .active(.activation) = phase,
               let activationHotkey,
               !activationHotkey.isModifierOnlyTrigger,
               activationHotkey.keyCode == keyCode {
                return true
            }
            return false
        }
    }

    mutating func handleKeyDown(
        keyCode: Int,
        modifierFlags: UInt,
        isRepeat: Bool,
        activationHotkey: HotkeyBinding?,
        askHotkey: HotkeyBinding?,
        personaHotkey: HotkeyBinding?,
        historyHotkey: HotkeyBinding? = nil,
        screenshotHotkey: HotkeyBinding? = nil,
        auxiliaryHotkey: HotkeyBinding? = nil,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [HotkeyGestureEvent] {
        guard !isRepeat else { return [] }
        if let events = handleAuxiliaryEvent(
            type: .keyDown, keyCode: keyCode, flags: modifierFlags,
            binding: auxiliaryHotkey, activation: activationHotkey, ask: askHotkey, timestamp: timestamp
        ) { return events }

        if let askHotkey, askHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            phase = .active(.ask)
            return [.begin(.ask)]
        }

        if let activationHotkey,
           !activationHotkey.isModifierOnlyTrigger,
           activationHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags),
           phase == .idle {
            phase = .active(.activation)
            return [.begin(.activation)]
        }

        if let personaHotkey, personaHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            let shouldCancelPendingActivation = phase == .pendingModifierActivation
            phase = .idle
            return shouldCancelPendingActivation
                ? [.cancel(.activation), .personaRequested]
                : [.personaRequested]
        }

        if let historyHotkey, historyHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            let shouldCancelPendingActivation = phase == .pendingModifierActivation
            phase = .idle
            return shouldCancelPendingActivation
                ? [.cancel(.activation), .historyRequested]
                : [.historyRequested]
        }

        if let screenshotHotkey, screenshotHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            return requestDiscreteAction(.screenshotRequested)
        }

        return []
    }

    mutating func handleKeyUp(
        keyCode: Int,
        activationHotkey: HotkeyBinding?,
        askHotkey: HotkeyBinding?,
        auxiliaryHotkey: HotkeyBinding? = nil,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [HotkeyGestureEvent] {
        if let events = handleAuxiliaryEvent(
            type: .keyUp, keyCode: keyCode, flags: 0,
            binding: auxiliaryHotkey, activation: activationHotkey, ask: askHotkey, timestamp: timestamp
        ) { return events }
        switch phase {
        case .active(.activation):
            guard let activationHotkey else { return [] }
            guard !activationHotkey.isModifierOnlyTrigger else { return [] }
            guard activationHotkey.keyCode == keyCode else { return [] }
            phase = .idle
            return [.end(.activation)]
        case .active(.ask):
            guard let askHotkey, askHotkey.keyCode == keyCode else { return [] }
            phase = .idle
            return [.end(.ask)]
        default:
            return []
        }
    }

    mutating func handleFlagsChanged(
        keyCode: Int,
        modifierFlags: UInt,
        activationHotkey: HotkeyBinding?,
        askHotkey: HotkeyBinding?,
        personaHotkey: HotkeyBinding? = nil,
        historyHotkey: HotkeyBinding? = nil,
        screenshotHotkey: HotkeyBinding? = nil,
        auxiliaryHotkey: HotkeyBinding? = nil,
        timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) -> [HotkeyGestureEvent] {
        if isSecondTapForDoubleTapAsk(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            askHotkey: askHotkey,
            timestamp: timestamp
        ) {
            lastModifierTap = nil
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            let shouldCancelPendingActivation = phase == .pendingModifierActivation
            phase = .active(.ask)
            return shouldCancelPendingActivation
                ? [.cancel(.activation), .begin(.ask)]
                : [.begin(.ask)]
        }

        if let events = handleAuxiliaryEvent(
            type: .flagsChanged, keyCode: keyCode, flags: modifierFlags,
            binding: auxiliaryHotkey, activation: activationHotkey, ask: askHotkey, timestamp: timestamp
        ) { return events }

        if let activationHotkey,
           activationHotkey.isModifierOnlyTrigger,
           activationHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags),
           phase == .idle {
            activationSettled = false
            suppressCurrentModifierTap = false
            if shouldDeferModifierActivation(
                activationHotkey: activationHotkey,
                competingHotkeys: [askHotkey, personaHotkey, historyHotkey, screenshotHotkey].compactMap(\.self),
                auxiliaryHotkey: auxiliaryHotkey
            ) {
                phase = .pendingModifierActivation
                return [.begin(.activation)]
            }

            phase = .active(.activation)
            return [.begin(.activation)]
        }

        if let askHotkey,
           askHotkey.isModifierOnlyTrigger,
           askHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            let shouldCancelPendingActivation = phase == .pendingModifierActivation
            phase = .active(.ask)
            return shouldCancelPendingActivation
                ? [.cancel(.activation), .begin(.ask)]
                : [.begin(.ask)]
        }

        if let personaHotkey,
           personaHotkey.isModifierOnlyTrigger,
           personaHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            let shouldCancelPendingActivation = phase == .pendingModifierActivation
            phase = .idle
            return shouldCancelPendingActivation
                ? [.cancel(.activation), .personaRequested]
                : [.personaRequested]
        }

        if let historyHotkey,
           historyHotkey.isModifierOnlyTrigger,
           historyHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            guard phase == .idle || phase == .pendingModifierActivation else { return [] }
            let shouldCancelPendingActivation = phase == .pendingModifierActivation
            phase = .idle
            return shouldCancelPendingActivation
                ? [.cancel(.activation), .historyRequested]
                : [.historyRequested]
        }

        if let screenshotHotkey,
           screenshotHotkey.isModifierOnlyTrigger,
           screenshotHotkey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            return requestDiscreteAction(.screenshotRequested)
        }

        if case .active(.ask) = phase,
           let askHotkey,
           askHotkey.isModifierOnlyTrigger,
           keyCode == askHotkey.keyCode,
           modifierFlags != askHotkey.modifierFlags {
            phase = .idle
            return [.end(.ask)]
        }
        if case .active(.ask) = phase,
           let askHotkey,
           askHotkey.isModifierDoubleTapTrigger,
           keyCode == askHotkey.keyCode,
           modifierFlags != askHotkey.modifierFlags {
            phase = .idle
            return [.end(.ask)]
        }

        guard let activationHotkey, activationHotkey.isModifierOnlyTrigger else { return [] }
        let isActivationModifierEvent = keyCode == activationHotkey.keyCode
        let activationModifierDown = isActivationModifierEvent && modifierFlags == activationHotkey.modifierFlags

        guard isActivationModifierEvent, !activationModifierDown else { return [] }

        switch phase {
        case .pendingModifierActivation:
            rememberModifierTap(
                keyCode: keyCode,
                modifierFlags: activationHotkey.modifierFlags,
                askHotkey: askHotkey,
                timestamp: timestamp
            )
            phase = .idle
            return [.activationTapped]
        case .active(.activation):
            rememberModifierTap(
                keyCode: keyCode,
                modifierFlags: activationHotkey.modifierFlags,
                askHotkey: askHotkey,
                timestamp: timestamp
            )
            phase = .idle
            return [.end(.activation)]
        default:
            return []
        }
    }

    /// A one-shot shortcut (no press and release phases) fires while idle, and
    /// wins over a modifier activation still waiting to settle.
    private mutating func requestDiscreteAction(_ event: HotkeyGestureEvent) -> [HotkeyGestureEvent] {
        guard phase == .idle || phase == .pendingModifierActivation else { return [] }
        let shouldCancelPendingActivation = phase == .pendingModifierActivation
        phase = .idle
        return shouldCancelPendingActivation ? [.cancel(.activation), event] : [event]
    }

    mutating func handlePendingModifierActivationTimeout() -> [HotkeyGestureEvent] {
        guard phase == .pendingModifierActivation else { return [] }
        phase = .active(.activation)
        return []
    }

    private func shouldDeferModifierActivation(
        activationHotkey: HotkeyBinding,
        competingHotkeys: [HotkeyBinding],
        auxiliaryHotkey: HotkeyBinding?
    ) -> Bool {
        guard activationHotkey.isModifierOnlyTrigger else { return false }
        if let auxiliaryHotkey,
           auxiliaryHotkey.modifierFlags & activationHotkey.modifierFlags == activationHotkey.modifierFlags {
            return true
        }
        return competingHotkeys.contains { hotkey in
            hotkey.modifierFlags == activationHotkey.modifierFlags
                && (hotkey.keyCode != activationHotkey.keyCode || hotkey.isModifierDoubleTapTrigger)
        }
    }

    private func isSecondTapForDoubleTapAsk(
        keyCode: Int,
        modifierFlags: UInt,
        askHotkey: HotkeyBinding?,
        timestamp: TimeInterval
    ) -> Bool {
        guard let askHotkey, askHotkey.isModifierDoubleTapTrigger else { return false }
        guard askHotkey.keyCode == keyCode, askHotkey.modifierFlags == modifierFlags else { return false }
        guard let lastModifierTap else { return false }
        guard lastModifierTap.keyCode == keyCode, lastModifierTap.modifierFlags == modifierFlags else { return false }
        return timestamp - lastModifierTap.timestamp <= Self.doubleTapMaximumInterval
    }

    private mutating func rememberModifierTap(
        keyCode: Int,
        modifierFlags: UInt,
        askHotkey: HotkeyBinding?,
        timestamp: TimeInterval
    ) {
        if suppressCurrentModifierTap {
            suppressCurrentModifierTap = false
            lastModifierTap = nil
            return
        }
        guard let askHotkey, askHotkey.isModifierDoubleTapTrigger else {
            lastModifierTap = nil
            return
        }
        guard askHotkey.keyCode == keyCode, askHotkey.modifierFlags == modifierFlags else {
            lastModifierTap = nil
            return
        }
        lastModifierTap = ModifierTap(keyCode: keyCode, modifierFlags: modifierFlags, timestamp: timestamp)
    }

    /// Returns nil when the existing shortcuts should handle this event.
    private mutating func handleAuxiliaryEvent(
        type: HotkeyPhysicalEventType,
        keyCode: Int,
        flags: UInt,
        binding: HotkeyBinding?,
        activation: HotkeyBinding?,
        ask: HotkeyBinding?,
        timestamp: TimeInterval
    ) -> [HotkeyGestureEvent]? {
        if type == .flagsChanged {
            let mask = HotkeyBinding.modifierFlag(for: keyCode)
            if mask != 0 {
                if flags & mask == 0 || pressedModifierKeys.contains(keyCode) {
                    pressedModifierKeys.remove(keyCode)
                } else {
                    pressedModifierKeys.insert(keyCode)
                }
            }
            pressedModifierKeys = pressedModifierKeys.filter {
                flags & HotkeyBinding.modifierFlag(for: $0) != 0
            }
            auxiliaryConsumedModifierKeys.formIntersection(pressedModifierKeys)
        }
        guard let binding else { return nil }
        let keys = Set(binding.physicalModifierKeys)
        let isModifier = !keys.isEmpty
        let down: Bool
        if isModifier {
            guard type == .flagsChanged else { return nil }
            down = keys.isSubset(of: pressedModifierKeys) && flags == binding.modifierFlags
        } else {
            guard keyCode == binding.keyCode, type != .flagsChanged else { return nil }
            down = type == .keyDown && flags == binding.modifierFlags
        }

        // A chord's remaining key releases must never become a main-key tap.
        if !auxiliaryReleaseKeys.isEmpty {
            auxiliaryReleaseKeys.formIntersection(pressedModifierKeys)
            return []
        }
        if auxiliaryIsDown, !down {
            auxiliaryIsDown = false
            if phase == .active(.auxiliary) {
                phase = .idle
                auxiliaryLastTap = nil
                rememberModifierTap(keyCode: keyCode, modifierFlags: binding.modifierFlags, askHotkey: ask, timestamp: timestamp)
                auxiliaryReleaseKeys = keys.intersection(pressedModifierKeys)
                return [.end(.auxiliary)]
            }
            auxiliaryLastTap = timestamp
            return nil
        }
        guard down, !auxiliaryIsDown else { return nil }
        auxiliaryIsDown = true
        if isModifier { auxiliaryConsumedModifierKeys.insert(keyCode) }
        let sharesActivation = activation.map {
            $0.keyCode == binding.keyCode && $0.modifierFlags == binding.modifierFlags
                && ($0.pressCount ?? 1) == 1
        } ?? false
        if binding.pressCount == 2 {
            guard let last = auxiliaryLastTap,
                  timestamp - last <= Self.doubleTapMaximumInterval else {
                auxiliaryLastTap = nil
                return sharesActivation ? nil : []
            }
        }
        let promotes = !activationSettled && (
            phase == .pendingModifierActivation || phase == .active(.activation)
                || (sharesActivation && binding.pressCount == 2)
        )
        guard phase == .idle || promotes else { return [] }
        auxiliaryLastTap = nil
        lastModifierTap = nil
        activationSettled = false
        phase = .active(.auxiliary)
        return [promotes ? .auxiliaryPromoted : .begin(.auxiliary)]
    }
}
