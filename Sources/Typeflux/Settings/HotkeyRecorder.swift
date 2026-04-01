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

            let binding = HotkeyBinding(keyCode: keyCode, modifierFlags: UInt(flags.rawValue))

            if event.type == .flagsChanged {
                guard binding.isRightCommandTrigger || binding.isFunctionTrigger else { return event }
                onRecorded(binding)
                self.stop()
                return nil
            }

            // Ignore repeats
            if event.isARepeat { return nil }

            // Require at least one modifier to reduce collisions.
            if flags.isEmpty { return nil }

            onRecorded(binding)
            self.stop()
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
}
