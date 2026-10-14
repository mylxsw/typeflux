import AppKit
import AVFoundation
import ScreenCaptureKit

extension ScreenRecordingCoordinator {
    static func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    static func authorize(_ options: ScreenRecordingOptions) async throws {
        for (type, enabled, failure) in [(AVMediaType.audio, options.microphone && options.capturesAudio,
                                          ScreenRecordingFailure.microphonePermission),
                                         (.video, options.camera, .cameraPermission)] where enabled {
            let status = AVCaptureDevice.authorizationStatus(for: type)
            if status == .authorized {
                continue
            }
            guard status == .notDetermined, await AVCaptureDevice.requestAccess(for: type) else { throw failure }
        }
    }

    static func catalog() async throws -> [ScreenRecordingChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let controls = Set(ScreenshotCaptureWindowPolicy.excludedWindowIDs())
        let displays = content.displays.enumerated().map { index, display in
            let name = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
                    .displayID
            }?.localizedName ?? L("recording.display", index + 1)
            return ScreenRecordingChoice(id: "display-\(display.displayID)",
                                         title: "\(name) · \(display.width) × \(display.height)",
                                         target: .display(display.displayID), frame: CGDisplayBounds(display.displayID),
                                         scale: CGFloat(CGDisplayCopyDisplayMode(display.displayID)?
                                             .pixelWidth ?? display.width) / max(
                                             1,
                                             CGDisplayBounds(display.displayID).width
                                         ))
        }
        let windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50
                && !controls.contains($0.windowID) && $0.owningApplication != nil
        }.map { window in
            let screen = NSScreen.screens.first { screen in
                ScreenCaptureGeometry.flipped(
                    screen.frame,
                    primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 0
                ).contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
            }
            return ScreenRecordingChoice(id: "window-\(window.windowID)",
                                         title: (window.owningApplication?.applicationName ?? "") + " — " +
                                             (window.title ?? ""),
                                         target: .window(window.windowID), frame: window.frame,
                                         scale: screen?.backingScaleFactor ?? 2)
        }
        let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        return displays + windows.sorted { left, right in
            guard case let .window(leftID) = left.target, case let .window(rightID) = right.target else { return false }
            return (order.firstIndex(of: leftID) ?? Int.max) < (order.firstIndex(of: rightID) ?? Int.max)
        }
    }
}
