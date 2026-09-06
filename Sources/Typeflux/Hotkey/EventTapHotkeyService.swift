import AppKit
import Carbon.HIToolbox
import Foundation

private let historySystemHotkeyID = EventHotKeyID(signature: 0x5459_4853, id: 1) // TYHS

private func hotkeyEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<EventTapHotkeyService>.fromOpaque(refcon).takeUnretainedValue()
    return service.handleEventTapEvent(type: type, event: event)
}

private func systemHotkeyCallback(
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
    guard status == noErr, hotkeyID.signature == historySystemHotkeyID.signature,
          hotkeyID.id == historySystemHotkeyID.id
    else {
        return noErr
    }

    let registrar = Unmanaged<SystemHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    registrar.handlePressed()
    return noErr
}

private final class SystemHotkeyRegistrar {
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var onPressed: (() -> Void)?

    var isRegistered: Bool {
        hotkeyRef != nil
    }

    init() {
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(_ binding: HotkeyBinding?) {
        unregister()

        guard let binding, (binding.pressCount ?? 1) == 1, !binding.isModifierOnlyTrigger else {
            return
        }

        let hotkeyID = historySystemHotkeyID
        var newHotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            carbonModifierFlags(from: binding.modifierFlags),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &newHotkeyRef
        )
        guard status == noErr else {
            ErrorLogStore.shared.log("Hotkey: failed to register History system hotkey, status \(status)")
            return
        }

        hotkeyRef = newHotkeyRef
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        hotkeyRef = nil
    }

    fileprivate func handlePressed() {
        DispatchQueue.main.async { [weak self] in
            self?.onPressed?()
        }
    }

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            systemHotkeyCallback,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        if status != noErr {
            ErrorLogStore.shared.log("Hotkey: failed to install History system hotkey handler, status \(status)")
        }
    }

    private func carbonModifierFlags(from flags: UInt) -> UInt32 {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: flags)
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

final class EventTapHotkeyService: HotkeyService {
    /// Allows competing modifier shortcuts to win without delaying recording start.
    /// Recording mode is decided by `WorkflowController`, not by this timer.
    private static let modifierShortcutArbitrationDelay: TimeInterval = 0.22
    private static let duplicateHistoryRequestSuppression: TimeInterval = 0.18

    var onActivationTap: ((HotkeyEventContext) -> Void)?
    var onActivationPressBegan: ((HotkeyEventContext) -> Void)?
    var onActivationPressEnded: ((HotkeyEventContext) -> Void)?
    var onActivationCancelled: (() -> Void)?
    var onAskPressBegan: ((HotkeyEventContext) -> Void)?
    var onAskPressEnded: (() -> Void)?
    var onPersonaPickerRequested: (() -> Void)?
    var onHistoryRequested: (() -> Void)?
    var onError: ((String) -> Void)?

    private let settingsStore: SettingsStore

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var arbiter = HotkeyGestureArbiter()
    private var pendingModifierActivationWorkItem: DispatchWorkItem?
    private var accessibilityRetryWorkItem: DispatchWorkItem?
    private let historySystemHotkey = SystemHotkeyRegistrar()
    private var hotkeySettingsObserver: NSObjectProtocol?
    private var lastHistoryRequestAt: Date?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        historySystemHotkey.onPressed = { [weak self] in
            ErrorLogStore.shared.log("Hotkey(System): history")
            self?.requestHistoryPicker()
        }
    }

    func start() {
        stop()

        NSLog("[Hotkey] Starting event tap service...")
        ErrorLogStore.shared.log("Hotkey: starting")

        registerHistorySystemHotkey()
        hotkeySettingsObserver = NotificationCenter.default.addObserver(
            forName: .hotkeySettingsDidChange,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            self?.registerHistorySystemHotkey()
        }
        installEventTapIfPossible()
    }

    func settleActivationGesture() {
        arbiter.settleActivationGesture()
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
        accessibilityRetryWorkItem?.cancel()
        accessibilityRetryWorkItem = nil
        if let hotkeySettingsObserver {
            NotificationCenter.default.removeObserver(hotkeySettingsObserver)
        }
        hotkeySettingsObserver = nil
        historySystemHotkey.unregister()
        arbiter = HotkeyGestureArbiter()
    }

    private func registerHistorySystemHotkey() {
        historySystemHotkey.register(settingsStore.historyHotkey)
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
            scheduleEventTapRetryAfterAccessibilityGrant()
            return
        }

        accessibilityRetryWorkItem?.cancel()
        accessibilityRetryWorkItem = nil
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installNSEventMonitorFallback() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .keyDown,
            .keyUp,
            .flagsChanged
        ]) { [weak self] event in
            _ = self?.processNSEvent(event, canConsume: false)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown,
            .keyUp,
            .flagsChanged
        ]) { [weak self] event in
            guard let self else { return event }
            let shouldConsume = processNSEvent(event, canConsume: true)
            return shouldConsume ? nil : event
        }
    }

    private func scheduleEventTapRetryAfterAccessibilityGrant() {
        guard !PrivacyGuard.isAccessibilityGranted() else { return }
        guard accessibilityRetryWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            accessibilityRetryWorkItem = nil

            guard PrivacyGuard.isAccessibilityGranted() else {
                scheduleEventTapRetryAfterAccessibilityGrant()
                return
            }

            ErrorLogStore.shared.log("Hotkey: accessibility granted, restarting event tap service")
            start()
        }
        accessibilityRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
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
            canConsume: canConsume,
            timestamp: event.timestamp
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
            canConsume: true,
            timestamp: TimeInterval(event.timestamp) / 1_000_000_000
        )
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func processPhysicalEvent(
        eventType: HotkeyPhysicalEventType?,
        keyCode: Int,
        modifierFlags: UInt,
        isRepeat: Bool,
        canConsume: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        guard let eventType else { return false }

        let activationHotkey = settingsStore.activationHotkey
        let askHotkey = settingsStore.askHotkey
        let personaHotkey = settingsStore.personaHotkey
        let historyHotkey = settingsStore.historyHotkey
        let shouldConsume = canConsume && arbiter.shouldConsume(
            eventType: eventType,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            activationHotkey: activationHotkey,
            askHotkey: askHotkey,
            personaHotkey: personaHotkey,
            historyHotkey: historyHotkey
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
                    personaHotkey: personaHotkey,
                    historyHotkey: historyHotkey
                ),
                context: HotkeyEventContext(uptime: timestamp)
            )
        case .keyUp:
            handleGestureEvents(
                arbiter.handleKeyUp(
                    keyCode: keyCode,
                    activationHotkey: activationHotkey,
                    askHotkey: askHotkey
                ),
                context: HotkeyEventContext(uptime: timestamp)
            )
        case .flagsChanged:
            handleGestureEvents(
                arbiter.handleFlagsChanged(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    activationHotkey: activationHotkey,
                    askHotkey: askHotkey,
                    personaHotkey: personaHotkey,
                    historyHotkey: historyHotkey,
                    timestamp: timestamp
                ),
                context: HotkeyEventContext(uptime: timestamp)
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
            .keyDown
        case .keyUp:
            .keyUp
        case .flagsChanged:
            .flagsChanged
        default:
            nil
        }
    }

    private func physicalEventType(for type: CGEventType) -> HotkeyPhysicalEventType? {
        switch type {
        case .keyDown:
            .keyDown
        case .keyUp:
            .keyUp
        case .flagsChanged:
            .flagsChanged
        default:
            nil
        }
    }

    private func handleGestureEvents(
        _ events: [HotkeyGestureEvent],
        context: HotkeyEventContext = HotkeyEventContext()
    ) {
        syncPendingModifierActivationTimer()

        for event in events {
            switch event {
            case .activationTapped:
                ErrorLogStore.shared.log("Hotkey(NSEvent): activation tap")
                RecordingStartupLatencyTrace.shared.mark("hotkey.activation_tap")
                DispatchQueue.main.async { [weak self] in
                    self?.onActivationTap?(context)
                }
            case .begin(.activation):
                ErrorLogStore.shared.log("Hotkey(NSEvent): activation down")
                RecordingStartupLatencyTrace.shared.begin("hotkey.activation_begin")
                DispatchQueue.main.async { [weak self] in
                    self?.onActivationPressBegan?(context)
                }
            case .end(.activation):
                ErrorLogStore.shared.log("Hotkey(NSEvent): activation up")
                RecordingStartupLatencyTrace.shared.mark("hotkey.activation_end")
                DispatchQueue.main.async { [weak self] in
                    self?.onActivationPressEnded?(context)
                }
            case .cancel(.activation):
                ErrorLogStore.shared.log("Hotkey(NSEvent): activation cancel")
                RecordingStartupLatencyTrace.shared.mark("hotkey.activation_cancel")
                DispatchQueue.main.async { [weak self] in
                    self?.onActivationCancelled?()
                }
            case .cancel(.ask), .cancel(.personaPicker), .cancel(.history):
                break
            case .begin(.ask):
                ErrorLogStore.shared.log("Hotkey(NSEvent): ask down")
                RecordingStartupLatencyTrace.shared.mark("hotkey.ask_begin")
                DispatchQueue.main.async { [weak self] in
                    self?.onAskPressBegan?(context)
                }
            case .end(.ask):
                ErrorLogStore.shared.log("Hotkey(NSEvent): ask up")
                RecordingStartupLatencyTrace.shared.mark("hotkey.ask_end")
                DispatchQueue.main.async { [weak self] in
                    self?.onAskPressEnded?()
                }
            case .begin(.personaPicker), .end(.personaPicker), .begin(.history), .end(.history):
                break
            case .personaRequested:
                ErrorLogStore.shared.log("Hotkey(NSEvent): persona picker")
                DispatchQueue.main.async { [weak self] in
                    self?.onPersonaPickerRequested?()
                }
            case .historyRequested:
                ErrorLogStore.shared.log("Hotkey(NSEvent): history")
                requestHistoryPicker()
            }
        }
    }

    private func requestHistoryPicker() {
        let now = Date()
        if let lastHistoryRequestAt,
           now.timeIntervalSince(lastHistoryRequestAt) < Self.duplicateHistoryRequestSuppression {
            ErrorLogStore.shared.log("Hotkey: suppressed duplicate History request")
            return
        }
        lastHistoryRequestAt = now
        DispatchQueue.main.async { [weak self] in
            self?.onHistoryRequested?()
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
            pendingModifierActivationWorkItem = nil
            handleGestureEvents(arbiter.handlePendingModifierActivationTimeout())
        }
        pendingModifierActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.modifierShortcutArbitrationDelay,
            execute: workItem
        )
    }
}
