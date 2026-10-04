import SwiftUI

extension AskTheme {
    /// The heaviest reasoning level reads in violet, apart from the accent levels below it.
    static let reasoningTopText = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.49, green: 0.25, blue: 0.94, alpha: 1),
        dark: NSColor(calibratedRed: 0.71, green: 0.55, blue: 1.0, alpha: 1)
    )

    /// The colour a reasoning level's name takes in the chip and the card title.
    static func reasoningText(_ effort: AskReasoningEffort, defaultColor: Color) -> Color {
        switch effort {
        case .providerDefault: defaultColor
        case .max: reasoningTopText
        default: accentText
        }
    }
}

/// The card behind the composer's model chip: the reasoning level on a slider, the
/// model it applies to, and a second page listing the models.
struct AskModelEffortCard: View {
    enum Page { case effort, models }

    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    @Binding var effort: AskReasoningEffort
    var hasImage = false
    var loggedIn: Bool
    var onManage: (() -> Void)?
    var offersCloudSignIn = false
    var close: () -> Void = {}
    @State var page: Page
    /// The glass menu hosts this card in its own panel, rendered once from a snapshot:
    /// writes through the bindings reach the model but never redraw the card. These
    /// copies drive what the card shows and are written through on every change.
    @State private var liveEffort: AskReasoningEffort
    @State private var liveReference: String

    init(library: AskModelLibrary, reference: Binding<String>, effort: Binding<AskReasoningEffort>,
         hasImage: Bool = false, loggedIn: Bool, onManage: (() -> Void)? = nil, offersCloudSignIn: Bool = false,
         close: @escaping () -> Void = {}, page: Page = .effort) {
        self.library = library
        _reference = reference
        _effort = effort
        self.hasImage = hasImage
        self.loggedIn = loggedIn
        self.onManage = onManage
        self.offersCloudSignIn = offersCloudSignIn
        self.close = close
        _page = State(initialValue: page)
        _liveEffort = State(initialValue: effort.wrappedValue)
        _liveReference = State(initialValue: reference.wrappedValue)
    }

    /// The slider and ↺ change the level the card shows and the composer uses.
    private var effortSelection: Binding<AskReasoningEffort> {
        Binding(get: { liveEffort }, set: { value in
            liveEffort = value
            effort = value
        })
    }

    /// Picking a model may move the level to one it offers; read it back afterwards.
    private var referenceSelection: Binding<String> {
        Binding(get: { liveReference }, set: { value in
            liveReference = value
            reference = value
            liveEffort = effort
        })
    }

    /// Sized like the composer's other glass menus: 13pt rows, 11pt captions.
    static let width: CGFloat = 272
    /// The model list keeps the width of the composer's model menu.
    static let modelsWidth: CGFloat = 330

    private var levels: [AskReasoningEffort] {
        AskReasoningEffort.levels(for: library.registry.resolve(liveReference)?.1)
    }

    var body: some View {
        Group {
            if page == .models { modelsPage } else { effortPage }
        }
        .frame(width: page == .models ? Self.modelsWidth : Self.width)
    }

    @ViewBuilder private var effortPage: some View {
        let shown = liveEffort.nearest(in: levels)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Color.clear.frame(width: 24, height: 24)
                VStack(spacing: 1) {
                    Text(levels.isEmpty ? library.name(for: liveReference) : shown.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(levels.isEmpty ? StudioTheme.textPrimary
                            : AskTheme.reasoningText(shown, defaultColor: StudioTheme.textPrimary))
                        .lineLimit(1)
                        .animation(.easeOut(duration: 0.2), value: shown)
                    Button { page = .models } label: {
                        HStack(spacing: 2) {
                            Text(levels.isEmpty ? L("ask.reasoning.changeModel") : library.name(for: liveReference))
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AskPressableStyle.subtle)
                    .accessibilityLabel(L("ask.reasoning.changeModel"))
                }
                .frame(maxWidth: .infinity)
                Button { effortSelection.wrappedValue = .providerDefault } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AskPressableStyle.subtle)
                .disabled(levels.isEmpty || liveEffort == .providerDefault)
                .opacity(levels.isEmpty || liveEffort == .providerDefault ? 0.3 : 1)
                .help(L("ask.reasoning.reset"))
                .accessibilityLabel(L("ask.reasoning.reset"))
            }
            if levels.isEmpty {
                Text(L("ask.reasoning.unsupported"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 10)
            } else {
                AskEffortSlider(levels: levels, effort: effortSelection)
                    .padding(.top, 10)
                Text(shown.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
    }

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { page = .effort } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(L("ask.reasoning.title"))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(AskPressableStyle.subtle)
            .padding(.leading, 8).padding(.top, 10)
            AskModelChoices(library: library, reference: referenceSelection, hasImage: hasImage, loggedIn: loggedIn,
                            dismiss: { page = .effort }, composerStyle: true,
                            onManage: onManage.map { manage in { close(); manage() } },
                            offersCloudSignIn: offersCloudSignIn)
        }
    }
}

/// The reasoning slider: a recessed track with a stop per level the model offers,
/// a liquid fill up to the chosen level, and a raised knob. At the top level the
/// fill reaches the end of the track. "Auto" shows an empty track and a dashed knob.
struct AskEffortSlider: View {
    let levels: [AskReasoningEffort]
    @Binding var effort: AskReasoningEffort

    static let height: CGFloat = 26
    static let knob: CGFloat = 20
    static let inset: CGFloat = 3

    /// The knob's centre for stop `index` of `count` on a track `width` wide; the end
    /// stops sit flush with the track's ends.
    static func knobCenter(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let edge = inset + knob / 2
        guard count > 1 else { return width / 2 }
        return edge + CGFloat(index) * (width - 2 * edge) / CGFloat(count - 1)
    }

    /// The fill reaches past the knob to its outer edge, so the top stop fills the track.
    static func fillWidth(knobCenter: CGFloat, width: CGFloat) -> CGFloat {
        min(width, knobCenter + knob / 2 + inset)
    }

    /// The stop nearest to `x`.
    static func index(at position: CGFloat, count: Int, width: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        return (0 ..< count).min { abs(knobCenter(index: $0, count: count, width: width) - position)
            < abs(knobCenter(index: $1, count: count, width: width) - position) } ?? 0
    }

    private var auto: Bool { effort == .providerDefault }
    /// "Auto" rests the knob on the middle stop.
    private var index: Int { auto ? (levels.count - 1) / 2 : levels.firstIndex(of: effort.nearest(in: levels)) ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let center = Self.knobCenter(index: index, count: levels.count, width: width)
            ZStack(alignment: .leading) {
                Capsule().fill(AskTheme.hoverFill)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                ForEach(levels.indices, id: \.self) { stop in
                    Circle().fill(StudioTheme.textTertiary)
                        .frame(width: 4, height: 4)
                        .position(x: Self.knobCenter(index: stop, count: levels.count, width: width), y: Self.height / 2)
                        .opacity(!auto && stop <= index ? 0 : 1)
                }
                AskLiquidFill(top: effort == .max)
                    .frame(width: auto ? 0 : Self.fillWidth(knobCenter: center, width: width), height: Self.height)
                    .clipShape(Capsule())
                    .opacity(auto ? 0 : 1)
                knob.position(x: center, y: Self.height / 2)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let picked = levels[Self.index(at: value.location.x, count: levels.count, width: width)]
                if picked != effort { effort = picked }
            })
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: index)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: auto)
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(L("ask.reasoning.title"))
        .accessibilityValue(effort.nearest(in: levels).label)
        .accessibilityAdjustableAction { direction in
            let current = auto ? (levels.count - 1) / 2 : index
            switch direction {
            case .increment: effort = levels[min(levels.count - 1, auto ? current : current + 1)]
            case .decrement: effort = levels[max(0, auto ? current : current - 1)]
            @unknown default: break
            }
        }
    }

    @ViewBuilder private var knob: some View {
        if auto {
            Circle().strokeBorder(StudioTheme.textTertiary, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
                .frame(width: Self.knob, height: Self.knob)
        } else {
            Circle()
                .fill(RadialGradient(colors: [.white, Color(white: 0.94), Color(white: 0.88)],
                                     center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: Self.knob * 0.7))
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.35), radius: 3.5, y: 2)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
    }
}

/// The slider's fill: a gradient with a glossy top half, a soft band of light that
/// sweeps across, and points of light that drift right and twinkle, like light in
/// moving water. Violet at the top level. Reduced motion keeps the points still.
struct AskLiquidFill: View {
    var top: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let particleCount = 26

    /// A stable pseudo-random value in 0..<1 for particle `index`, so the layout needs no state.
    static func noise(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { canvas, size in
                draw(in: &canvas, size: size, time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = size.width, height = size.height
        guard width > 1 else { return }
        let rect = CGRect(origin: .zero, size: size)
        let colors: [Color] = top
            ? [Color(red: 0.56, green: 0.61, blue: 1.0), Color(red: 0.61, green: 0.42, blue: 1.0), Color(red: 0.54, green: 0.25, blue: 0.94)]
            : [Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.23, green: 0.51, blue: 1.0)]
        canvas.fill(Path(rect), with: .linearGradient(Gradient(colors: colors), startPoint: .zero,
                                                      endPoint: CGPoint(x: width, y: 0)))
        // A slow band of light sweeps through, like a current.
        let sweep = (time * 60).truncatingRemainder(dividingBy: Double(width) + 160) - 80
        canvas.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(0.16), .white.opacity(0)]),
            startPoint: CGPoint(x: sweep - 70, y: 0), endPoint: CGPoint(x: sweep + 70, y: 0)))
        // Drifting, twinkling points; the last stretch under the knob stays clear.
        let span = max(Double(width), 40) + 20
        for index in 0 ..< Self.particleCount {
            let speed = 8 + Self.noise(index, 1) * 16
            let left = (Self.noise(index, 2) * 340 + time * speed).truncatingRemainder(dividingBy: span) - 10
            guard left < Double(width) - AskEffortSlider.knob / 2 - 10 else { continue }
            let phase = Self.noise(index, 3) * 6.28
            let top = 5 + Self.noise(index, 4) * Double(height - 10) + sin(time * 1.3 + phase) * 1.2
            let alpha = 0.35 + 0.65 * abs(sin(time * (0.6 + Self.noise(index, 5) * 1.6) + phase))
            let radius = 0.5 + Self.noise(index, 6) * 0.8
            canvas.fill(Path(ellipseIn: CGRect(x: left - radius, y: top - radius, width: radius * 2, height: radius * 2)),
                        with: .color(.white.opacity(alpha * 0.85)))
        }
        // A glossy top half and a darker lower edge give the fill depth.
        canvas.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.26), location: 0), .init(color: .white.opacity(0.05), location: 0.48),
                             .init(color: .clear, location: 0.52), .init(color: .black.opacity(0.12), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
        canvas.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: height / 2),
                      with: .color(top ? Color(red: 0.78, green: 0.67, blue: 1).opacity(0.35)
                          : Color(red: 0.55, green: 0.71, blue: 1).opacity(0.35)), lineWidth: 1)
    }
}
