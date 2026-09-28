import AppKit
import ScreenCaptureKit

struct AskCapturedContext: Sendable {
    var selection: String?
    var source: String?
    var screenshot: String?
    var warning: String?
    var capturedAt = Date()
}

@MainActor
protocol AskContextCapturing {
    func capture(includeScreenshot: Bool) async -> AskCapturedContext
}

@MainActor
final class AskContextCapture: AskContextCapturing {
    private let injector: TextInjector

    init(injector: TextInjector) { self.injector = injector }

    func capture(includeScreenshot: Bool) async -> AskCapturedContext {
        let app = NSWorkspace.shared.frontmostApplication
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let displayId = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // Capture before the launcher takes focus. The injector fixes the source
        // target before its first asynchronous accessibility read.
        let selection: TextSelectionSnapshot
        if AXIsProcessTrusted() { selection = await injector.selectionSnapshot(for: .automaticInsertion) }
        else { selection = TextSelectionSnapshot(source: "accessibility-unavailable") }
        var result = AskCapturedContext(
            selection: selection.selectedText,
            source: [app?.localizedName, selection.windowTitle].compactMap { $0 }.joined(separator: " — ")
        )
        if includeScreenshot {
            do { result.screenshot = try await Self.screenshot(displayId: displayId).dataURL }
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

    static func screenshot(displayId: CGDirectDisplayID? = nil) async throws -> Screenshot {
        guard CGPreflightScreenCaptureAccess() else {
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
