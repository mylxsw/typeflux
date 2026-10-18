import AppKit

extension ScreenRecordingCoordinator {
    var selectionHint: String {
        switch sourceKind {
        case .region: L("recording.regionHint")
        case .window: L("recording.pickWindow")
        case .display: L("recording.pickDisplay")
        }
    }

    var outputSize: CGSize {
        (try? ScreenRecordingGeometry.outputSize(points: selectedSource?.frame.size ?? media.size,
                                                 scale: selectedSource?.scale ?? 1,
                                                 maxDimension: options.dimension)) ?? media.size
    }

    var outputSummary: String {
        let size = (state == .preview || state == .exporting) ? previewOutputSize : outputSize
        return "\(Int(size.width)) × \(Int(size.height)) · \(options.format.rawValue.uppercased()) · \(options.captureFPS) FPS · " +
            audioSummary +
            (options.format == .gif ? " · " + L("recording.max30") : " · " + L(
                "recording.countdownSummary",
                options.countdown
            ))
    }

    var previewOutputSize: CGSize {
        guard options.format == .gif else { return media.size }
        return (try? ScreenRecordingGeometry.outputSize(points: media.size, scale: 1, maxDimension: 960)) ?? media.size
    }

    /// Proportional to the exported length. Each recorded AAC track is ~128 kbps; export mixes
    /// the kept tracks into one, so dropping every track removes that share.
    var estimatedBytes: Int64 {
        guard duration > 0 else { return 0 }
        let gif = options.format == .gif
        let output = edit.outputDuration(selectionDuration)
        let seconds = gif ? min(output, ScreenRecordingEdit.gifLimit) : output
        let audioRate = Self.audioBytesPerSecond
        let videoRate = max(0, Double(media.fileBytes) / duration - audioRate * Double(edit.tracks.count))
        let audio = gif || edit.includedTracks.isEmpty ? 0 : audioRate
        return Int64((videoRate * (gif ? 1.5 : 1) + audio) * seconds)
    }

    static let audioBytesPerSecond = 128_000.0 / 8

    /// Frames per second for frame stepping: the source rate, or GIF's fixed 10.
    var frameRate: Int {
        options.format == .gif ? 10 : media.fps > 0 ? max(1, Int(media.fps.rounded())) : options.captureFPS
    }

    /// Exported length after the speed change.
    var outputDuration: Double {
        edit.outputDuration(selectionDuration)
    }

    var gifTooLong: Bool {
        options.format == .gif && outputDuration > ScreenRecordingEdit.gifLimit + 0.01
    }

    /// "Video · System audio + Microphone · 2× · 24.0 s" for the export bar.
    var exportSummary: String {
        var parts: [String]
        if options.format == .gif {
            parts = [L("recording.kind.gif"), L("recording.silent"), L("recording.max30")]
        } else {
            let kept = edit.includedTracks.map(\.title)
            let audio = edit.tracks.isEmpty ? L("recording.silent")
                : kept.isEmpty ? L("recording.allTracksOff") : kept.joined(separator: " + ")
            parts = [L("recording.kind.mp4"), audio]
        }
        if edit.rate != 1 {
            parts.append(ScreenRecordingEdit.rateTitle(edit.rate))
            parts.append(L("recording.outputSeconds", outputDuration))
        }
        return parts.joined(separator: " · ")
    }

    var selectedSource: ScreenRecordingChoice? {
        choices.first { $0.id == selectedID }
    }

    var visibleSources: [ScreenRecordingChoice] {
        choices.filter { $0.target.kind == sourceKind }
    }

    var canStart: Bool {
        state == .setup && selectedSource != nil && permissionFailure == nil && {
            if case let .region(_, rect) = selectedSource?.target {
                return ScreenRecordingLayout.validRegion(rect)
            }
            return true
        }()
    }

    var selectionDuration: Double {
        max(0, trimEnd - trimStart)
    }

    var trimIsValid: Bool {
        (try? ScreenRecordingTrim(start: trimStart, end: trimEnd, rate: edit.rate)
            .validated(duration: duration, format: options.format)) != nil
    }

    var canExport: Bool {
        state == .preview && canUsePreview && trimIsValid
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
        guard state == .preview, canUsePreview, seconds.isFinite else { return }
        trimStart = min(max(0, seconds), max(0, trimEnd - min(0.5, duration)))
        seek(trimStart)
    }

    func setTrimEnd(_ seconds: Double) {
        guard state == .preview, canUsePreview, seconds.isFinite else { return }
        trimEnd = max(min(duration, seconds), min(duration, trimStart + min(0.5, duration)))
        seek(trimEnd)
    }

    func resetTrim() {
        guard state == .preview, canUsePreview else { return }
        trimStart = 0
        trimEnd = duration
        seek(0)
    }

    static func recoveryTitle(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? L("recording.recover")
    }
}
