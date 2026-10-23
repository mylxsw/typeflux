import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureShortcutOwnerTests {
    @Test func oneListenerRefreshesBindingsAndKeepsLogicalShortcutDestinations() async throws {
        let domain = "feature-input-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        let service = FeatureHotkeyFixture()
        var commands: [FeatureCommand] = []
        let owner = FeatureShortcutHost(settings: settings, service: service, dispatch: { commands.append($0) })
        owner.start()
        try owner.handle(.init(destination: .shortcuts, action: "start"))
        defaults.set(1, forKey: "fixture.unrelatedSetting")
        try owner.handle(.init(destination: .shortcuts, action: "settings"))
        #expect(service.starts == 1, "Unrelated settings must not reset the input listener or its gestures")
        settings.activationHotkey = HotkeyBinding(keyCode: 7, modifierFlags: 0)
        try owner.handle(.init(destination: .shortcuts, action: "settings"))
        #expect(service.starts == 2)
        try owner.handle(.init(destination: .shortcuts, action: "recording", payload: JSONEncoder().encode(true)))
        #expect(service.recordingStopEnabled?() == true)
        service.onAskPressBegan?(.init(uptime: 1))
        service.onHistoryRequested?()
        service.onScreenshotRequested?()
        service.onShortcutRequested?(.action(.ring))
        service.onShortcutReleased?(.action(.ring))
        service.onActivationPressBegan?(.init(uptime: 2))
        for _ in 0..<100 where commands.count < 6 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(commands.contains { $0.destination == .launcher && $0.action == "toggleLauncher" })
        #expect(commands.contains { $0.destination == .clipboard && $0.action == "toggleClipboard" })
        #expect(commands.contains { $0.destination == .screenshot && $0.action == "screenshot" })
        #expect(commands.filter { $0.destination == .ring }.count == 2)
        try owner.handle(.init(destination: .shortcuts, action: "settle"))
        try owner.handle(.init(destination: .shortcuts, action: "ping"))
        try owner.handle(.init(destination: .shortcuts, action: "stop"))
        #expect(service.stops == 1 && service.settles == 1)
        #expect(throws: FeatureRPC.Failure.invalidMessage) { try owner.handle(.init(destination: .shortcuts, action: "invalid")) }
    }

    @Test func inputRunLoopDrainsWhileTheMainThreadIsWaiting() {
        let loop = HotkeyInputRunLoop.shared.value
        #expect(!CFEqual(loop, CFRunLoopGetMain()))
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { done.signal() }
        CFRunLoopWakeUp(loop)
        #expect(done.wait(timeout: .now() + 1) == .success)
    }
}

private final class FeatureHotkeyFixture: HotkeyService {
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
    var starts = 0, stops = 0, settles = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func settleActivationGesture() { settles += 1 }
}


extension FeatureShortcutOwnerTests {
    @Test func recordingPredicateCanRunOutsideTheUIActor() async {
        let flag = HotkeyRecordingFlag()
        let predicate = FeatureShortcutHost.recordingPredicate(flag)
        flag.value = true
        #expect(await Task.detached { predicate() }.value)
        flag.value = false
        #expect(await Task.detached { predicate() }.value == false)
    }
}
