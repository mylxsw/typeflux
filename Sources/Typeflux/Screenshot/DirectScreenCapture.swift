import AppKit
import ScreenCaptureKit

extension ScreenCaptureContent {
    /// Explicit screenshots do not need a shareable-content enumeration when no
    /// capture controls need exclusion. AI context retains the filtered path.
    @available(macOS 26.0, *)
    static func direct() async throws -> ScreenCaptureContent {
        try Task.checkCancellation()
        let displays = try activeDisplays()
        let windows = ScreenshotWindowCatalog.shared.begin()
        return ScreenCaptureContent(displays: displays, windows: [], latestWindows: { windows.snapshot },
                                    capture: { display, excluded, size in
            guard excluded.isEmpty else { throw ScreenCaptureError.unavailable }
            try Task.checkCancellation()
            let configuration = SCScreenshotConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.showsCursor = false
            configuration.dynamicRange = .sdr
            return try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureScreenshot(rect: display.frame, configuration: configuration) { output, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image = output?.sdrImage { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: ScreenCaptureError.unavailable) }
                }
            }
        })
    }

    static func activeDisplays() throws -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            throw ScreenCaptureError.unavailable
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            throw ScreenCaptureError.unavailable
        }
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map { id in
            let frame = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            return Display(id: id, frame: frame,
                           scale: ScreenCaptureGeometry.backingScale(pixelWidth: mode?.pixelWidth ?? 0,
                                                                     pointWidth: mode?.width ?? 0))
        }
    }
}

/// Window snapping is best effort. A slow metadata query must neither delay the
/// frozen screen nor accumulate more queries when the user repeatedly captures.
final class ScreenshotWindowCatalog: @unchecked Sendable {
    static let shared = ScreenshotWindowCatalog()

    final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [ScreenSnapshot.Window] = []
        var snapshot: [ScreenSnapshot.Window] { lock.withLock { windows } }
        fileprivate func finish(_ windows: [ScreenSnapshot.Window]) { lock.withLock { self.windows = windows } }
    }

    private let lock = NSLock()
    private var active: Request?
    private let load: @Sendable () -> [ScreenSnapshot.Window]

    init(load: @escaping @Sendable () -> [ScreenSnapshot.Window] = ScreenshotWindowCatalog.systemWindows) {
        self.load = load
    }

    func begin() -> Request {
        lock.withLock {
            if let active { return active }
            let request = Request()
            active = request
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                request.finish(load())
                lock.withLock { active = nil }
            }
            return request
        }
    }

    static func systemWindows() -> [ScreenSnapshot.Window] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var bundles: [pid_t: String] = [:]
        return entries.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let id = ScreenshotCaptureWindowPolicy.captureWindowID(number.intValue),
                  let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), !frame.isEmpty,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else { return nil }
            let pid = owner.int32Value
            if bundles[pid] == nil { bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            return ScreenSnapshot.Window(id: id, frame: frame, processID: pid, bundleIdentifier: bundles[pid],
                                         applicationName: entry[kCGWindowOwnerName as String] as? String,
                                         title: entry[kCGWindowName as String] as? String,
                                         layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
        }
    }
}
