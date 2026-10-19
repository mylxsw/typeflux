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
///
/// Size and corner radius are interpolated here, once, like the bottom capsule: the island stays
/// centered on the notch every frame, and its content keeps the expanded layout while it is
/// clipped, so nothing reflows or slides while the window resizes.
struct NotchIslandCapsule: View, Animatable {
    let snapshot: VoiceCapsuleSnapshot
    let notch: VoiceCapsuleNotchGeometry
    let actions: VoiceCapsuleActions
    private var expansion: CGFloat
    private var bodyHeight: CGFloat

    init(snapshot: VoiceCapsuleSnapshot, notch: VoiceCapsuleNotchGeometry, actions: VoiceCapsuleActions) {
        self.snapshot = snapshot
        self.notch = notch
        self.actions = actions
        expansion = snapshot.showsBody ? 1 : 0
        bodyHeight = VoiceCapsuleLayout.islandBodyHeight(lines: snapshot.transcriptLines)
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(expansion, bodyHeight) }
        set {
            expansion = newValue.first
            bodyHeight = newValue.second
        }
    }

    private var compactSize: CGSize {
        VoiceCapsuleLayout.contentSize(for: .notchIsland(notch), sizeClass: .compact)
    }

    private var expandedWidth: CGFloat {
        VoiceCapsuleLayout.contentSize(for: .notchIsland(notch), sizeClass: .expanded).width
    }

    private var compactRadius: CGFloat { min(16, notch.height * 0.55) }

    /// The transcript fades in over the last part of the opening and out over the first part of the
    /// closing, so it is only legible while the island has room for it.
    static func contentOpacity(expansion: CGFloat) -> CGFloat {
        max(0, min(1, (expansion - 0.55) / 0.45))
    }

    var body: some View {
        let fillet = VoiceCapsuleLayout.islandFillet
        let width = compactSize.width + (expandedWidth - compactSize.width) * expansion
        let shape = NotchIslandShape(bottomRadius: compactRadius + (26 - compactRadius) * expansion, fillet: fillet)
        VStack(spacing: 0) {
            ears
            if expansion > 0 {
                bodySection
                    // Lay the body out at its final width and clip it, instead of rewrapping each frame.
                    .frame(width: expandedWidth, alignment: .topLeading)
                    .frame(width: width, alignment: .top)
                    .opacity(Self.contentOpacity(expansion: expansion))
                    .allowsHitTesting(snapshot.showsBody)
                    .accessibilityHidden(!snapshot.showsBody)
            }
        }
        .padding(.horizontal, fillet)
        .frame(width: width + fillet * 2,
               height: snapshot.phase == .failure ? nil : notch.height + bodyHeight * expansion, alignment: .top)
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
        // Geometry is interpolated once, above. Re-lay out children at each intermediate
        // size instead of animating their positions a second time.
        .transaction { $0.animation = nil }
    }

    private var orbDiameter: CGFloat { max(14, min(20, notch.height - 10)) }

    /// The same items compact and expanded, so the row never reflows while the island grows.
    private var ears: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                VoiceCapsuleOrb(phase: snapshot.phase, level: snapshot.level, diameter: orbDiameter)
                if snapshot.phase.isListening, let startedAt = snapshot.recordingStartedAt {
                    Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                        .font(.system(size: 12))
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
        case .listening: nil
        case .processing: VoiceCapsuleCopy.percent(snapshot.progress)
        case .failure: VoiceCapsuleCopy.state(for: snapshot)
        }
        if let text {
            Text(text)
                .font(.system(size: 12))
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
                    .font(.system(size: 12.5))
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
