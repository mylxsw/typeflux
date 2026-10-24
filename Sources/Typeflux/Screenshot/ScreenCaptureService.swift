import CoreGraphics
import Foundation

struct ScreenCaptureRequest: Equatable {
    enum Displays: Equatable {
        case all
        /// The display with this ID, or the first display when it is missing or nil.
        case preferred(CGDirectDisplayID?)
    }

    enum Resolution: Equatable {
        /// One image pixel per display pixel.
        case native
        /// The display's point size scaled down so the longer side fits.
        case fitting(maxDimension: Int)
    }

    enum WindowExclusion: Equatable {
        /// Automatic AI screen context omits the app's own UI.
        case ownApplication
        /// Explicit screenshots keep app pages and omit only capture controls.
        case screenshotControls
    }

    var displays: Displays = .all
    var resolution: Resolution = .native
    var includesWindows = true
    var windowExclusion: WindowExclusion = .ownApplication
}

enum ScreenCaptureError: Error, Equatable {
    case permissionDenied
    /// No display to capture, or the system returned no usable image.
    case unavailable
}

protocol ScreenCapturing {
    /// Captures the requested displays at once. Never asks for Screen Recording access:
    /// throws `permissionDenied` instead, so a prompt only follows an explicit user action.
    func snapshot(_ request: ScreenCaptureRequest) async throws -> ScreenSnapshot
}

/// Freezes displays and lists windows through `ScreenCaptureContent`, applying the same
/// exclusion policy to the pixels and selectable windows.
struct ScreenCaptureService: ScreenCapturing {
    private let permission: any ScreenCapturePermissionProviding
    private let loadContent: () async throws -> ScreenCaptureContent
    private let ownProcessID: pid_t
    private let captureControlWindowIDs: @MainActor () -> [CGWindowID]

    init(permission: any ScreenCapturePermissionProviding = ScreenCapturePermission.live,
         ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
         captureControlWindowIDs: @escaping @MainActor () -> [CGWindowID] = ScreenshotCaptureWindowPolicy.excludedWindowIDs,
         loadContent: @escaping () async throws -> ScreenCaptureContent = ScreenCaptureContent.system) {
        self.permission = permission
        self.ownProcessID = ownProcessID
        self.captureControlWindowIDs = captureControlWindowIDs
        self.loadContent = loadContent
    }

    func snapshot(_ request: ScreenCaptureRequest) async throws -> ScreenSnapshot {
        try Task.checkCancellation()
        guard permission.isGranted else { throw ScreenCaptureError.permissionDenied }
        let content = try await measuredContent()
        try Task.checkCancellation()
        let displays = Self.displays(content.displays, matching: request.displays)
        guard !displays.isEmpty else { throw ScreenCaptureError.unavailable }
        let excludedWindows: [CGWindowID]
        switch request.windowExclusion {
        case .ownApplication:
            excludedWindows = content.windows.filter { $0.processID == ownProcessID }.map(\.id)
        case .screenshotControls:
            let controls = Set(await captureControlWindowIDs())
            try Task.checkCancellation()
            excludedWindows = content.windows.filter { $0.processID == ownProcessID && controls.contains($0.id) }.map(\.id)
        }
        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, display) in displays.enumerated() {
                try Task.checkCancellation()
                let size = ScreenCaptureGeometry.pixelSize(pointSize: display.frame.size, scale: display.scale,
                                                           resolution: request.resolution)
                group.addTask {
                    try Task.checkCancellation()
                    let captured = try await Self.capture(content, display: display, excluded: excludedWindows,
                                                          size: size, index: index + 1, count: displays.count)
                    try Task.checkCancellation()
                    // The macOS 13 fallback always returns native pixels.
                    ShortcutLatency.record(.imageResizeStarted, itemIndex: index + 1, itemCount: displays.count)
                    defer { ShortcutLatency.record(.imageResizeFinished, itemIndex: index + 1, itemCount: displays.count) }
                    guard let image = ScreenCaptureGeometry.resized(captured, to: size) else {
                        throw ScreenCaptureError.unavailable
                    }
                    return (index, image)
                }
            }
            var images = [CGImage?](repeating: nil, count: displays.count)
            for try await (index, image) in group { images[index] = image }
            return images.compactMap { $0 }
        }
        try Task.checkCancellation()
        let snapshot = ScreenSnapshot(
            displays: zip(displays, images).map { display, image in
                ScreenSnapshot.Display(id: display.id, frame: display.frame, scale: display.scale, image: image)
            },
            windows: request.includesWindows ? content.windows.filter { !excludedWindows.contains($0.id) } : []
        )
        ShortcutLatency.record(.captureAssembled)
        return snapshot
    }

    private func measuredContent() async throws -> ScreenCaptureContent {
        ShortcutLatency.record(.contentLoadStarted)
        defer { ShortcutLatency.record(.contentLoadFinished) }
        return try await loadContent()
    }

    private static func capture(_ content: ScreenCaptureContent, display: ScreenCaptureContent.Display,
                                excluded: [CGWindowID], size: ScreenPixelSize, index: Int, count: Int) async throws -> CGImage {
        ShortcutLatency.record(.displayCaptureStarted, itemIndex: index, itemCount: count)
        defer { ShortcutLatency.record(.displayCaptureFinished, itemIndex: index, itemCount: count) }
        return try await content.capture(display, excluded, size)
    }

    static func displays(_ displays: [ScreenCaptureContent.Display],
                         matching selection: ScreenCaptureRequest.Displays) -> [ScreenCaptureContent.Display] {
        switch selection {
        case .all:
            return displays
        case let .preferred(id):
            return [displays.first { $0.id == id } ?? displays.first].compactMap { $0 }
        }
    }
}
