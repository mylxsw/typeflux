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

    var displays: Displays = .all
    var resolution: Resolution = .native
    var includesWindows = true
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

/// Freezes displays and lists windows through `ScreenCaptureContent`, leaving
/// Typeflux's own windows out of both.
struct ScreenCaptureService: ScreenCapturing {
    private let permission: any ScreenCapturePermissionProviding
    private let loadContent: () async throws -> ScreenCaptureContent
    private let ownProcessID: pid_t

    init(permission: any ScreenCapturePermissionProviding = ScreenCapturePermission.live,
         ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
         loadContent: @escaping () async throws -> ScreenCaptureContent = ScreenCaptureContent.system) {
        self.permission = permission
        self.ownProcessID = ownProcessID
        self.loadContent = loadContent
    }

    func snapshot(_ request: ScreenCaptureRequest) async throws -> ScreenSnapshot {
        guard permission.isGranted else { throw ScreenCaptureError.permissionDenied }
        let content = try await loadContent()
        let displays = Self.displays(content.displays, matching: request.displays)
        guard !displays.isEmpty else { throw ScreenCaptureError.unavailable }
        let ownWindows = content.windows.filter { $0.processID == ownProcessID }.map(\.id)
        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, display) in displays.enumerated() {
                let size = ScreenCaptureGeometry.pixelSize(pointSize: display.frame.size, scale: display.scale,
                                                           resolution: request.resolution)
                group.addTask {
                    let captured = try await content.capture(display, ownWindows, size)
                    // The macOS 13 fallback always returns native pixels.
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
        return ScreenSnapshot(
            displays: zip(displays, images).map { display, image in
                ScreenSnapshot.Display(id: display.id, frame: display.frame, scale: display.scale, image: image)
            },
            windows: request.includesWindows ? content.windows.filter { $0.processID != ownProcessID } : []
        )
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
