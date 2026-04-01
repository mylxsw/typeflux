import AppKit
import Foundation

final class EventTapHotkeyService: HotkeyService {
    var onActivationPressBegan: (() -> Void)?
    var onActivationPressEnded: (() -> Void)?
    var onAskPressBegan: (() -> Void)?
    var onAskPressEnded: (() -> Void)?
    var onPersonaPickerRequested: (() -> Void)?
    var onError: ((String) -> Void)?

    private let settingsStore: SettingsStore

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activeAction: HotkeyAction?

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
        activeAction = nil
    }

    private func handleNSEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handleKeyDown(event)
        case .keyUp:
            handleKeyUp(event)
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            return
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.isARepeat { return }

        let keyCode = Int(event.keyCode)
        let flags = filteredFlags(event.modifierFlags)
        let activationHotkey = settingsStore.activationHotkey
        let askHotkey = settingsStore.askHotkey
        let personaHotkey = settingsStore.personaHotkey

        if !activationHotkey.isRightCommandTrigger,
           !activationHotkey.isFunctionTrigger,
           activationHotkey.matches(keyCode: keyCode, modifierFlags: flags),
           activeAction == nil {
            activeAction = .activation
            ErrorLogStore.shared.log("Hotkey(NSEvent): activation down")
            DispatchQueue.main.async { [weak self] in
                self?.onActivationPressBegan?()
            }
            return
        }

        if askHotkey.matches(keyCode: keyCode, modifierFlags: flags),
           activeAction == nil {
            activeAction = .ask
            ErrorLogStore.shared.log("Hotkey(NSEvent): ask down")
            DispatchQueue.main.async { [weak self] in
                self?.onAskPressBegan?()
            }
            return
        }

        if personaHotkey.matches(keyCode: keyCode, modifierFlags: flags) {
            ErrorLogStore.shared.log("Hotkey(NSEvent): persona picker")
            DispatchQueue.main.async { [weak self] in
                self?.onPersonaPickerRequested?()
            }
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let activationHotkey = settingsStore.activationHotkey
        let askHotkey = settingsStore.askHotkey

        switch activeAction {
        case .activation:
            guard !activationHotkey.isRightCommandTrigger else { return }
            guard activationHotkey.keyCode == keyCode else { return }

            activeAction = nil
            ErrorLogStore.shared.log("Hotkey(NSEvent): activation up")
            DispatchQueue.main.async { [weak self] in
                self?.onActivationPressEnded?()
            }
        case .ask:
            guard askHotkey.keyCode == keyCode else { return }

            activeAction = nil
            ErrorLogStore.shared.log("Hotkey(NSEvent): ask up")
            DispatchQueue.main.async { [weak self] in
                self?.onAskPressEnded?()
            }
        default:
            return
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let activationHotkey = settingsStore.activationHotkey
        guard activationHotkey.isRightCommandTrigger || activationHotkey.isFunctionTrigger else { return }

        let isActivationModifierEvent = Int(event.keyCode) == activationHotkey.keyCode
        let activationModifierDown = isActivationModifierEvent
            && filteredFlags(event.modifierFlags) == activationHotkey.modifierFlags

        if activationModifierDown, activeAction == nil {
            activeAction = .activation
            ErrorLogStore.shared.log("Hotkey(NSEvent): modifier activation down")
            DispatchQueue.main.async { [weak self] in
                self?.onActivationPressBegan?()
            }
        } else if isActivationModifierEvent, !activationModifierDown, activeAction == .activation {
            activeAction = nil
            ErrorLogStore.shared.log("Hotkey(NSEvent): modifier activation up")
            DispatchQueue.main.async { [weak self] in
                self?.onActivationPressEnded?()
            }
        }
    }

    private func filteredFlags(_ flags: NSEvent.ModifierFlags) -> UInt {
        UInt(flags.intersection([.command, .shift, .control, .option, .function]).rawValue)
    }
}
