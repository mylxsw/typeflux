import AppKit
import Foundation

final class EventTapHotkeyService: HotkeyService {
    private static let modifierActivationArbitrationDelay: TimeInterval = 0.12

    var onActivationPressBegan: (() -> Void)?
    var onActivationPressEnded: (() -> Void)?
    var onAskPressBegan: (() -> Void)?
    var onAskPressEnded: (() -> Void)?
    var onPersonaPickerRequested: (() -> Void)?
    var onError: ((String) -> Void)?

    private let settingsStore: SettingsStore

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
        pendingModifierActivationWorkItem?.cancel()
        pendingModifierActivationWorkItem = nil
        arbiter = HotkeyGestureArbiter()
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
        let keyCode = Int(event.keyCode)
        let flags = filteredFlags(event.modifierFlags)
        let activationHotkey = settingsStore.activationHotkey
        let askHotkey = settingsStore.askHotkey
        let personaHotkey = settingsStore.personaHotkey
        handleGestureEvents(
            arbiter.handleKeyDown(
                keyCode: keyCode,
                modifierFlags: flags,
                isRepeat: event.isARepeat,
                activationHotkey: activationHotkey,
                askHotkey: askHotkey,
                personaHotkey: personaHotkey
            )
        )
    }

    private func handleKeyUp(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let activationHotkey = settingsStore.activationHotkey
        let askHotkey = settingsStore.askHotkey
        handleGestureEvents(
            arbiter.handleKeyUp(
                keyCode: keyCode,
                activationHotkey: activationHotkey,
                askHotkey: askHotkey
            )
        )
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let activationHotkey = settingsStore.activationHotkey
        let askHotkey = settingsStore.askHotkey
        handleGestureEvents(
            arbiter.handleFlagsChanged(
                keyCode: Int(event.keyCode),
                modifierFlags: filteredFlags(event.modifierFlags),
                activationHotkey: activationHotkey,
                askHotkey: askHotkey
            )
        )
    }

    private func filteredFlags(_ flags: NSEvent.ModifierFlags) -> UInt {
        UInt(flags.intersection([.command, .shift, .control, .option, .function]).rawValue)
    }

    private func handleGestureEvents(_ events: [HotkeyGestureEvent]) {
        syncPendingModifierActivationTimer()

        for event in events {
            switch event {
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
            deadline: .now() + Self.modifierActivationArbitrationDelay,
            execute: workItem
        )
    }
}
