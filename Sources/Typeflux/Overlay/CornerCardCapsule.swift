import SwiftUI

/// A Siri-like card below the menu bar: the orb, a title and live state, and the transcript
/// when it expands. Always dark so it reads on any wallpaper.
struct CornerCardCapsule: View {
    let snapshot: VoiceCapsuleSnapshot
    let actions: VoiceCapsuleActions

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: snapshot.showsBody ? 24 : VoiceCapsuleLayout.cardCompactHeight / 2,
                         style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if snapshot.showsBody {
                bodySection.transition(.opacity)
            }
        }
        .frame(width: VoiceCapsuleLayout.cardWidth,
               height: snapshot.phase == .failure ? nil
                   : (snapshot.showsBody ? VoiceCapsuleLayout.cardExpandedHeight(lines: snapshot.transcriptLines)
                       : VoiceCapsuleLayout.cardCompactHeight),
               alignment: .top)
        .background(background)
        .overlay(alignment: .bottom) {
            if snapshot.phase == .processing {
                VoiceCapsuleProgressBar(progress: snapshot.progress)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.32), radius: 20, x: 0, y: 14)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("voiceCapsule.accessibility.label"))
    }

    private var background: some View {
        // Glass alone turns grey over bright wallpapers; a dark veil keeps the card legible.
        LiquidGlassShapeBackground(shape: shape, cornerRadius: snapshot.showsBody ? 24 : nil,
                                   tintOpacity: 0.06, strokeOpacity: 0, lineWidth: 0.5)
            .overlay(shape.fill(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.62)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VoiceCapsuleOrb(phase: snapshot.phase, level: snapshot.level, diameter: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: VoiceCapsuleCopy.productName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                subtitle
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: VoiceCapsuleLayout.cardCompactHeight)
    }

    @ViewBuilder
    private var subtitle: some View {
        let base = Text(VoiceCapsuleCopy.subtitle(for: snapshot))
        if snapshot.phase.isListening, let startedAt = snapshot.recordingStartedAt {
            base + Text(verbatim: " · ") + Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
        } else {
            base
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch snapshot.phase {
        case .listening:
            HStack(spacing: 8) {
                if snapshot.phase.showsRecordingControls {
                    VoiceCapsuleRoundButton(systemName: "xmark", inverted: false,
                                            accessibilityLabel: L("common.cancel"), action: actions.cancel)
                }
                LevelWaveform(level: snapshot.level, activeColor: Color.white.opacity(0.95))
                    .frame(width: 38, height: OverlayWaveformMetrics.maximumBarHeight)
                if snapshot.phase.showsRecordingControls {
                    VoiceCapsuleRoundButton(systemName: "checkmark", inverted: true,
                                            accessibilityLabel: L("common.done"), action: actions.confirm)
                }
            }
        case .processing:
            Text(VoiceCapsuleCopy.percent(snapshot.progress))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.75))
        case .completed:
            EmptyView()
        case .failure:
            VoiceCapsuleRoundButton(systemName: "xmark", inverted: false,
                                    accessibilityLabel: L("voiceCapsule.action.close"), action: actions.dismiss)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if snapshot.phase == .failure {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(showsIndicators: false) {
                    Text(snapshot.message)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 100)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    VoiceCapsuleFailureActions(snapshot: snapshot, actions: actions)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VoiceCapsuleTranscript(text: snapshot.text, fontSize: VoiceCapsuleLayout.cardTranscriptFontSize,
                                       lineHeight: VoiceCapsuleLayout.cardTranscriptLineHeight,
                                       lineCount: snapshot.transcriptLines, placeholder: L("voiceCapsule.placeholder"))
                Text(VoiceCapsuleCopy.hint(for: snapshot.phase))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .opacity(snapshot.phase.isListening ? 1 : 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 2)
        }
    }
}
