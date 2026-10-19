import SwiftUI

/// A Siri-like card below the menu bar: the orb, a title and live state, and the transcript
/// when it expands. Always dark so it reads on any wallpaper. The orb alone shows the voice;
/// the controls appear in the timer's place only while the pointer is over the card.
struct CornerCardCapsule: View {
    let snapshot: VoiceCapsuleSnapshot
    let actions: VoiceCapsuleActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let slotSize = CGSize(width: 64, height: 28)

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
            } else if let countdown = snapshot.failureCountdown {
                OverlayFailureCountdownBar(countdown: countdown)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.32), radius: 20, x: 0, y: 14)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("voiceCapsule.accessibility.label"))
        // Hidden controls stay reachable for VoiceOver without hovering.
        .accessibilityAction(named: L("common.cancel")) {
            if snapshot.phase.cardControls.contains(.cancel) { actions.cancel() }
        }
        .accessibilityAction(named: L("common.done")) {
            if snapshot.phase.cardControls.contains(.confirm) { actions.confirm() }
        }
    }

    private var background: some View {
        // Glass alone turns grey over bright wallpapers; a dark veil keeps the card legible.
        LiquidGlassShapeBackground(shape: shape, cornerRadius: snapshot.showsBody ? 24 : nil,
                                   tintOpacity: 0.06, strokeOpacity: 0, lineWidth: 0.5)
            .overlay(shape.fill(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.62)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VoiceCapsuleOrb(phase: snapshot.phase, level: snapshot.level, diameter: 40, showsRipples: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: VoiceCapsuleCopy.productName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                Text(VoiceCapsuleCopy.subtitle(for: snapshot))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            slot
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: VoiceCapsuleLayout.cardCompactHeight)
    }

    /// One fixed slot: the timer or progress at rest, the controls under the pointer. Its size never
    /// changes, so the title does not move when the controls appear.
    private var slot: some View {
        let controls = snapshot.phase.cardControls
        let revealed = snapshot.controlsRevealed && !controls.isEmpty
        return ZStack(alignment: .trailing) {
            meta
                .opacity(revealed ? 0 : 1)
                .offset(x: revealed && !reduceMotion ? 4 : 0)
            HStack(spacing: 6) {
                if controls.contains(.cancel) {
                    VoiceCapsuleRoundButton(systemName: "xmark", inverted: false,
                                            accessibilityLabel: L("common.cancel"), action: actions.cancel)
                }
                if controls.contains(.confirm) {
                    VoiceCapsuleRoundButton(systemName: "checkmark", inverted: true,
                                            accessibilityLabel: L("common.done"), action: actions.confirm)
                }
            }
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed || reduceMotion ? 1 : 0.88, anchor: .trailing)
            .allowsHitTesting(revealed)
            .accessibilityHidden(!revealed)
        }
        .frame(width: Self.slotSize.width, height: Self.slotSize.height, alignment: .trailing)
        .animation(.easeOut(duration: 0.16), value: revealed)
    }

    @ViewBuilder
    private var meta: some View {
        switch snapshot.phase {
        case .listening:
            if let startedAt = snapshot.recordingStartedAt {
                Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        case .processing:
            Text(VoiceCapsuleCopy.percent(snapshot.progress))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.7))
        case .failure:
            EmptyView()
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
            VoiceCapsuleTranscript(text: snapshot.text, fontSize: VoiceCapsuleLayout.cardTranscriptFontSize,
                                   lineHeight: VoiceCapsuleLayout.cardTranscriptLineHeight,
                                   lineCount: snapshot.transcriptLines)
                .padding(.horizontal, 18)
                .padding(.top, 2)
        }
    }
}
