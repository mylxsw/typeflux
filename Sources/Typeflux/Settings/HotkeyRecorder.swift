import AppKit
import Foundation

final class HotkeyRecorder: ObservableObject {
    @Published var isRecording: Bool = false

    private var monitor: Any?

    func start(onRecorded: @escaping (HotkeyBinding) -> Void) {
        stop()
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            let keyCode = Int(event.keyCode)
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])

            guard let binding = Self.recordedBinding(
                eventType: event.type,
                keyCode: keyCode,
                modifierFlags: UInt(flags.rawValue),
                isRepeat: event.isARepeat,
            ) else {
                return event.type == .keyDown && event.isARepeat ? nil : event
            }
            onRecorded(binding)
            stop()
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    static func recordedBinding(
        eventType: NSEvent.EventType,
        keyCode: Int,
        modifierFlags: UInt,
        isRepeat: Bool,
    ) -> HotkeyBinding? {
        let binding = HotkeyBinding(keyCode: keyCode, modifierFlags: modifierFlags)

        if eventType == .flagsChanged {
            return binding.isModifierOnlyTrigger ? binding : nil
        }

        guard eventType == .keyDown, !isRepeat, modifierFlags != 0 else { return nil }
        return binding
    }
}
