import AppKit
import Carbon.HIToolbox
import Foundation

private let systemHotkeyPoolSignature: OSType = 0x5459_4850 // TYHP

private func systemHotkeyPoolCallback(
    nextHandler _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr, hotkeyID.signature == systemHotkeyPoolSignature else {
        return OSStatus(eventNotHandledErr)
    }
    let pool = Unmanaged<SystemHotkeyPool>.fromOpaque(userData).takeUnretainedValue()
    let handled = GetEventKind(event) == UInt32(kEventHotKeyReleased)
        ? pool.handleReleased(id: hotkeyID.id) : pool.handlePressed(id: hotkeyID.id)
    return handled ? noErr : OSStatus(eventNotHandledErr)
}

/// Registers any number of plain key chords (⌃⌥R) with the system, for the feature and
/// keyword shortcuts. They need no Accessibility permission and never pass through the
/// gesture arbiter, which only handles voice input's holds and taps.
final class SystemHotkeyPool {
    private let name: String
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var targets: [UInt32: HotkeyTarget] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var ringLatency: ShortcutLatencyTrace?
    private let beginShortcutTrace: (FeatureRole) -> ShortcutLatencyTrace?

    var onPressed: ((HotkeyTarget) -> Void)?
    /// The key of a registered chord was let go. Only shortcuts that are held (the ring) use it.
    var onReleased: ((HotkeyTarget) -> Void)?

    init(name: String, beginShortcutTrace: @escaping (FeatureRole) -> ShortcutLatencyTrace? = ShortcutLatency.begin) {
        self.name = name
        self.beginShortcutTrace = beginShortcutTrace
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// The targets that are registered now.
    var registeredTargets: Set<HotkeyTarget> {
        Set(targets.values)
    }

    /// Replaces every registration with `bindings`. Gestures cannot be system hotkeys and are skipped.
    func register(_ bindings: [HotkeyTarget: HotkeyBinding]) {
        unregisterAll()
        var nextID: UInt32 = 1
        for (target, binding) in bindings.sorted(by: { $0.value.signature < $1.value.signature }) {
            guard Self.canRegister(binding) else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                Self.carbonModifierFlags(from: binding.modifierFlags),
                EventHotKeyID(signature: systemHotkeyPoolSignature, id: nextID),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs[nextID] = ref
                targets[nextID] = target
                nextID += 1
            } else {
                ErrorLogStore.shared
                    .log("Hotkey: failed to register \(name) \(HotkeyFormat.display(binding)), status \(status)")
            }
        }
    }

    func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs = [:]
        targets = [:]
        ringLatency = nil
    }

    func handlePressed(id: UInt32) -> Bool {
        guard let target = targets[id] else { return false }
        let role = FeatureHotkeyEvent.destination(for: target)
        let trace = role == .host ? nil : beginShortcutTrace(role)
        if target == .action(.ring) {
            ringLatency = trace
        }
        ShortcutLatency.deliver(trace) { [weak self] in
            ShortcutLatency.record(.callback)
            if target == .action(.ring) {
                ShortcutLatency.record(.ringPressed)
            }
            self?.onPressed?(target)
        }
        return true
    }

    func handleReleased(id: UInt32) -> Bool {
        guard let target = targets[id] else { return false }
        let trace = target == .action(.ring) ? ringLatency : nil
        if target == .action(.ring) {
            ringLatency = nil
        }
        ShortcutLatency.deliver(trace) { [weak self] in
            if target == .action(.ring) {
                ShortcutLatency.record(.ringReleased)
            }
            self?.onReleased?(target)
        }
        return true
    }

    /// The registration id of `target`, for tests that drive the callbacks.
    func registrationID(of target: HotkeyTarget) -> UInt32? {
        targets.first { $0.value == target }?.key
    }

    static func canRegister(_ binding: HotkeyBinding) -> Bool {
        (binding.pressCount ?? 1) == 1 && !binding.isModifierOnlyTrigger && binding.modifierKeyCodes == nil
            && HotkeyBinding.modifierFlag(for: binding.keyCode) == 0
    }

    static func carbonModifierFlags(from flags: UInt) -> UInt32 {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: flags)
        var result: UInt32 = 0
        if modifierFlags.contains(.command) {
            result |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifierFlags.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifierFlags.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        return result
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            systemHotkeyPoolCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        if status != noErr {
            ErrorLogStore.shared.log("Hotkey: failed to install \(name) hotkey handler, status \(status)")
        }
    }
}
