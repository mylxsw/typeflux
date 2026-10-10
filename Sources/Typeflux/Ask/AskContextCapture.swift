import AppKit

struct AskCapturedContext: Sendable {
    var selection: String?
    var selectionStatus: String?
    var source: String?
    /// The source app, so the composer can draw its icon.
    var sourceBundleID: String?
    var screenshot: String?
    var warning: String?
    var capturedAt = Date()
    var memory: AskMemory?
}

@MainActor
protocol AskContextCapturing {
    /// A read-only check; querying it must never request permission.
    var screenCaptureAllowed: Bool { get }
    /// Called only after an explicit screenshot action.
    func requestScreenCapturePermission() -> Bool
    func makeSelectionRequest() -> ReadOnlySelectionRequest
    func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext
    /// Memory for a conversation started without a source application.
    func globalMemory() -> AskMemory?
    /// Why a screenshot is missing when none was taken: no permission, or unavailable.
    /// Reads the permission without asking for it.
    func missingScreenshotWarning() -> String
    /// Lists Typeflux in System Settings → Screen & System Audio Recording and opens it.
    func openScreenCaptureSettings()
}

extension AskContextCapturing {
    func requestScreenCapturePermission() -> Bool { screenCaptureAllowed }
    func globalMemory() -> AskMemory? { nil }
    func missingScreenshotWarning() -> String { AskContextCapture.missingScreenshotWarning(allowed: false) }
    func makeSelectionRequest() -> ReadOnlySelectionRequest { .frontmost() }
    func openScreenCaptureSettings() {}

    func capture(includeScreenshot: Bool, includeSelection: Bool = true) async -> AskCapturedContext {
        await capture(includeScreenshot: includeScreenshot, includeSelection: includeSelection,
                      request: makeSelectionRequest())
    }
}

@MainActor
final class AskContextCapture: AskContextCapturing {
    private let permission: any ScreenCapturePermissionProviding
    private let injector: TextInjector
    private let memory: (any AskMemoryProviding)?
    private let frontmostProcessID: @MainActor () -> pid_t?
    private let accessibilityTrusted: () -> Bool
    private let captureScreenshot: (CGDirectDisplayID?) async throws -> String
    private let sourceTracker: AskSourceApplicationTracker

    /// - Parameter captureScreenshot: replaces the capture through `capturer`.
    init(
        injector: TextInjector, memory: (any AskMemoryProviding)? = nil,
        permission: any ScreenCapturePermissionProviding = ScreenCapturePermission.live,
        capturer: any ScreenCapturing = ScreenCaptureService(),
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostProcessID: (@MainActor () -> pid_t?)? = nil,
        sourceTracker: AskSourceApplicationTracker? = nil,
        captureScreenshot: ((CGDirectDisplayID?) async throws -> String)? = nil
    ) {
        self.permission = permission
        self.injector = injector
        self.memory = memory
        let tracker = sourceTracker ?? AskSourceApplicationTracker.shared
        self.frontmostProcessID = frontmostProcessID ?? { tracker.resolve(.frontmost()).processID }
        self.accessibilityTrusted = accessibilityTrusted
        self.captureScreenshot = captureScreenshot ?? {
            try await AskContextCapture.screenshot(displayId: $0, requestAccessIfNeeded: false,
                                                   permission: permission, capturer: capturer).dataURL
        }
        self.sourceTracker = tracker
    }

    func globalMemory() -> AskMemory? {
        memory?.memory(bundleIdentifier: nil, appName: nil)
    }

    var screenCaptureAllowed: Bool { permission.isGranted }

    func requestScreenCapturePermission() -> Bool {
        permission.request()
    }

    func openScreenCaptureSettings() {
        permission.registerAndOpenSettings()
    }

    func missingScreenshotWarning() -> String {
        Self.missingScreenshotWarning(allowed: screenCaptureAllowed)
    }

    static func missingScreenshotWarning(allowed: Bool) -> String {
        L(allowed ? "ask.capture.unavailable" : "ask.capture.permission")
    }

    func makeSelectionRequest() -> ReadOnlySelectionRequest { sourceTracker.resolve(injector.makeReadOnlySelectionRequest()) }

    func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext {
        func discarded(_ status: String) -> AskCapturedContext {
            request.log(status: status)
            return AskCapturedContext(selectionStatus: status)
        }
        guard !Task.isCancelled else { return discarded("capture-cancelled") }
        guard request.matches(processID: frontmostProcessID()) else {
            return discarded(request.processID == nil ? "source-unavailable" : "target-changed")
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let displayId = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // The screenshot runs alongside the accessibility read rather than after it;
        // the launcher is already on screen and is excluded from the capture.
        let screenshotAllowed = screenCaptureAllowed
        let screenshotTask: Task<String, Error>? = includeScreenshot && screenshotAllowed
            ? Task { [captureScreenshot] in try await captureScreenshot(displayId) } : nil
        defer { screenshotTask?.cancel() }
        // The request was fixed before the launcher took focus and before any
        // draft/operation-queue waits. Never recapture the frontmost app here.
        let selection: TextSelectionSnapshot
        if !includeSelection {
            selection = TextSelectionSnapshot(source: "selection-not-requested")
        } else if let snapshot = request.nativeSnapshot, snapshot.source == "system-ui-fallback" {
            selection = snapshot
        } else if request.nativeSnapshot != nil || accessibilityTrusted() {
            selection = await injector.readOnlySelectionSnapshot(for: request)
        } else {
            selection = TextSelectionSnapshot(source: "permission-missing")
        }
        request.log(status: selection.source, details: ["phase": "capture-result"])
        guard !Task.isCancelled else { return discarded("capture-cancelled") }
        guard request.matches(processID: frontmostProcessID()), selection.source != "target-changed" else {
            return discarded("target-changed")
        }
        var result = AskCapturedContext(
            selection: selection.selectedText,
            selectionStatus: selection.source,
            source: [request.processName, selection.windowTitle].compactMap { $0 }.joined(separator: " — "),
            sourceBundleID: request.bundleIdentifier,
            // Source identity stays the same even after asynchronous selection reads.
            memory: memory?.memory(bundleIdentifier: request.bundleIdentifier, appName: request.processName)
        )
        if includeScreenshot && !screenshotAllowed { result.warning = Self.missingScreenshotWarning(allowed: false) }
        if let screenshotTask {
            do { result.screenshot = try await screenshotTask.value }
            catch { result.warning = error.localizedDescription }
        }
        guard !Task.isCancelled else { return discarded("capture-cancelled") }
        guard request.matches(processID: frontmostProcessID()) else { return discarded("target-changed") }
        return result
    }

    struct Screenshot {
        var dataURL: String
        var displayId: CGDirectDisplayID
        var width: Int
        var height: Int
    }

    /// One display (`displayId`, or the first one), downscaled to at most 1600 px and
    /// encoded as a JPEG data URL. Typeflux's own windows are left out of the capture.
    /// - Parameter requestAccessIfNeeded: on the first missing-permission failure, asks
    ///   once so Typeflux is listed in System Settings → Screen & System Audio Recording.
    static func screenshot(
        displayId: CGDirectDisplayID? = nil, requestAccessIfNeeded: Bool = true,
        permission: any ScreenCapturePermissionProviding = ScreenCapturePermission.live,
        capturer: any ScreenCapturing = ScreenCaptureService()
    ) async throws -> Screenshot {
        guard permission.isGranted else {
            if requestAccessIfNeeded { permission.requestOnce() }
            throw AskLocalError.message(L("ask.capture.permission"))
        }
        let snapshot: ScreenSnapshot
        do {
            snapshot = try await capturer.snapshot(ScreenCaptureRequest(
                displays: .preferred(displayId), resolution: .fitting(maxDimension: 1600), includesWindows: false
            ))
        } catch let error as ScreenCaptureError {
            let key = error == .permissionDenied ? "ask.capture.permission" : "ask.capture.unavailable"
            throw AskLocalError.message(L(key))
        }
        guard let display = snapshot.displays.first,
              let dataURL = jpegDataURL(display.image)
        else { throw AskLocalError.message(L("ask.capture.unavailable")) }
        return Screenshot(dataURL: dataURL, displayId: display.id,
                          width: display.image.width, height: display.image.height)
    }

    /// JPEG at quality 0.6; nil when encoding fails or the result exceeds 2 MB.
    static func jpegDataURL(_ image: CGImage) -> String? {
        let target = NSImage(size: NSSize(width: image.width, height: image.height))
        target.lockFocus()
        NSImage(cgImage: image, size: .zero).draw(in: NSRect(origin: .zero, size: target.size))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]),
              data.count <= 2_000_000 else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}

enum AskLocalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
