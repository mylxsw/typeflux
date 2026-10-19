import Foundation

/// State the corner card and notch island derive from the shared overlay model.
extension OverlayViewModel {
    /// The phase a top skin draws, or nil for presentations they leave to the shared cards.
    var voiceCapsulePhase: VoiceCapsulePhase? {
        switch presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview:
            .listening(handsFree: presentation.showsRecordingControls)
        case .processing, .processingPreview:
            .processing
        case .failure:
            .failure
        case .transcriptPreview, .notice, .personaPicker, .resultDialog:
            nil
        }
    }

    var drawsVoiceCapsuleSkin: Bool { skin.isTopAnchored && voiceCapsulePhase != nil }

    /// Top skins expand for the live transcript, streamed output, or a hover while recording.
    var voiceCapsuleExpanded: Bool {
        switch presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview:
            recordingPreviewExpanded || capsuleHovered
        case .processingPreview:
            true
        default:
            false
        }
    }

    var voiceCapsuleTranscriptLines: Int {
        VoiceCapsuleLayout.transcriptLines(for: skin, text: detailText)
    }

    var voiceCapsuleSnapshot: VoiceCapsuleSnapshot? {
        guard let phase = voiceCapsulePhase else { return nil }
        return VoiceCapsuleSnapshot(
            phase: phase,
            text: phase == .failure ? "" : detailText,
            level: level,
            progress: processingProgress,
            statusText: statusText,
            message: phase == .failure ? detailText : "",
            targetAppName: targetAppName,
            recordingStartedAt: recordingStartedAt,
            expanded: voiceCapsuleExpanded,
            transcriptLines: voiceCapsuleTranscriptLines,
            controlsRevealed: cardControlsRevealed,
            failureActions: failureActions,
            failureCountdown: phase == .failure ? failureCountdown : nil
        )
    }

    var voiceCapsuleActions: VoiceCapsuleActions {
        VoiceCapsuleActions(
            cancel: { [weak self] in self?.requestCancel() },
            confirm: { [weak self] in self?.requestConfirm() },
            dismiss: { [weak self] in self?.requestDismiss() },
            failureAction: { [weak self] index in self?.requestFailureAction(at: index) }
        )
    }
}
