import Foundation
import IOKit.ps

/// The source is installed and delivers callbacks on the main run loop.
final class SemanticIndexPower {
    private let changed: @MainActor () -> Void
    private var source: CFRunLoopSource?

    @MainActor init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let observation = Unmanaged<SemanticIndexPower>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observation.changed() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    static func hasExternalPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let power = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (power as String) == kIOPMACPowerKey
    }
}
