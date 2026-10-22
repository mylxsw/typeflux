import AppKit
import Darwin

/// Fault injection is available only in a debug build with a separately identified
/// fixture bundle. Production app identities cannot enable it through environment.
enum FeatureIsolationProbe {
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["TYPEFLUX_FEATURE_FIXTURE"] == "1"
            && Bundle.main.bundleIdentifier?.hasPrefix("ai.gulu.typeflux.isolation-test.") == true
        #else
        false
        #endif
    }

    @MainActor private static var terminationSignal: DispatchSourceSignal?
    @MainActor static func installCoverageExit() {
        guard enabled else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        source.setEventHandler { exit(0) }
        source.resume()
        terminationSignal = source
    }

    static func blockMainThread(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    static func flushCoverage() {
        #if DEBUG
        guard enabled, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__llvm_profile_write_file") else { return }
        let write = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        _ = write()
        #endif
    }

    @MainActor static var capture: (any AskContextCapturing)? {
        enabled ? EmptyContext() : nil
    }

    @MainActor private struct EmptyContext: AskContextCapturing {
        var screenCaptureAllowed: Bool { false }
        func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext {
            .init(source: "Isolation fixture")
        }
    }

    struct Screen: ScreenCapturing {
        func snapshot(_ request: ScreenCaptureRequest) async throws -> ScreenSnapshot {
            try await MainActor.run {
                let screen = NSScreen.main
                let size = screen?.frame.size ?? CGSize(width: 800, height: 600)
                guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenCaptureError.unavailable }
                context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.5, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
                guard let image = context.makeImage() else { throw ScreenCaptureError.unavailable }
                return ScreenSnapshot(displays: [.init(id: CGMainDisplayID(), frame: CGRect(origin: .zero, size: size), scale: 1, image: image)], windows: [])
            }
        }
    }
}
