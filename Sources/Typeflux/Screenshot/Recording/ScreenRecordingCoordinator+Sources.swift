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
        let displays = content.displays.map {
            ScreenRecordingChoice(id: "display-\($0.displayID)", title: L("recording.display", Int($0.displayID)),
                                  target: .display($0.displayID))
        }
        let windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50
                && !controls.contains($0.windowID) && $0.owningApplication != nil
        }.map {
            ScreenRecordingChoice(id: "window-\($0.windowID)",
                                  title: ($0.owningApplication?.applicationName ?? "") + " — " + ($0.title ?? ""),
                                  target: .window($0.windowID))
        }
        return displays + windows
    }
}
