import AppKit
import ScreenCaptureKit

struct AskCapturedContext: Sendable {
    var selection: String?
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
    func capture(includeScreenshot: Bool, includeSelection: Bool) async -> AskCapturedContext
    /// Memory for a conversation started without a source application.
    func globalMemory() -> AskMemory?
}

extension AskContextCapturing {
    func globalMemory() -> AskMemory? { nil }

    func capture(includeScreenshot: Bool) async -> AskCapturedContext {
        await capture(includeScreenshot: includeScreenshot, includeSelection: true)
    }
}

@MainActor
final class AskContextCapture: AskContextCapturing {
    private static let screenCaptureRequestedKey = "ask.screenCaptureAccessRequested"
    private let injector: TextInjector
    private let memory: (any AskMemoryProviding)?
    private let accessibilityTrusted: () -> Bool
    private let captureScreenshot: (CGDirectDisplayID?) async throws -> String

    init(
        injector: TextInjector, memory: (any AskMemoryProviding)? = nil,
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        captureScreenshot: @escaping (CGDirectDisplayID?) async throws -> String = {
            try await AskContextCapture.screenshot(displayId: $0).dataURL
        }
    ) {
        self.injector = injector
        self.memory = memory
        self.accessibilityTrusted = accessibilityTrusted
        self.captureScreenshot = captureScreenshot
    }

    func globalMemory() -> AskMemory? {
        memory?.memory(bundleIdentifier: nil, appName: nil)
    }

    func capture(includeScreenshot: Bool, includeSelection: Bool) async -> AskCapturedContext {
        let app = NSWorkspace.shared.frontmostApplication
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let displayId = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // Capture before the launcher takes focus. The injector fixes the source
        // target before its first asynchronous accessibility read.
        let selection: TextSelectionSnapshot
        if includeSelection, accessibilityTrusted() {
            selection = await injector.selectionSnapshot(for: .readOnlyContext)
        } else {
            selection = TextSelectionSnapshot(source: "selection-not-requested-or-unavailable")
        }
        var result = AskCapturedContext(
            selection: selection.selectedText,
            source: [app?.localizedName, selection.windowTitle].compactMap { $0 }.joined(separator: " — "),
            sourceBundleID: app?.bundleIdentifier,
            // Resolved before the launcher takes focus, while the source app is still frontmost.
            memory: memory?.memory(bundleIdentifier: app?.bundleIdentifier, appName: app?.localizedName)
        )
        if includeScreenshot {
            do { result.screenshot = try await captureScreenshot(displayId) }
            catch { result.warning = error.localizedDescription }
        }
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

    static func screenshot(displayId: CGDirectDisplayID? = nil) async throws -> Screenshot {
        guard CGPreflightScreenCaptureAccess() else {
            // Registers Typeflux in the Screen Recording list the first time; the
            // system only shows its prompt while the decision is still undetermined.
            if !UserDefaults.standard.bool(forKey: screenCaptureRequestedKey) {
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
