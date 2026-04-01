import Foundation

enum HotkeyAction {
    case activation
    case ask
    case personaPicker
}

protocol HotkeyService: AnyObject {
    var onActivationPressBegan: (() -> Void)? { get set }
    var onActivationPressEnded: (() -> Void)? { get set }
    var onAskPressBegan: (() -> Void)? { get set }
    var onAskPressEnded: (() -> Void)? { get set }
    var onPersonaPickerRequested: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start()
    func stop()
}
