import Foundation

enum HotkeyAction {
    case activation
    case ask
    case personaPicker
    case history
}

struct HotkeyEventContext: Sendable, Equatable {
    let detectedAt: Date
    /// Physical event time in seconds since system startup.
    let uptime: TimeInterval

    init(detectedAt: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.detectedAt = detectedAt
        self.uptime = uptime
    }
}

protocol HotkeyService: AnyObject {
    var onActivationTap: ((HotkeyEventContext) -> Void)? { get set }
    var onActivationPressBegan: ((HotkeyEventContext) -> Void)? { get set }
    var onActivationPressEnded: ((HotkeyEventContext) -> Void)? { get set }
    var onActivationCancelled: (() -> Void)? { get set }
    var onAskPressBegan: ((HotkeyEventContext) -> Void)? { get set }
    var onAskPressEnded: (() -> Void)? { get set }
    var onPersonaPickerRequested: (() -> Void)? { get set }
    var onHistoryRequested: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start()
    func stop()
    func settleActivationGesture()
}

extension HotkeyService {
    func settleActivationGesture() {}
}
