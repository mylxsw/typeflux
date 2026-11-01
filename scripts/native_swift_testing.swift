import AppKit
import Darwin
import Testing

/// AppKit may stop the run loop while dismissing a native menu. Swift's async
/// main drain then returns and exits before Testing finishes. Keep a synchronous
/// main alive; Testing's entry point owns the final exit status.
@main
struct NativeSwiftTesting {
    @MainActor static func main() {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_TEST_BUNDLE"],
              dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            fputs("Unable to load the test bundle\n", stderr)
            exit(1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task {
            application.activate(ignoringOtherApps: true)
            await Testing.__swiftPMEntryPoint() as Never
        }
        while true { application.run() }
    }
}
