import CoreWLAN
import Darwin
import Foundation

/// Constructed only by the disposable CLI child. Tests inject harmless controls.
struct NativeSystemAdapter {
    struct Control {
        var read: () throws -> Bool
        var write: (Bool) throws -> Void
    }

    var wifi: () throws -> Control = {
        guard let interface = CWWiFiClient.shared().interface() else { throw NativeSystemFailure.notExecuted }
        return Control(read: { interface.powerOn() }, write: { try interface.setPower($0) })
    }
    var bluetooth: () throws -> Control = {
        let library = try NativeSystemLibrary(path: "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth")
        return try bluetoothControl(library: library)
    }
    var scroll: () throws -> Control = {
        try scrollControl(library: NativeSystemLibrary(
            path: "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport"))
    }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var notifyScrollChange: () -> Void = {
        DistributedNotificationCenter.default().postNotificationName(
            .init("SwipeScrollDirectionDidChangeNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func bluetoothControl(library: any NativeSystemSymbols) throws -> Control {
        let get = unsafeBitCast(try library.symbol("IOBluetoothPreferenceGetControllerPowerState"),
                               to: (@convention(c) () -> Int32).self)
        let set = unsafeBitCast(try library.symbol("IOBluetoothPreferenceSetControllerPowerState"),
                               to: (@convention(c) (Int32) -> Void).self)
        return Control(read: { withExtendedLifetime(library) { get() != 0 } },
                       write: { value in withExtendedLifetime(library) { set(value ? 1 : 0) } })
    }

    static func scrollControl(library: any NativeSystemSymbols) throws -> Control {
        let get = unsafeBitCast(try library.symbol("swipeScrollDirection"), to: (@convention(c) () -> Bool).self)
        let set = unsafeBitCast(try library.symbol("setSwipeScrollDirection"), to: (@convention(c) (Bool) -> Void).self)
        return Control(read: { withExtendedLifetime(library) { get() } },
                       write: { value in withExtendedLifetime(library) { set(value) } })
    }

    func execute(_ operation: NativeSystemOperation) -> NativeSystemOutcome {
        if operation == .probe { return .completed }
        let control: Control
        let target: Bool
        do {
            switch operation {
            case .toggleWiFi: control = try wifi()
            case .toggleBluetooth: control = try bluetooth()
            case .toggleScrollDirection: control = try scroll()
            case .probe: return .completed
            }
            target = try !control.read()
        } catch { return .notExecuted }
        // Once the setter is entered, even an error cannot establish no effect.
        do {
            try control.write(target)
            for _ in 0 ..< (operation == .toggleBluetooth ? 20 : 1) {
                if operation == .toggleBluetooth { sleep(0.1) }
                if try control.read() == target {
                    if operation == .toggleScrollDirection { notifyScrollChange() }
                    return .completed
                }
            }
        } catch { return .unknown }
        return .unknown
    }
}

protocol NativeSystemSymbols: AnyObject {
    func symbol(_ name: String) throws -> UnsafeMutableRawPointer
}

final class NativeSystemLibrary: NativeSystemSymbols {
    private let handle: UnsafeMutableRawPointer
    init(path: String) throws {
        guard let handle = dlopen(path, RTLD_LAZY) else { throw NativeSystemFailure.notExecuted }
        self.handle = handle
    }
    deinit { dlclose(handle) }
    func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
        guard let symbol = dlsym(handle, name) else { throw NativeSystemFailure.notExecuted }
        return symbol
    }
}
