import AppKit
import Foundation

private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<EventTapHotkeyService>.fromOpaque(refcon).takeUnretainedValue()
    return service.handleEventTapEvent(type: type, event: event)
}

final class EventTapHotkeyService: HotkeyService {
    private static let modifierActivationHoldDelay: TimeInterval = 0.22

    var onActivationTap: (() -> Void)?
    var onActivationPressBegan: (() -> Void)?
    var onActivationPressEnded: (() -> Void)?
    var onAskPressBegan: (() -> Void)?
    var onAskPressEnded: (() -> Void)?
    var onPersonaPickerRequested: (() -> Void)?
    var onError: ((String) -> Void)?

    private let settingsStore: SettingsStore

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var arbiter = HotkeyGestureArbiter()
    private var pendingModifierActivationWorkItem: DispatchWorkItem?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func start() {
        stop()
        
        NSLog("[Hotkey] Starting event tap service...")
        ErrorLogStore.shared.log("Hotkey: starting")

        installEventTapIfPossible()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        eventTap = nil
        runLoopSource = nil
        globalMonitor = nil
        localMonitor = nil
        pendingModifierActivationWorkItem?.cancel()
        pendingModifierActivationWorkItem = nil
        arbiter = HotkeyGestureArbiter()
    }

    private func installEventTapIfPossible() {
        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyEventTapCallback,
            userInfo: selfPointer
        ) else {
            ErrorLogStore.shared.log("Hotkey: failed to create CGEventTap, using NSEvent fallback")
            installNSEventMonitorFallback()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installNSEventMonitorFallback() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            _ = self?.processNSEvent(event, canConsume: false)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let shouldConsume = self.processNSEvent(event, canConsume: true)
            return shouldConsume ? nil : event
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        _ = processNSEvent(event, canConsume: false)
    }

    private func processNSEvent(_ event: NSEvent, canConsume: Bool) -> Bool {
        processPhysicalEvent(
            eventType: physicalEventType(for: event.type),
            keyCode: Int(event.keyCode),
            modifierFlags: filteredFlags(event.modifierFlags),
            isRepeat: event.isARepeat,
            canConsume: canConsume
        )
    }

    fileprivate func handleEventTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let eventType = physicalEventType(for: type) else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = filteredFlags(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        let isRepeat = eventType == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let shouldConsume = processPhysicalEvent(
            eventType: eventType,
            keyCode: keyCode,
            modifierFlags: flags,
            isRepeat: isRepeat,
            canConsume: true
        )
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func processPhysicalEvent(
        eventType: HotkeyPhysicalEventType?,
        keyCode: Int,
        modifierFlags: UInt,
        isRepeat: Bool,
        canConsume: Bool
    ) -> Bool {
        guard let eventType else { return false }

        let activationHotkey = settingsStore.activationHotkey
        let askHotkey = settingsStore.askHotkey
        let personaHotkey = settingsStore.personaHotkey
        let shouldConsume = canConsume && arbiter.shouldConsume(
            eventType: eventType,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            activationHotkey: activationHotkey,
            askHotkey: askHotkey,
            personaHotkey: personaHotkey
        )

        switch eventType {
        case .keyDown:
            handleGestureEvents(
                arbiter.handleKeyDown(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    isRepeat: isRepeat,
                    activationHotkey: activationHotkey,
                    askHotkey: askHotkey,
                    personaHotkey: personaHotkey
                )
            )
        case .keyUp:
            handleGestureEvents(
                arbiter.handleKeyUp(
                    keyCode: keyCode,
                    activationHotkey: activationHotkey,
                    askHotkey: askHotkey
                )
            )
        case .flagsChanged:
            handleGestureEvents(
                arbiter.handleFlagsChanged(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    activationHotkey: activationHotkey,
                    askHotkey: askHotkey
                )
            )
        }

        return shouldConsume
    }

    private func filteredFlags(_ flags: NSEvent.ModifierFlags) -> UInt {
        UInt(flags.intersection([.command, .shift, .control, .option, .function]).rawValue)
    }

    private func physicalEventType(for type: NSEvent.EventType) -> HotkeyPhysicalEventType? {
        switch type {
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        case .flagsChanged:
            return .flagsChanged
        default:
            return nil
        }
    }

    private func physicalEventType(for type: CGEventType) -> HotkeyPhysicalEventType? {
        switch type {
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        case .flagsChanged:
            return .flagsChanged
        default:
            return nil
        }
    }

    private func handleGestureEvents(_ events: [HotkeyGestureEvent]) {
        syncPendingModifierActivationTimer()

        for event in events {
            switch event {
            case .activationTapped:
                ErrorLogStore.shared.log("Hotkey(NSEvent): activation tap")
                DispatchQueue.main.async { [weak self] in
                    self?.onActivationTap?()
                }
            case .begin(.activation):
                ErrorLogStore.shared.log("Hotkey(NSEvent): activation down")
                DispatchQueue.main.async { [weak self] in
                    self?.onActivationPressBegan?()
                }
            case .end(.activation):
                ErrorLogStore.shared.log("Hotkey(NSEvent): activation up")
                DispatchQueue.main.async { [weak self] in
                    self?.onActivationPressEnded?()
                }
            case .begin(.ask):
                ErrorLogStore.shared.log("Hotkey(NSEvent): ask down")
                DispatchQueue.main.async { [weak self] in
                    self?.onAskPressBegan?()
                }
            case .end(.ask):
                ErrorLogStore.shared.log("Hotkey(NSEvent): ask up")
                DispatchQueue.main.async { [weak self] in
                    self?.onAskPressEnded?()
                }
            case .begin(.personaPicker), .end(.personaPicker):
                break
            case .personaRequested:
                ErrorLogStore.shared.log("Hotkey(NSEvent): persona picker")
                DispatchQueue.main.async { [weak self] in
                    self?.onPersonaPickerRequested?()
                }
            }
        }
    }

    private func syncPendingModifierActivationTimer() {
        guard arbiter.hasPendingModifierActivation else {
            pendingModifierActivationWorkItem?.cancel()
            pendingModifierActivationWorkItem = nil
            return
        }

        guard pendingModifierActivationWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingModifierActivationWorkItem = nil
            self.handleGestureEvents(self.arbiter.handlePendingModifierActivationTimeout())
        }
        pendingModifierActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.modifierActivationHoldDelay,
            execute: workItem
        )
    }
}
