import AppKit
import Foundation

private func hotkeyRecorderEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<HotkeyRecorder>.fromOpaque(refcon).takeUnretainedValue()
    return recorder.handleEventTapEvent(type: type, event: event)
}

final class HotkeyRecorder: ObservableObject {
    @Published var isRecording: Bool = false

    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onRecorded: ((HotkeyBinding) -> Void)?

    func start(onRecorded: @escaping (HotkeyBinding) -> Void) {
        stop()
        isRecording = true
        self.onRecorded = onRecorded

        if installEventTapIfPossible() {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            let shouldConsume = processRecordedEvent(
                eventType: event.type,
                keyCode: Int(event.keyCode),
                modifierFlags: Self.filteredFlags(event.modifierFlags),
                isRepeat: event.isARepeat,
            )
            return shouldConsume ? nil : event
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(eventTap)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        eventTap = nil
        runLoopSource = nil
        onRecorded = nil
        isRecording = false
    }

    private func installEventTapIfPossible() -> Bool {
        let mask =
            (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyRecorderEventTapCallback,
            userInfo: selfPointer,
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handleEventTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let eventType = nsEventType(for: type) else {
            return Unmanaged.passUnretained(event)
        }

        let shouldConsume = processRecordedEvent(
            eventType: eventType,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            modifierFlags: Self.filteredFlags(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))),
            isRepeat: eventType == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        )
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func processRecordedEvent(
        eventType: NSEvent.EventType,
        keyCode: Int,
        modifierFlags: UInt,
        isRepeat: Bool,
    ) -> Bool {
        guard let binding = Self.recordedBinding(
            eventType: eventType,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isRepeat: isRepeat,
        ) else {
            return eventType == .keyDown && isRepeat
        }

        onRecorded?(binding)
        stop()
        return true
    }

    private func nsEventType(for type: CGEventType) -> NSEvent.EventType? {
        switch type {
        case .keyDown:
            .keyDown
        case .flagsChanged:
            .flagsChanged
        default:
            nil
        }
    }

    static func recordedBinding(
        eventType: NSEvent.EventType,
        keyCode: Int,
        modifierFlags: UInt,
        isRepeat: Bool,
    ) -> HotkeyBinding? {
        if eventType == .flagsChanged {
            return modifierOnlyBinding(keyCode: keyCode, modifierFlags: modifierFlags)
        }

        guard eventType == .keyDown, !isRepeat, modifierFlags != 0 else { return nil }
        return HotkeyBinding(keyCode: keyCode, modifierFlags: modifierFlags)
    }

    private static func modifierOnlyBinding(keyCode: Int, modifierFlags: UInt) -> HotkeyBinding? {
        let expectedModifierFlags: UInt? = switch keyCode {
        case HotkeyBinding.rightCommandKeyCode:
            UInt(NSEvent.ModifierFlags.command.rawValue)
        case HotkeyBinding.rightOptionKeyCode:
            UInt(NSEvent.ModifierFlags.option.rawValue)
        case HotkeyBinding.functionKeyCode:
            UInt(NSEvent.ModifierFlags.function.rawValue)
        default:
            nil
        }

        guard let expectedModifierFlags else { return nil }
        guard modifierFlags & expectedModifierFlags == expectedModifierFlags else { return nil }
        return HotkeyBinding(keyCode: keyCode, modifierFlags: expectedModifierFlags)
    }

    private static func filteredFlags(_ flags: NSEvent.ModifierFlags) -> UInt {
        UInt(flags.intersection([.command, .option, .control, .shift, .function]).rawValue)
    }
}
