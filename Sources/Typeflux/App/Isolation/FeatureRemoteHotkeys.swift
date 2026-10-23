import AppKit
import Foundation

struct FeatureHotkeyEvent: Codable, Sendable {
    let name: String
    var context: HotkeyEventContext?
    var target: HotkeyTarget?
    var message: String?
}

/// Feature controllers share one input owner in the host.
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
    private struct Bindings: Equatable {
        let primary: [HotkeyBinding?]
        let shortcuts: [HotkeyTarget: HotkeyBinding]
    }
    private let settings: SettingsStore
    private var bindings: Bindings?
    private var currentBindings: Bindings {
        .init(primary: [settings.activationHotkey, settings.auxiliaryHotkey, settings.askHotkey,
            settings.personaHotkey, settings.historyHotkey, settings.screenshotHotkey],
            shortcuts: EventTapHotkeyService.shortcutBindings(in: settings))
    }
    private let service: any HotkeyService
    private let dispatch: @MainActor (FeatureCommand) async throws -> Void
    init(settings: SettingsStore = SettingsStore(), service: (any HotkeyService)? = nil,
         dispatch: @escaping @MainActor (FeatureCommand) async throws -> Void = { try await FeatureProcess.dispatch($0) }) {
        self.settings = settings
        self.service = service ?? EventTapHotkeyService(settingsStore: settings)
        self.dispatch = dispatch
    }
    private let recording = HotkeyRecordingFlag()

    nonisolated static func recordingPredicate(_ flag: HotkeyRecordingFlag) -> @Sendable () -> Bool {
        { flag.value }
    }

    func start() {
        service.recordingStopEnabled = Self.recordingPredicate(recording)
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

    func handle(_ command: FeatureCommand) throws {
        switch command.action {
        case "start":
            if !FeatureIsolationProbe.enabled { service.start(); bindings = currentBindings }
        case "settings":
            let next = currentBindings
            guard next != bindings else { return }
            if !FeatureIsolationProbe.enabled { service.start(); bindings = next }
        case "stop", "shutdown": service.stop()
        case "settle": service.settleActivationGesture()
        case "recording": recording.value = try JSONDecoder().decode(Bool.self, from: command.payload)
        case "ping": break
        default: throw FeatureRPC.Failure.invalidMessage
        }
    }

    private func send(_ command: FeatureCommand) {
        var command = command
        command.latency = ShortcutLatency.current
        ShortcutLatency.record(.dispatched)
        Task {
            do { try await dispatch(command) }
            catch { ShortcutLatency.record(.failed, trace: command.latency) }
        }
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
