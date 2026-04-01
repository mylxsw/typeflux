import AppKit
import Foundation

final class HotkeyRecorder: ObservableObject {
    @Published var isRecording: Bool = false

    private var monitor: Any?

    func start(onRecorded: @escaping (HotkeyBinding) -> Void) {
        stop()
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            // Ignore repeats
            if event.isARepeat { return nil }

            let keyCode = Int(event.keyCode)
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])

            // Require at least one modifier to reduce collisions.
            if flags.isEmpty { return nil }

            let binding = HotkeyBinding(keyCode: keyCode, modifierFlags: UInt(flags.rawValue))
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
