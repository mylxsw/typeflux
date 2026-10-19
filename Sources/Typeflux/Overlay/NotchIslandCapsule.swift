import SwiftUI

/// A black island hanging from the top edge: square top corners that flare into the menu bar
/// through reverse fillets, and rounded bottom corners.
struct NotchIslandShape: Shape {
    var bottomRadius: CGFloat
    var fillet: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let fillet = min(fillet, width / 4, height)
        let radius = max(0, min(bottomRadius, (width - fillet * 2) / 2, height - fillet))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + width, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + width - fillet, y: rect.minY + fillet),
                          control: CGPoint(x: rect.minX + width - fillet, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX + width - fillet, y: rect.minY + height),
                    tangent2End: CGPoint(x: rect.minX + fillet, y: rect.minY + height), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX + fillet, y: rect.minY + height),
                    tangent2End: CGPoint(x: rect.minX + fillet, y: rect.minY + fillet), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX + fillet, y: rect.minY + fillet))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                          control: CGPoint(x: rect.minX + fillet, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The capsule grown out of the camera housing. Compact: the orb and timer on the left ear,
/// the waveform or progress on the right. Expanded: the transcript hangs below the menu bar.
struct NotchIslandCapsule: View {
    let snapshot: VoiceCapsuleSnapshot
    let notch: VoiceCapsuleNotchGeometry
    let actions: VoiceCapsuleActions

    private var size: CGSize {
        VoiceCapsuleLayout.contentSize(for: .notchIsland(notch), sizeClass: snapshot.showsBody ? .expanded : .compact,
                                       transcriptLines: snapshot.transcriptLines)
    }

    private var bottomRadius: CGFloat {
        snapshot.showsBody ? 26 : min(16, notch.height * 0.55)
    }

    var body: some View {
        let fillet = VoiceCapsuleLayout.islandFillet
        let shape = NotchIslandShape(bottomRadius: bottomRadius, fillet: fillet)
        VStack(spacing: 0) {
            ears
            if snapshot.showsBody {
                bodySection.transition(.opacity)
            }
        }
        .padding(.horizontal, fillet)
        .frame(width: size.width + fillet * 2,
               height: snapshot.phase == .failure ? nil : size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .overlay(alignment: .bottom) {
            if snapshot.phase == .processing {
                VoiceCapsuleProgressBar(progress: snapshot.progress)
                    .padding(.horizontal, fillet + 18)
            } else if let countdown = snapshot.failureCountdown {
                OverlayFailureCountdownBar(countdown: countdown)
                    .padding(.horizontal, fillet + 18)
            }
        }
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("voiceCapsule.accessibility.label"))
    }

    private var orbDiameter: CGFloat { max(14, min(20, notch.height - 10)) }

    private var ears: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                VoiceCapsuleOrb(phase: snapshot.phase, level: snapshot.level, diameter: orbDiameter)
                if snapshot.showsBody {
                    Text(verbatim: VoiceCapsuleCopy.productName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                if snapshot.phase.isListening, let startedAt = snapshot.recordingStartedAt {
                    Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            // Nothing is drawn behind the camera.
            Spacer(minLength: notch.isHardware ? notch.width : 8)
            HStack(spacing: 8) {
                rightStatus
                rightAccessory
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: notch.height)
        .lineLimit(1)
    }

    @ViewBuilder
    private var rightStatus: some View {
        let text: String? = switch snapshot.phase {
        case .listening: snapshot.showsBody ? VoiceCapsuleCopy.state(for: snapshot) : nil
        case .processing: snapshot.showsBody
            ? "\(VoiceCapsuleCopy.state(for: snapshot)) \(VoiceCapsuleCopy.percent(snapshot.progress))"
            : VoiceCapsuleCopy.percent(snapshot.progress)
        case .failure: VoiceCapsuleCopy.state(for: snapshot)
        }
        if let text {
            Text(text)
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.62))
        }
    }

    @ViewBuilder
    private var rightAccessory: some View {
        switch snapshot.phase {
        case .listening:
            LevelWaveform(level: snapshot.level, activeColor: Color.white.opacity(0.95))
                .frame(width: 32, height: max(12, notch.height - 12))
        case .processing:
            VoiceCapsuleProgressRing(progress: snapshot.progress)
        case .failure:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if snapshot.phase == .failure {
            VStack(alignment: .leading, spacing: 12) {
                Text(snapshot.message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineSpacing(3)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Spacer(minLength: 0)
                    VoiceCapsuleFailureActions(snapshot: snapshot, actions: actions)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 16)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VoiceCapsuleTranscript(text: snapshot.text, fontSize: VoiceCapsuleLayout.islandTranscriptFontSize,
                                       lineHeight: VoiceCapsuleLayout.islandTranscriptLineHeight,
                                       lineCount: snapshot.transcriptLines)
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if snapshot.phase.isListening {
                        VoiceCapsulePillButton(title: L("common.cancel"), prominent: false, action: actions.cancel)
                        VoiceCapsulePillButton(title: L("common.done"), prominent: true, action: actions.confirm)
                    }
                }
                .frame(height: 26)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }
}
