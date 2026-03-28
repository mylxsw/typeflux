import Foundation

enum HotkeyAction {
    case activation
    case personaPicker
}

protocol HotkeyService: AnyObject {
    var onPressBegan: (() -> Void)? { get set }
    var onPressEnded: (() -> Void)? { get set }
    var onPersonaPickerRequested: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start()
    func stop()
}
