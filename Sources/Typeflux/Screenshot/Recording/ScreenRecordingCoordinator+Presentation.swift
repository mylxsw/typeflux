import AppKit

extension ScreenRecordingCoordinator {
    var selectedSource: ScreenRecordingChoice? {
        choices.first { $0.id == selectedID }
    }

    var visibleSources: [ScreenRecordingChoice] {
        choices.filter { $0.target.kind == sourceKind }
    }

    var canStart: Bool {
        state == .setup && selectedSource != nil && permissionFailure != .permission
    }

    var selectionDuration: Double {
        max(0, trimEnd - trimStart)
    }

    var trimIsValid: Bool {
        (try? ScreenRecordingTrim(start: trimStart, end: trimEnd)
            .validated(duration: duration, format: options.format)) != nil
    }

    var canExport: Bool {
        state == .preview && trimIsValid
    }

    var devicePermissionURL: URL? {
        switch permissionFailure {
        case .microphonePermission: URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        case .cameraPermission: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        default: nil
        }
    }

    var permissionActionTitle: String {
        switch permissionFailure {
        case .microphonePermission: L("recording.microphoneSettings")
        case .cameraPermission: L("recording.cameraSettings")
        default: L("recording.permissions")
        }
    }

    var sourceSummary: String {
        guard let source = selectedSource else { return L("recording.selectSource") }
        if case let .region(_, rect) = source.target {
            return L("recording.region") + " · \(Int(rect.width)) × \(Int(rect.height))"
        }
        return source.title
    }

    var audioSummary: String {
        guard options.capturesAudio else { return L("recording.silent") }
        let titles = [(options.systemAudio, "recording.systemAudio"), (options.microphone, "recording.microphone")]
            .filter(\.0).map { L($0.1) }
        return titles.isEmpty ? L("recording.silent") : titles.joined(separator: " + ")
    }

    func setTrimStart(_ seconds: Double) {
        guard state == .preview, seconds.isFinite else { return }
        trimStart = min(max(0, seconds), max(0, trimEnd - 0.01))
        seek(trimStart)
    }

    func setTrimEnd(_ seconds: Double) {
        guard state == .preview, seconds.isFinite else { return }
        trimEnd = max(min(duration, seconds), min(duration, trimStart + 0.01))
        seek(trimEnd)
    }

    func resetTrim() {
        guard state == .preview else { return }
        trimStart = 0
        trimEnd = duration
        seek(0)
    }

    static func recoveryTitle(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? L("recording.recover")
    }
}
