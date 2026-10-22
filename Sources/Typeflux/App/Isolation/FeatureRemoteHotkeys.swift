import AppKit
import Foundation

struct FeatureHotkeyEvent: Codable, Sendable {
    let name: String
    var context: HotkeyEventContext?
    var target: HotkeyTarget?
    var message: String?
}

/// The host keeps existing workflow callbacks; event taps run in their own process.
final class FeatureRemoteHotkeys: HotkeyService {
    var recordingStopEnabled: (() -> Bool)?
    var onRecordingStop: (() -> Void)?
    var onAuxiliaryPressBegan: ((HotkeyEventContext) -> Void)?
    var onAuxiliaryPressEnded: ((HotkeyEventContext) -> Void)?
    var onAuxiliaryPromoted: ((HotkeyEventContext) -> Void)?
    var onActivationTap: ((HotkeyEventContext) -> Void)?
    var onActivationPressBegan: ((HotkeyEventContext) -> Void)?
    var onActivationPressEnded: ((HotkeyEventContext) -> Void)?
    var onActivationCancelled: (() -> Void)?
    var onAskPressBegan: ((HotkeyEventContext) -> Void)?
    var onAskPressEnded: (() -> Void)?
    var onPersonaPickerRequested: (() -> Void)?
    var onHistoryRequested: (() -> Void)?
    var onScreenshotRequested: (() -> Void)?
    var onShortcutRequested: ((HotkeyTarget) -> Void)?
    var onShortcutReleased: ((HotkeyTarget) -> Void)?
    var onShortcutCancelled: ((HotkeyTarget) -> Void)?
    var onError: ((String) -> Void)?
    func start() { guard FeatureProcess.owns(.host) else { return }; Task { @MainActor in FeatureProcess.send(.init(destination: .shortcuts, action: "start")) } }
    func stop() { guard FeatureProcess.owns(.host) else { return }; Task { @MainActor in FeatureProcess.send(.init(destination: .shortcuts, action: "stop")) } }
    func settleActivationGesture() { Task { @MainActor in FeatureProcess.send(.init(destination: .shortcuts, action: "settle")) } }

    func receive(_ event: FeatureHotkeyEvent) {
        switch event.name {
        case "onRecordingStop": onRecordingStop?()
        case "onAuxiliaryPressBegan": if let value = event.context { onAuxiliaryPressBegan?(value) }
        case "onAuxiliaryPressEnded": if let value = event.context { onAuxiliaryPressEnded?(value) }
        case "onAuxiliaryPromoted": if let value = event.context { onAuxiliaryPromoted?(value) }
        case "onActivationTap": if let value = event.context { onActivationTap?(value) }
        case "onActivationPressBegan": if let value = event.context { onActivationPressBegan?(value) }
        case "onActivationPressEnded": if let value = event.context { onActivationPressEnded?(value) }
        case "onActivationCancelled": onActivationCancelled?()
        case "onAskPressBegan": if let value = event.context { onAskPressBegan?(value) }
        case "onAskPressEnded": onAskPressEnded?()
        case "onPersonaPickerRequested": onPersonaPickerRequested?()
        case "onHistoryRequested": onHistoryRequested?()
        case "onScreenshotRequested": onScreenshotRequested?()
        case "onShortcutRequested": if let value = event.target { onShortcutRequested?(value) }
        case "onShortcutReleased": if let value = event.target { onShortcutReleased?(value) }
        case "onShortcutCancelled": if let value = event.target { onShortcutCancelled?(value) }
        case "onError": if let value = event.message { onError?(value) }
        default: break
        }
    }
}

@MainActor
final class FeatureShortcutHost {
    static let shared = FeatureShortcutHost()
    private let service = EventTapHotkeyService(settingsStore: SettingsStore())
    private var recording = false

    func start() {
        FeatureProcess.handle = { [weak self] command in
            guard let self else { throw FeatureRPC.Failure.unavailable }
            #if DEBUG
            if FeatureIsolationProbe.enabled, command.action == "probeExercise" { return try JSONEncoder().encode(getpid()) }
            if FeatureIsolationProbe.enabled, command.action == "probeFreeze" {
                FeatureIsolationProbe.blockMainThread(seconds: 10)
                return Data()
            }
            if FeatureIsolationProbe.enabled, command.action == "probeRoute" {
                return try await FeatureProcess.route(JSONDecoder().decode(FeatureCommand.self, from: command.payload))
            }
            if FeatureIsolationProbe.enabled, command.action == "probeDispatch" {
                try await FeatureProcess.dispatch(JSONDecoder().decode(FeatureCommand.self, from: command.payload))
                return Data()
            }
            if FeatureIsolationProbe.enabled, command.action == "probeShortcut" {
                self.event(try JSONDecoder().decode(FeatureHotkeyEvent.self, from: command.payload))
                return Data()
            }
            #endif
            switch command.action {
            case "start", "settings": if !FeatureIsolationProbe.enabled { service.start() }
            case "stop", "shutdown": service.stop()
            case "settle": service.settleActivationGesture()
            case "recording": recording = (try? JSONDecoder().decode(Bool.self, from: command.payload)) ?? false
            case "ping": break
            default: throw FeatureRPC.Failure.invalidMessage
            }
            return Data()
        }
        FeatureProcess.configure(api: AskAPIClient())
        service.recordingStopEnabled = { [weak self] in self?.recording ?? false }
        service.onRecordingStop = { [weak self] in self?.event(.init(name: "onRecordingStop")) }
        service.onAuxiliaryPressBegan = { [weak self] value in self?.event(.init(name: "onAuxiliaryPressBegan", context: value)) }
        service.onAuxiliaryPressEnded = { [weak self] value in self?.event(.init(name: "onAuxiliaryPressEnded", context: value)) }
        service.onAuxiliaryPromoted = { [weak self] value in self?.event(.init(name: "onAuxiliaryPromoted", context: value)) }
        service.onActivationTap = { [weak self] value in self?.event(.init(name: "onActivationTap", context: value)) }
        service.onActivationPressBegan = { [weak self] value in self?.event(.init(name: "onActivationPressBegan", context: value)) }
        service.onActivationPressEnded = { [weak self] value in self?.event(.init(name: "onActivationPressEnded", context: value)) }
        service.onActivationCancelled = { [weak self] in self?.event(.init(name: "onActivationCancelled")) }
        service.onAskPressBegan = { [weak self] _ in self?.send(.init(destination: .launcher, action: "toggleLauncher")) }
        service.onAskPressEnded = { _ = 0 }
        service.onPersonaPickerRequested = { [weak self] in self?.event(.init(name: "onPersonaPickerRequested")) }
        service.onHistoryRequested = { [weak self] in self?.send(.init(destination: .clipboard, action: "toggleClipboard")) }
        service.onScreenshotRequested = { [weak self] in self?.send(.init(destination: .screenshot, action: "screenshot")) }
        service.onShortcutRequested = { [weak self] value in self?.event(.init(name: "onShortcutRequested", target: value)) }
        service.onShortcutReleased = { [weak self] value in self?.event(.init(name: "onShortcutReleased", target: value)) }
        service.onShortcutCancelled = { [weak self] value in self?.event(.init(name: "onShortcutCancelled", target: value)) }
        service.onError = { [weak self] value in self?.event(.init(name: "onError", message: value)) }
    }

    private func send(_ command: FeatureCommand) {
        Task { try? await FeatureProcess.dispatch(command) }
    }

    private func event(_ event: FeatureHotkeyEvent) {
        let destination = event.target.map(FeatureHotkeyEvent.destination(for:)) ?? .host
        guard let payload = try? JSONEncoder().encode(event) else { return }
        send(.init(destination: destination, action: "hotkey", payload: payload))
    }
}

extension FeatureHotkeyEvent {
    static func destination(for target: HotkeyTarget) -> FeatureRole {
        switch target {
        case .action(.ring): return .ring
        case .action(.openChat): return .chat
        case .action(.openStudio): return .settings
        case .action(.screenshotText), .action(.screenshotTranslation): return .screenshot
        case .action(.openNotes): return .notes
        case .action(.openWordBook): return .wordBook
        case .action(.openHelp): return .help
        case .action(.translate): return .translation
        case .keyword: return .launcher
        default: return .host
        }
    }
}
