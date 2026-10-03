import ObjectiveC
import WebKit

/// CSP and content rules do not block WebRTC's STUN traffic. Executable previews
/// therefore require WebKit's engine-level switches, checked before loading any
/// content. These are SPI (not App Store APIs); absent/changed SPI fails closed.
/// See WebKit's WKPreferencesPrivate.h and the device-artifacts validation report.
@MainActor enum AskPreviewEnginePolicy {
    static func apply(to preferences: WKPreferences) throws {
        for (setter, getter) in [
            ("_setPeerConnectionEnabled:", "_peerConnectionEnabled"),
            ("_setMediaDevicesEnabled:", "_mediaDevicesEnabled"),
            ("_setScreenCaptureEnabled:", "_screenCaptureEnabled"),
            ("_setDNSPrefetchingEnabled:", "_dnsPrefetchingEnabled")
        ] {
            try disable(on: preferences, setter: setter, getter: getter)
        }
    }

    static func disable(on object: NSObject, setter: String, getter: String) throws {
        let set = NSSelectorFromString(setter), get = NSSelectorFromString(getter)
        guard let type = object_getClass(object),
              let setMethod = class_getInstanceMethod(type, set),
              let getMethod = class_getInstanceMethod(type, get),
              method_getNumberOfArguments(setMethod) == 3, method_getNumberOfArguments(getMethod) == 2,
              encoding(setMethod, argument: 2).map({ ["B", "c"].contains($0) }) == true,
              encoding(getMethod).map({ ["B", "c"].contains($0) }) == true,
              encoding(setMethod) == "v" else { throw AskArtifactError.previewDisabled }
        // Use the verified Objective-C BOOL ABI directly. KVC on a missing key
        // would raise an uncatchable Objective-C exception instead of failing closed.
        typealias SetBool = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        typealias GetBool = @convention(c) (AnyObject, Selector) -> ObjCBool
        let write = unsafeBitCast(method_getImplementation(setMethod), to: SetBool.self)
        let read = unsafeBitCast(method_getImplementation(getMethod), to: GetBool.self)
        write(object, set, false)
        guard !read(object, get).boolValue else { throw AskArtifactError.previewDisabled }
    }

    private static func encoding(_ method: Method, argument: UInt32? = nil) -> String? {
        guard let bytes = argument.map({ method_copyArgumentType(method, $0) }) ?? method_copyReturnType(method) else {
            return nil
        }
        defer { free(bytes) }
        return String(cString: bytes)
    }
}
