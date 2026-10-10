import CoreGraphics
import Foundation
@testable import Typeflux

/// Screen Recording access without touching the system. `request()` grants access
/// when `grantsRequest` is set.
final class FakeScreenCapturePermission: ScreenCapturePermissionProviding {
    var granted: Bool
    var grantsRequest = false
    private(set) var requests = 0
    private(set) var onceRequests = 0
    private(set) var settingsOpened = 0

    init(granted: Bool = false) {
        self.granted = granted
    }

    var isGranted: Bool { granted }

    @discardableResult
    func request() -> Bool {
        if granted { return true }
        requests += 1
        granted = grantsRequest
        return granted
    }

    func requestOnce() { onceRequests += 1 }

    func openSystemSettings() { settingsOpened += 1 }
}

/// Returns a fixed snapshot, or throws, and records every request.
final class FakeScreenCapturer: ScreenCapturing {
    var result: Result<ScreenSnapshot, Error>
    private(set) var requests: [ScreenCaptureRequest] = []

    init(_ result: Result<ScreenSnapshot, Error>) {
        self.result = result
    }

    func snapshot(_ request: ScreenCaptureRequest) async throws -> ScreenSnapshot {
        requests.append(request)
        return try result.get()
    }
}

enum ScreenCaptureTestSupport {
    /// A solid image in device RGB.
    static func image(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func window(_ id: CGWindowID, processID: pid_t, frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 80),
                       title: String? = nil) -> ScreenSnapshot.Window {
        ScreenSnapshot.Window(id: id, frame: frame, processID: processID, bundleIdentifier: "app.\(processID)",
                              applicationName: "App \(processID)", title: title, layer: 0)
    }
}
