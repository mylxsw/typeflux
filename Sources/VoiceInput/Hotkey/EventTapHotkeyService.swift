import AppKit
import Foundation

final class EventTapHotkeyService: HotkeyService {
    private enum PrimaryModifierHotkey {
        static let rightCommandKeyCode = 54
    }

    var onPressBegan: (() -> Void)?
    var onPressEnded: (() -> Void)?
    var onError: ((String) -> Void)?

    private let settingsStore: SettingsStore

    private var isPressed = false
    private var activeCustomKeyCode: Int?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var nseventIsPressed = false

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func start() {
        stop()
        
        NSLog("[Hotkey] Starting event tap service...")
        ErrorLogStore.shared.log("Hotkey: starting")

        // Fallback: NSEvent global monitor (more reliable than CGEventTap in some environments)
        // Note: global monitor will not receive events while app is in secure input contexts, but works for most cases.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        nseventIsPressed = false
 
        isPressed = false
        activeCustomKeyCode = nil
    }

     private func handleNSEvent(_ event: NSEvent) {
         switch event.type {
         case .keyDown, .keyUp:
             let keyCode = Int(event.keyCode)
             let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
             let flagsRaw = UInt(flags.rawValue)

             let bindings = settingsStore.customHotkeys
             let matched = bindings.contains(where: { $0.keyCode == keyCode && $0.modifierFlags == flagsRaw })
             guard matched else { return }

             if event.type == .keyDown {
                 if activeCustomKeyCode == nil {
                     activeCustomKeyCode = keyCode
                     ErrorLogStore.shared.log("Hotkey(NSEvent): custom down")
                     DispatchQueue.main.async { [weak self] in
                         self?.onPressBegan?()
                     }
                 }
             } else {
                 if activeCustomKeyCode == keyCode {
                     activeCustomKeyCode = nil
                     ErrorLogStore.shared.log("Hotkey(NSEvent): custom up")
                     DispatchQueue.main.async { [weak self] in
                         self?.onPressEnded?()
                     }
                 }
             }

         case .flagsChanged:
             let isRightCommandEvent = Int(event.keyCode) == PrimaryModifierHotkey.rightCommandKeyCode
             let rightCommandDown = isRightCommandEvent && event.modifierFlags.contains(.command)
             let hasOtherModifiers = event.modifierFlags.intersection([.shift, .control, .option]).rawValue != 0

             if rightCommandDown, !hasOtherModifiers, !nseventIsPressed {
                 nseventIsPressed = true
                 ErrorLogStore.shared.log("Hotkey(NSEvent): right command down")
                 DispatchQueue.main.async { [weak self] in
                     self?.onPressBegan?()
                 }
             } else if isRightCommandEvent, !rightCommandDown, nseventIsPressed {
                 nseventIsPressed = false
                 ErrorLogStore.shared.log("Hotkey(NSEvent): right command up")
                 DispatchQueue.main.async { [weak self] in
                     self?.onPressEnded?()
                 }
             }

         default:
             return
         }
     }
}
