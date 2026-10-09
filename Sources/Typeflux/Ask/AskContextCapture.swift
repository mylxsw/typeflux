import AppKit
import ScreenCaptureKit

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
}

extension AskContextCapturing {
    func requestScreenCapturePermission() -> Bool { screenCaptureAllowed }
    func globalMemory() -> AskMemory? { nil }
    func missingScreenshotWarning() -> String { AskContextCapture.missingScreenshotWarning(allowed: false) }
    func makeSelectionRequest() -> ReadOnlySelectionRequest { .frontmost() }

    func capture(includeScreenshot: Bool, includeSelection: Bool = true) async -> AskCapturedContext {
        await capture(includeScreenshot: includeScreenshot, includeSelection: includeSelection,
                      request: makeSelectionRequest())
    }
}

@MainActor
final class AskContextCapture: AskContextCapturing {
    private static let screenCaptureRequestedKey = "ask.screenCaptureAccessRequested"
    private let preflightScreenCapture: () -> Bool
    private let requestScreenCapture: () -> Bool
    private let injector: TextInjector
    private let memory: (any AskMemoryProviding)?
    private let frontmostProcessID: @MainActor () -> pid_t?
    private let accessibilityTrusted: () -> Bool
    private let captureScreenshot: (CGDirectDisplayID?) async throws -> String
    private let sourceTracker: AskSourceApplicationTracker

    init(
        injector: TextInjector, memory: (any AskMemoryProviding)? = nil,
        preflightScreenCapture: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestScreenCapture: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostProcessID: (@MainActor () -> pid_t?)? = nil,
        sourceTracker: AskSourceApplicationTracker? = nil,
        captureScreenshot: @escaping (CGDirectDisplayID?) async throws -> String = {
            try await AskContextCapture.screenshot(displayId: $0, requestAccessIfNeeded: false).dataURL
        }
    ) {
        self.preflightScreenCapture = preflightScreenCapture
        self.requestScreenCapture = requestScreenCapture
        self.injector = injector
        self.memory = memory
        let tracker = sourceTracker ?? AskSourceApplicationTracker.shared
        self.frontmostProcessID = frontmostProcessID ?? { tracker.resolve(.frontmost()).processID }
        self.accessibilityTrusted = accessibilityTrusted
        self.captureScreenshot = captureScreenshot
        self.sourceTracker = tracker
    }

    func globalMemory() -> AskMemory? {
        memory?.memory(bundleIdentifier: nil, appName: nil)
    }

    var screenCaptureAllowed: Bool { preflightScreenCapture() }

    func requestScreenCapturePermission() -> Bool {
        screenCaptureAllowed || requestScreenCapture()
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

    /// `CGPreflightScreenCaptureAccess` only reads the current state; it never adds
    /// the app to System Settings → Screen & System Audio Recording. The app is
    /// listed only after `CGRequestScreenCaptureAccess` (or a capture attempt), so
    /// send the request before pointing the user at the settings pane.
    /// - Returns: whether access is already granted.
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func screenshot(displayId: CGDirectDisplayID? = nil, requestAccessIfNeeded: Bool = true) async throws -> Screenshot {
        guard CGPreflightScreenCaptureAccess() else {
            // Registers Typeflux in the Screen Recording list the first time; the
            // system only shows its prompt while the decision is still undetermined.
            if requestAccessIfNeeded && !UserDefaults.standard.bool(forKey: screenCaptureRequestedKey) {
                UserDefaults.standard.set(true, forKey: screenCaptureRequestedKey)
                _ = CGRequestScreenCaptureAccess()
            }
            throw AskLocalError.message(L("ask.capture.permission"))
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayId }) ?? content.displays.first else {
            throw AskLocalError.message(L("ask.capture.unavailable"))
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        let scale = min(1, 1600 / Double(max(display.width, display.height)))
        config.width = max(1, Int(Double(display.width) * scale))
        config.height = max(1, Int(Double(display.height) * scale))
        config.showsCursor = false
        let image: CGImage
        if #available(macOS 14.0, *) {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } else {
            guard let legacy = CGWindowListCreateImage(CGDisplayBounds(display.displayID), .optionOnScreenOnly, kCGNullWindowID, .bestResolution) else {
                throw AskLocalError.message(L("ask.capture.unavailable"))
            }
            image = legacy
        }
        let target = NSImage(size: NSSize(width: config.width, height: config.height))
        target.lockFocus()
        NSImage(cgImage: image, size: .zero).draw(in: NSRect(origin: .zero, size: target.size))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]), data.count <= 2_000_000 else {
            throw AskLocalError.message(L("ask.capture.unavailable"))
        }
        return Screenshot(dataURL: "data:image/jpeg;base64," + data.base64EncodedString(), displayId: display.displayID, width: config.width, height: config.height)
    }
}

enum AskLocalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
