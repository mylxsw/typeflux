// swiftlint:disable file_length
import SwiftUI
import TypefluxChat

/// One composer entry opens the effort card; choosing a model returns to that card.
struct ChatModelPicker: View {
    @Bindable var store: ChatStore
    var maximumHeight: CGFloat = 420
    @State private var expanded = false

    var body: some View {
        let shown = store.reasoningEffort.nearest(in: store.supportedReasoningLevels)
        Button { expanded = true } label: {
            HStack(spacing: 5) {
                Text(store.selectedModel?.name ?? NSLocalizedString("Choose model", comment: ""))
                    .lineLimit(1).truncationMode(.middle)
                if shown != .providerDefault {
                    Text(shown.label)
                        .foregroundStyle(shown.isTop(in: store.supportedReasoningLevels)
                            ? ChatTheme.purple : ChatTheme.secondary)
                        .lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChatTheme.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy || store.models.isEmpty)
        .accessibilityLabel(NSLocalizedString("Model and reasoning", comment: ""))
        .accessibilityValue([store.selectedModel?.name, shown == .providerDefault ? nil : shown.label]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("modelPicker")
        .popover(isPresented: $expanded, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            ChatModelEffortCard(store: store, maximumHeight: maximumHeight)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(ChatTheme.popover)
        }
        .onChange(of: store.isBusy) { _, busy in
            if busy {
                expanded = false
            }
        }
    }
}

struct ChatModelEffortCard: View {
    enum Page { case effort, models }
    @Bindable var store: ChatStore
    var maximumHeight: CGFloat
    @State private var page: Page = .effort
    @State private var selectionNotice: String?

    static let width: CGFloat = 272
    static let modelsWidth: CGFloat = 330

    init(store: ChatStore, page: Page = .effort, maximumHeight: CGFloat = 420) {
        self.store = store
        self.maximumHeight = maximumHeight
        _page = State(initialValue: page)
    }

    private var shown: ChatReasoningEffort {
        store.reasoningEffort.nearest(in: store.supportedReasoningLevels)
    }

    var body: some View {
        ChatPopoverContent(maximumHeight: maximumHeight) {
            pageContent
        }
        // The ideal widths match the Mac; the model list can contract on small phones.
        .frame(minWidth: Self.width,
               idealWidth: page == .models ? Self.modelsWidth : Self.width,
               maxWidth: page == .models ? Self.modelsWidth : Self.width)
        .background(ChatTheme.popover)
        .disabled(store.isBusy)
    }

    @ViewBuilder private var pageContent: some View {
        if page == .models {
            modelsPage
        } else {
            effortPage
        }
    }

    private var effortPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 44, height: 44)
                VStack(spacing: 1) {
                    Text(store.supportedReasoningLevels.isEmpty
                        ? store.selectedModel?.name ?? NSLocalizedString("Choose model", comment: "")
                        : shown.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(effortColor)
                        .lineLimit(2)
                        .accessibilityIdentifier("reasoningTitle")
                    Button { page = .models } label: {
                        HStack(spacing: 3) {
                            Text(store.supportedReasoningLevels.isEmpty
                                ? NSLocalizedString("Change model", comment: "")
                                : store.selectedModel?.name ?? NSLocalizedString("Choose model", comment: ""))
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.caption)
                        .foregroundStyle(ChatTheme.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("Change model", comment: ""))
                    .accessibilityValue(store.selectedModel?.name ?? "")
                    .accessibilityIdentifier("changeModel")
                }
                .frame(maxWidth: .infinity)
                Button {
                    store.selectReasoningEffort(.providerDefault)
                    selectionNotice = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ChatTheme.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.supportedReasoningLevels.isEmpty || shown == .providerDefault)
                .opacity(store.supportedReasoningLevels.isEmpty || shown == .providerDefault ? 0.3 : 1)
                .accessibilityLabel(NSLocalizedString("Back to Auto", comment: ""))
                .accessibilityIdentifier("resetReasoning")
            }
            if store.supportedReasoningLevels.isEmpty {
                Text(NSLocalizedString(
                    "This model does not offer reasoning levels and answers in its own way.",
                    comment: ""
                ))
                .font(.caption)
                .foregroundStyle(ChatTheme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ChatEffortSlider(levels: store.supportedReasoningLevels, effort: Binding(
                    get: { store.reasoningEffort },
                    set: { store.selectReasoningEffort($0); selectionNotice = nil }
                ))
                Text(shown.caption)
                    .font(.caption)
                    .foregroundStyle(ChatTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            if let selectionNotice {
                Text(selectionNotice)
                    .font(.caption2)
                    .foregroundStyle(ChatTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("reasoningAdjustment")
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 16)
    }

    private var effortColor: Color {
        if store.supportedReasoningLevels.isEmpty || shown == .providerDefault {
            return .primary
        }
        return shown.isTop(in: store.supportedReasoningLevels) ? ChatTheme.purple : ChatTheme.accentText
    }

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { page = .effort } label: {
                Label(NSLocalizedString("Reasoning effort", comment: ""), systemImage: "chevron.left")
                    .font(.subheadline)
                    .foregroundStyle(ChatTheme.secondary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backToReasoning")
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Typeflux Cloud")
                    Spacer()
                    Text(NSLocalizedString("Credits", comment: ""))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(ChatTheme.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                if store.hasConversationImages, store.models.contains(where: { $0.vision != true }) {
                    Label(NSLocalizedString("This conversation needs a model that supports photos.", comment: ""),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(ChatTheme.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
                ForEach(store.models) { model in
                    modelRow(model)
                }
            }
            .padding(.bottom, 6)
            Rectangle().fill(ChatTheme.separator).frame(height: 0.5)
            Text(NSLocalizedString("Models and pricing are provided by Typeflux Cloud.", comment: ""))
                .font(.caption2)
                .foregroundStyle(ChatTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }

    private func modelRow(_ model: ChatModel) -> some View {
        let selected = model.reference == store.modelRef
        let blocked = store.hasConversationImages && model.vision != true
        return Button {
            let previous = shown
            guard store.selectModel(model) else { return }
            selectionNotice = previous != shown && previous != .providerDefault
                ? String(format: NSLocalizedString("This model does not offer “%@”; using “%@”", comment: ""),
                         previous.label, shown.label) : nil
            page = .effort
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChatTheme.accentText)
                    .frame(width: 14).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(blocked ? ChatTheme.secondary : Color.primary)
                        .lineLimit(2)
                    if blocked {
                        Text(NSLocalizedString("Does not support photos", comment: ""))
                            .font(.caption2).foregroundStyle(ChatTheme.secondary)
                    } else if let capacity = ChatModelPickerDisplay.capacity(model) {
                        Text(capacity).font(.caption2).foregroundStyle(ChatTheme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.vision == true {
                    Text(NSLocalizedString("Vision", comment: ""))
                        .font(.system(size: 10))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(ChatTheme.secondary, lineWidth: 0.5))
                        .foregroundStyle(ChatTheme.secondary)
                }
                if let multiplier = ChatModelPickerDisplay.multiplier(model) {
                    Text(multiplier).font(.caption).monospacedDigit()
                        .foregroundStyle(ChatTheme.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChatModelRowStyle())
        .disabled(blocked || store.isBusy)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("model-" + model.id)
    }
}

/// Keep an unavailable model's explanation readable. PlainButtonStyle dims the
/// entire disabled label even when its text already uses a secondary foreground.
struct ChatModelRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed && isEnabled ? ChatTheme.raised : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Short cards keep their natural height. In a small window or above the keyboard,
/// the complete page scrolls so its final row and footer remain reachable.
struct ChatPopoverContent<Content: View>: View {
    var maximumHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView {
                content.fixedSize(horizontal: false, vertical: true)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("modelCardScroll")
        }
        .frame(maxHeight: max(44, maximumHeight))
    }
}

extension ChatReasoningEffort {
    var label: String {
        let key = switch self {
        case .providerDefault: "Auto"
        case .low: "Light"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Ultra"
        }
        return NSLocalizedString(key, comment: "Reasoning effort")
    }

    var caption: String {
        let key = switch self {
        case .providerDefault: "The model decides how much to think"
        case .low: "Fastest, for simple questions"
        case .medium: "Balances speed and depth"
        case .high: "Thinks more, for complex questions"
        case .xhigh: "Deep reasoning, slower and uses more credits"
        case .max: "The deepest reasoning, slowest and uses the most credits"
        }
        return NSLocalizedString(key, comment: "Reasoning effort description")
    }
}

enum ChatModelPickerDisplay {
    static func multiplier(_ model: ChatModel) -> String? {
        guard let raw = model.pricing?["multiplier"],
              raw.range(of: #"^[0-9]+(?:\.[0-9]{1,4})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              value > 0, value <= 100 else { return nil }
        return NSDecimalNumber(decimal: value).stringValue + "×"
    }

    static func capacity(_ model: ChatModel) -> String? {
        guard let context = model.contextWindowTokens, let output = model.maxOutputTokens,
              context > 0, output > 0 else { return nil }
        return String(format: NSLocalizedString("%@ context · %@ output", comment: "Model capacity"),
                      count(context), count(output))
    }

    static func count(_ value: Int) -> String {
        if value >= 1_000_000 {
            return (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(0 ... 1))) + "M"
        }
        if value >= 1000 {
            return (Double(value) / 1000).formatted(.number.precision(.fractionLength(0 ... 1))) + "K"
        }
        return value.formatted()
    }
}

/// A 26-point Mac track inside a 44-point touch target. Auto is not a real stop.
struct ChatEffortSlider: View {
    let levels: [ChatReasoningEffort]
    @Binding var effort: ChatReasoningEffort
    var reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    static let height: CGFloat = 26
    static let knobSize: CGFloat = 20
    static let inset: CGFloat = 3
    static let touchHeight: CGFloat = 44

    static func knobCenter(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let edge = inset + knobSize / 2
        guard count > 1, width > 2 * edge else { return width / 2 }
        return edge + CGFloat(min(max(index, 0), count - 1)) * (width - 2 * edge) / CGFloat(count - 1)
    }

    static func fillWidth(knobCenter: CGFloat, width: CGFloat) -> CGFloat {
        min(width, knobCenter + knobSize / 2 + inset)
    }

    static func index(at position: CGFloat, count: Int, width: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        return (0 ..< count).min {
            abs(knobCenter(index: $0, count: count, width: width) - position)
                < abs(knobCenter(index: $1, count: count, width: width) - position)
        } ?? 0
    }

    static func adjusted(_ effort: ChatReasoningEffort, levels: [ChatReasoningEffort],
                         increase: Bool) -> ChatReasoningEffort {
        guard !levels.isEmpty else { return .providerDefault }
        let middle = (levels.count - 1) / 2
        if effort == .providerDefault {
            return levels[middle]
        }
        let current = levels.firstIndex(of: effort.nearest(in: levels)) ?? 0
        return levels[min(max(current + (increase ? 1 : -1), 0), levels.count - 1)]
    }

    private var auto: Bool {
        effort == .providerDefault
    }

    private var index: Int {
        auto ? max(0, (levels.count - 1) / 2) : levels.firstIndex(of: effort.nearest(in: levels)) ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let center = Self.knobCenter(index: index, count: levels.count, width: width)
            ZStack(alignment: .leading) {
                Capsule().fill(ChatTheme.controlSurface)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                ForEach(levels.indices, id: \.self) { stop in
                    Circle().fill(ChatTheme.tertiary)
                        .frame(width: 4, height: 4)
                        .position(
                            x: Self.knobCenter(index: stop, count: levels.count, width: width),
                            y: Self.height / 2
                        )
                        .opacity(!auto && stop <= index ? 0 : 1)
                }
                ChatLiquidFill(top: effort.nearest(in: levels).isTop(in: levels), reduceMotionOverride: reduceMotion)
                    .frame(width: auto ? 0 : Self.fillWidth(knobCenter: center, width: width), height: Self.height)
                    .clipShape(Capsule()).opacity(auto ? 0 : 1)
                knob.position(x: center, y: Self.height / 2)
            }
            .frame(height: Self.height)
            .frame(height: Self.touchHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !levels.isEmpty else { return }
                effort = levels[Self.index(at: value.location.x, count: levels.count, width: width)]
            })
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: index)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: auto)
        }
        .frame(height: Self.touchHeight)
        .accessibilityElement()
        .accessibilityLabel(NSLocalizedString("Reasoning effort", comment: ""))
        .accessibilityValue(effort.nearest(in: levels).label)
        .accessibilityIdentifier("reasoningSlider")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: effort = Self.adjusted(effort, levels: levels, increase: true)
            case .decrement: effort = Self.adjusted(effort, levels: levels, increase: false)
            @unknown default: break
            }
        }
    }

    @ViewBuilder private var knob: some View {
        if auto {
            Circle().strokeBorder(ChatTheme.secondary, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
                .frame(width: Self.knobSize, height: Self.knobSize)
        } else {
            Circle().fill(RadialGradient(colors: [.white, Color(white: 0.94), Color(white: 0.88)],
                                         center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0,
                                         endRadius: Self.knobSize * 0.7))
                .frame(width: Self.knobSize, height: Self.knobSize)
                .shadow(color: .black.opacity(0.35), radius: 3.5, y: 2)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
    }
}

struct ChatLiquidFill: View {
    var top: Bool
    var reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    static let particleCount = 26

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

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
            ? [
                Color(red: 0.56, green: 0.61, blue: 1),
                Color(red: 0.61, green: 0.42, blue: 1),
                Color(red: 0.54, green: 0.25, blue: 0.94)
            ]
            : [Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.23, green: 0.51, blue: 1)]
        canvas.fill(Path(rect), with: .linearGradient(Gradient(colors: colors), startPoint: .zero,
                                                      endPoint: CGPoint(x: width, y: 0)))
        let sweep = (time * 60).truncatingRemainder(dividingBy: Double(width) + 160) - 80
        canvas.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(0.16), .white.opacity(0)]),
            startPoint: CGPoint(x: sweep - 70, y: 0), endPoint: CGPoint(x: sweep + 70, y: 0)
        ))
        let span = max(Double(width), 40) + 20
        for index in 0 ..< Self.particleCount {
            let speed = 8 + Self.noise(index, 1) * 16
            let left = (Self.noise(index, 2) * 340 + time * speed).truncatingRemainder(dividingBy: span) - 10
            guard left < Double(width) - ChatEffortSlider.knobSize / 2 - 10 else { continue }
            let phase = Self.noise(index, 3) * 6.28
            let top = 5 + Self.noise(index, 4) * Double(height - 10) + sin(time * 1.3 + phase) * 1.2
            let alpha = 0.35 + 0.65 * abs(sin(time * (0.6 + Self.noise(index, 5) * 1.6) + phase))
            let radius = 0.5 + Self.noise(index, 6) * 0.8
            canvas.fill(
                Path(ellipseIn: CGRect(x: left - radius, y: top - radius, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(alpha * 0.85))
            )
        }
        canvas.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.26), location: 0),
                .init(color: .white.opacity(0.05), location: 0.48),
                .init(color: .clear, location: 0.52),
                .init(color: .black.opacity(0.12), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: height)
        ))
        canvas.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: height / 2),
                      with: .color(top ? Color(red: 0.78, green: 0.67, blue: 1).opacity(0.35)
                          : Color(red: 0.55, green: 0.71, blue: 1).opacity(0.35)), lineWidth: 1)
    }
}
