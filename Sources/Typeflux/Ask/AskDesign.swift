// swiftlint:disable file_length
import AppKit
import SwiftUI

/// Design tokens for the Ask surfaces.
///
/// The workspace is a standalone window placed directly over the desktop, so its
/// backplates are opaque. The launcher card is the one exception: it is glass
/// (`AskGlassBackground`), and falls back to `composerSurface` when the user
/// turns on Reduce Transparency.
enum AskTheme {
    static let accent = StudioTheme.accent

    // Neutral greys chosen to match the settings window (`StudioTheme.shellSurface`
    // and `sidebar` composited over their material); opaque on purpose.
    static let surface = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0.985, alpha: 1),
        dark: NSColor(calibratedWhite: 0.122, alpha: 1)
    )
    /// One step above `surface`: composer footer, tool cards, inline banners.
    static let raisedSurface = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0.965, alpha: 1),
        dark: NSColor(calibratedWhite: 0.150, alpha: 1)
    )
    static let sidebarSurface = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0.940, alpha: 1),
        dark: NSColor(calibratedWhite: 0.075, alpha: 1)
    )
    static let controlSurface = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0.925, alpha: 1),
        dark: NSColor(calibratedWhite: 0.180, alpha: 1)
    )
    static let bubbleSurface = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0.930, alpha: 1),
        dark: NSColor(calibratedWhite: 0.165, alpha: 1)
    )
    static let border = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.886, green: 0.898, blue: 0.918, alpha: 1),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10)
    )
    static let separator = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.910, green: 0.922, blue: 0.937, alpha: 1),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )
    static let accentSoft = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.906, green: 0.937, blue: 1.0, alpha: 1),
        dark: NSColor(calibratedRed: 0.082, green: 0.149, blue: 0.243, alpha: 1)
    )
    static let accentText = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.106, green: 0.341, blue: 0.839, alpha: 1),
        dark: NSColor(calibratedRed: 0.557, green: 0.741, blue: 1.0, alpha: 1)
    )
    static let successSoft = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.894, green: 0.965, blue: 0.929, alpha: 1),
        dark: NSColor(calibratedRed: 0.071, green: 0.161, blue: 0.114, alpha: 1)
    )
    static let warningSoft = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.984, green: 0.941, blue: 0.882, alpha: 1),
        dark: NSColor(calibratedRed: 0.165, green: 0.125, blue: 0.082, alpha: 1)
    )
    static let dangerSoft = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.984, green: 0.918, blue: 0.918, alpha: 1),
        dark: NSColor(calibratedRed: 0.173, green: 0.094, blue: 0.094, alpha: 1)
    )
    // Design-board values are specified in sRGB. `calibratedWhite` uses the
    // gamma 1.8 generic grey space, so 0.18 there renders as #3D3D3D, not #2E2E2E.

    /// The workspace composer card and empty-state cards: one step lighter than
    /// the transcript canvas in dark, plain white in light.
    static let composerSurface = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.180, blue: 0.180, alpha: 1)
    )
    /// Popovers opened from the composer (model and reasoning choosers).
    static let popoverSurface = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1)
    )
    /// Cards inside the usage panel, one step above the panel itself.
    static let panelCard = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.239, green: 0.239, blue: 0.239, alpha: 1)
    )
    /// Recessed track behind the usage panel's segmented control.
    static let segmentTrack = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0.918, green: 0.922, blue: 0.933, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.180, blue: 0.180, alpha: 1)
    )
    /// The design board's primary blue (#1D81DD dark / #1670C8 light), used for
    /// the sidebar's primary action. `accent` stays the app-wide control tint.
    static let primaryAction = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0.086, green: 0.439, blue: 0.784, alpha: 1),
        dark: NSColor(srgbRed: 0.114, green: 0.506, blue: 0.867, alpha: 1)
    )
    /// The launcher's idle edge. It floats over arbitrary windows, so it needs a
    /// firmer outline than the workspace composer's `border` to read as a panel.
    static let floatingBorder = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.12),
        dark: NSColor(calibratedWhite: 1, alpha: 0.18)
    )
    /// Translucent hover wash, so borderless controls read the same on any surface.
    static let hoverFill = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    /// The product's indigo mark (the original assistant avatar), used only for
    /// brand moments: the empty state and the account badge. Never for state.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.455, green: 0.467, blue: 0.984), Color(red: 0.608, green: 0.545, blue: 0.984)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
    static let monoSurface = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.957, green: 0.965, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.063, green: 0.071, blue: 0.086, alpha: 1)
    )

    static func toolTitle(_ call: AskToolCall) -> String {
        let name = call.function.name
        guard name == "computer" || name == "browser" else { return name }
        let action = (try? AskLocalTools.arguments(call.function.arguments)["action"] as? String) ?? ""
        let title = L("ask.tool." + name)
        return action.isEmpty ? title : title + " · " + L("ask.action." + action)
    }
}

/// Fixed metrics shared by the launcher panel and the workspace. The native
/// window geometry depends on them, so they live next to the views that use them.
enum AskMetrics {
    static let launcherWidth: CGFloat = 680
    /// Breathing room around the launcher card.
    static let launcherGutter: CGFloat = 6
    /// The launcher's glass card: 26 = footer inset 10 + the 32pt send button's radius 16,
    /// so the corner stays concentric with the controls in it.
    static let launcherCardCorner: CGFloat = 26
    /// Height of every footer control: menus, context chips, microphone and send.
    static let composerControlHeight: CGFloat = 32
    /// Horizontal padding inside the footer's text menus (model, reasoning).
    static let composerControlPadding: CGFloat = 10
    static let bannerHeight: CGFloat = 32
    static let bannerSpacing: CGFloat = 6
    static let sidebarWidth: CGFloat = 248
    static let headerHeight: CGFloat = 52
    /// Height of the title bar row; the unified toolbar centres the traffic lights in it.
    static let titleBarRowHeight: CGFloat = 52
    /// Space above the sidebar's first row, clearing the title bar tools.
    static let sidebarTopInset: CGFloat = 52
    /// Vertical strip reserved for the window's traffic-light buttons.
    static let trafficLightStrip: CGFloat = 32
    /// Leading space for the title bar tools, past the traffic lights.
    static let trafficLightInset: CGFloat = 78
    /// Header title inset when the sidebar is collapsed: clears the floating toggle.
    static let collapsedTitleInset: CGFloat = 156
    /// One centred reading column shared by the transcript and the composer, so
    /// questions, answers and the input line up instead of spanning the window.
    static let columnWidth: CGFloat = 720
    static let columnInset: CGFloat = 24
    static let composerMaxWidth: CGFloat = columnWidth
    static let transcriptMaxWidth: CGFloat = columnWidth - columnInset * 2
    static let bubbleMaxWidth: CGFloat = 540
    static let composerCardCorner: CGFloat = 16
    /// Widest the composer's model name may grow before it truncates in the middle.
    static let modelMenuMaxWidth: CGFloat = 132
    /// The saved-screenshot card above the composer and its thumbnail.
    static let recoveryCardCorner: CGFloat = 12
    static let recoveryThumbnail = CGSize(width: 54, height: 36)

    /// Height of the launcher panel, including its transparent gutter.
    static func launcherHeight(editor: CGFloat, banners: Int) -> CGFloat {
        let chrome = AskComposerChrome.launcher
        return editor + chrome.editorTopInset + chrome.editorBottomInset + chrome.footerHeight + launcherGutter * 2
            + CGFloat(banners) * (bannerHeight + bannerSpacing)
    }
}

/// Surface of the shared composer. The launcher and the workspace are the same
/// feature behind different triggers: they share every control and state. The
/// launcher floats over other apps, so it is a larger glass card with roomier
/// insets; the workspace keeps its opaque card inside the conversation window.
struct AskComposerChrome: Equatable {
    var fill: Color
    var corner: CGFloat
    var editorFontSize: CGFloat
    var horizontalInset: CGFloat
    var idleBorder: Color
    /// Draws the card with `AskGlassBackground` instead of `fill`.
    var glass = false
    var editorTopInset: CGFloat = 15
    var editorBottomInset: CGFloat = 11
    var footerHeight: CGFloat = 44
    var footerLeadingInset: CGFloat = 12

    static let workspace = AskComposerChrome(
        fill: AskTheme.composerSurface,
        corner: AskMetrics.composerCardCorner,
        editorFontSize: 14,
        horizontalInset: 15,
        idleBorder: AskTheme.border
    )

    /// The editor text starts where the model name does: footer inset 10 plus the
    /// menu's own 10pt padding, less the text view's 5pt line fragment padding.
    static let launcher = AskComposerChrome(
        fill: AskTheme.composerSurface,
        corner: AskMetrics.launcherCardCorner,
        editorFontSize: 15,
        horizontalInset: 15,
        idleBorder: AskTheme.floatingBorder,
        glass: true,
        editorTopInset: 14,
        editorBottomInset: 2,
        footerHeight: 52,
        footerLeadingInset: 10
    )

    static func of(launcher: Bool) -> AskComposerChrome { launcher ? .launcher : .workspace }
}

/// Colour is reserved for state: blue runs, green finished, amber needs a
/// decision, red failed. Everything else stays neutral grey.
enum AskActivityState {
    case running, done, attention, failed

    var tint: Color {
        switch self {
        case .running: return AskTheme.accentText
        case .done: return StudioTheme.success
        case .attention: return StudioTheme.warning
        case .failed: return StudioTheme.danger
        }
    }

    var softFill: Color {
        switch self {
        case .running: return AskTheme.accentSoft
        case .done: return AskTheme.successSoft
        case .attention: return AskTheme.warningSoft
        case .failed: return AskTheme.dangerSoft
        }
    }

    var needsAttention: Bool { self == .attention || self == .failed }
}

/// Every switch, attachment and source label in the composer is a capsule.
/// Native check boxes and bare text links are intentionally not used here.
struct AskChip: View {
    /// `unavailable` is a solid, muted chip whose tooltip gives the reason. A
    /// dashed outline used to read as a broken control.
    enum Style { case neutral, active, warning, unavailable }

    var title: String
    var systemImage: String
    var style: Style = .neutral
    var action: (() -> Void)?
    var onRemove: (() -> Void)?
    var help: String?
    var disabled = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
            Text(title).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("ask.remove"))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(stroke))
        .contentShape(Capsule())
        .onTapGesture { if !disabled { action?() } }
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .opacity(disabled && style != .unavailable ? 0.55 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(disabled ? L("ask.image.disabled") : "")
        .accessibilityHint(help ?? title)
        .help(help ?? title)
    }

    private var foreground: Color {
        switch style {
        case .neutral: return StudioTheme.textSecondary
        case .active: return AskTheme.accentText
        case .warning: return StudioTheme.warning
        case .unavailable: return StudioTheme.textTertiary
        }
    }

    private var fill: Color {
        switch style {
        case .active: return AskTheme.accentSoft
        case .warning: return AskTheme.warningSoft
        default: return .clear
        }
    }

    private var stroke: Color {
        switch style {
        case .active, .warning: return .clear
        default: return AskTheme.border
        }
    }
}

struct AskStatusBadge: View {
    var text: String
    var state: AskActivityState

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(state.tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(state.softFill, in: Capsule())
    }
}

/// A tool call is one collapsed 40pt row. It only expands when the user asks
/// for it, or when the run is waiting for a decision.
struct AskToolCard<Detail: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    var state: AskActivityState
    var statusText: String
    var detail: () -> Detail
    @State private var expanded: Bool

    init(title: String, subtitle: String? = nil, systemImage: String, state: AskActivityState,
         statusText: String, startsExpanded: Bool = false,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.state = state
        self.statusText = statusText
        self.detail = detail
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(StudioTheme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    AskStatusBadge(text: statusText, state: state)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                .padding(.horizontal, 11)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                detail()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AskTheme.surface)
            }
        }
        .background(AskTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(state.needsAttention ? state.tint.opacity(0.45) : AskTheme.border)
        )
    }
}

/// Monospaced block used for tool arguments and results.
struct AskMonoBlock: View {
    var title: String
    var text: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(isError ? StudioTheme.danger : StudioTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskTheme.separator))
        }
    }
}

/// Disconnects, voice failures and confirmations all use the same bar so they
/// never interrupt the transcript with red body text.
struct AskBanner: View {
    enum Tone { case info, warning, danger }

    var text: String
    var tone: Tone = .info
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage ?? defaultSymbol).font(.system(size: 12, weight: .medium))
            Text(text).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(AskTheme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("ask.remove"))
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .frame(minHeight: AskMetrics.bannerHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var defaultSymbol: String {
        switch tone {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .danger: return "exclamationmark.octagon"
        }
    }

    private var foreground: Color {
        switch tone {
        case .info: return StudioTheme.textSecondary
        case .warning: return StudioTheme.warning
        case .danger: return StudioTheme.danger
        }
    }

    private var fill: Color {
        switch tone {
        case .info: return AskTheme.raisedSurface
        case .warning: return AskTheme.warningSoft
        case .danger: return AskTheme.dangerSoft
        }
    }
}

/// Capsule buttons for Ask's own cards and sheets, in place of the stock
/// bordered buttons: `primary` fills with the design blue, `secondary` is a
/// quiet outline. Both dim when disabled.
struct AskCapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        CapsuleLabel(configuration: configuration, kind: kind)
    }

    /// Not named `Body`: that would shadow the protocol's associated type.
    /// A separate view is needed to read `isEnabled` from the environment.
    struct CapsuleLabel: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(kind == .primary ? Color.white : StudioTheme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(kind == .primary ? AskTheme.primaryAction : AskTheme.hoverFill, in: Capsule())
                .overlay(Capsule().strokeBorder(kind == .primary ? Color.clear : AskTheme.border))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .fixedSize()
        }
    }
}

struct AskSendButton: View {
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : StudioTheme.textTertiary)
        // The only solid control in the composer: a lit accent drop when it can send,
        // a faint translucent well otherwise, so it sits on glass and opaque cards alike.
        .background(Circle().fill(enabled ? AskTheme.accent : AskTheme.hoverFill))
        .overlay {
            if enabled {
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.32), .clear],
                                             center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: 22))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: enabled ? AskTheme.accent.opacity(0.35) : .clear, radius: 5, y: 2)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.15), value: enabled)
        .accessibilityLabel(L("ask.send"))
    }
}

struct AskKeyCap: View {
    var symbol: String?
    var text: String?

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            else { Text(text ?? "").font(.system(size: 10, weight: .semibold)) }
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .frame(minWidth: 18, minHeight: 18)
        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// One piece of a shortcut sentence: plain words, or a key drawn as a key.
enum AskHintSegment: Equatable {
    case text(String)
    case key(String)
}

/// "Press [⌘ Space] anytime to summon · Hold [Fn] to dictate" under the empty
/// state. Both keys come from the configured shortcuts and follow changes to
/// them; the sentence used to say "double-press Fn" whatever was configured.
struct AskShortcutHint: View {
    let settings: SettingsStore
    @State private var clauses: [[AskHintSegment]] = []

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(clauses.enumerated()), id: \.offset) { index, clause in
                if index > 0 { Text(verbatim: "·") }
                ForEach(Array(clause.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case let .text(value): Text(value)
                    case let .key(value): keyCap(value)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(StudioTheme.textTertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AskPresentation.spokenHint(clauses))
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .hotkeySettingsDidChange)) { _ in refresh() }
    }

    private func refresh() {
        clauses = AskPresentation.shortcutHint(summon: settings.askHotkey, voice: settings.activationHotkey)
    }

    private func keyCap(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(AskTheme.border))
    }
}

/// Level meter shown only while the recorder is listening.
struct AskWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let barCount = 11

    var body: some View {
        if reduceMotion {
            bars(phase: 0)
        } else {
            TimelineView(.periodic(from: Date(), by: 0.12)) { context in
                bars(phase: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func bars(phase: Double) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(AskTheme.accent)
                    .frame(width: 2.5, height: Self.height(index: index, phase: phase))
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    static func height(index: Int, phase: Double) -> CGFloat {
        let value = sin(Double(index) * 0.9 + phase * 6)
        return 4 + CGFloat(abs(value)) * 10
    }
}

/// A user bubble: rounded everywhere except the corner that points at its
/// sender. `UnevenRoundedRectangle` needs macOS 14, the app supports 13.
struct AskBubbleShape: InsettableShape {
    var radius: CGFloat = 16
    var tail: CGFloat = 5
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let big = min(radius, box.width / 2, box.height / 2)
        let small = min(tail, big)
        var path = Path()
        path.move(to: CGPoint(x: box.minX + big, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - big, y: box.minY))
        path.addArc(center: CGPoint(x: box.maxX - big, y: box.minY + big), radius: big,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - small))
        path.addArc(center: CGPoint(x: box.maxX - small, y: box.maxY - small), radius: small,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: box.minX + big, y: box.maxY))
        path.addArc(center: CGPoint(x: box.minX + big, y: box.maxY - big), radius: big,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + big))
        path.addArc(center: CGPoint(x: box.minX + big, y: box.minY + big), radius: big,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> AskBubbleShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// The indigo sparkle tile shown above the empty state.
struct AskBrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(AskTheme.brandGradient,
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: Color(red: 0.455, green: 0.467, blue: 0.984).opacity(0.28), radius: 12, y: 6)
            .accessibilityHidden(true)
    }
}

/// The account badge in the sidebar footer: the name's first letter on the mark.
struct AskAccountBadge: View {
    var name: String

    var body: some View {
        Text(verbatim: name.first.map { String($0).uppercased() } ?? "·")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 24, height: 24)
            .background(AskTheme.brandGradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Borderless action used by the transcript's per-turn toolbar. It only paints
/// a background under the pointer, so a row of them reads as one quiet strip
/// instead of three competing buttons.
struct AskGhostButton: View {
    var title: String
    var systemImage: String
    var active = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10.5))
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(hovering ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        if active { return StudioTheme.success }
        return hovering ? StudioTheme.textPrimary : StudioTheme.textTertiary
    }
}

/// The four things a selected excerpt can become. Replaces a modal that asked
/// for an optional question before anything could happen.
enum AskSelectionAction: String, CaseIterable {
    case explain, translate, ask, copy

    var title: String {
        switch self {
        case .explain: return L("ask.selection.explain")
        case .translate: return L("ask.selection.translate")
        case .ask: return L("ask.selection.ask")
        case .copy: return L("ask.copy")
        }
    }

    var systemImage: String {
        switch self {
        case .explain: return "info.circle"
        case .translate: return "character.book.closed"
        case .ask: return "text.bubble"
        case .copy: return "doc.on.doc"
        }
    }

    /// The question carried into the draft. `ask` leaves it to the user, and
    /// `copy` never reaches the composer.
    var question: String {
        switch self {
        case .explain: return L("ask.references.explain")
        case .translate: return L("ask.references.translate")
        case .ask, .copy: return ""
        }
    }
}

/// The bar that floats over a selection inside an answer. Copy is separated by
/// a rule because it is the only action that does not reach the composer.
struct AskSelectionActionBar: View {
    var perform: (AskSelectionAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AskSelectionAction.allCases, id: \.rawValue) { action in
                if action == .copy {
                    Rectangle().fill(AskTheme.separator)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 3)
                }
                AskSelectionActionButton(action: action) { perform(action) }
            }
        }
        .padding(4)
        // Never let the popover compress a label into an ellipsis.
        .fixedSize()
        .tint(AskTheme.accent)
    }
}

private struct AskSelectionActionButton: View {
    var action: AskSelectionAction
    var perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: action.systemImage).font(.system(size: 11))
                Text(action.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(hovering ? AskTheme.accentText : StudioTheme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(hovering ? AskTheme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(action.title)
    }
}

/// A subtle recording outline complements the fixed voice control.
/// Focus and transcription keep the neutral border.
struct AskVoiceBorder: ViewModifier {
    @ObservedObject var voice: AskVoiceInput
    var context: String
    var radius: CGFloat
    var idle: Color = AskTheme.border
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listening: Bool { voice.context == context && voice.phase == .listening }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .overlay(
                ZStack {
                    shape.strokeBorder(Self.borderColor(listening: listening, idle: idle),
                                       lineWidth: Self.borderWidth(listening: listening))
                    // A highlight travels around the accent edge while the microphone is open.
                    if listening, !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                            let angle = Self.sheenAngle(at: context.date.timeIntervalSinceReferenceDate)
                            shape.strokeBorder(
                                AngularGradient(colors: [.clear, Color.white.opacity(0.75), .clear, .clear],
                                                center: .center, angle: .degrees(angle)),
                                lineWidth: Self.borderWidth(listening: true)
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            )
            // A soft halo outside the card while recording. Only a ring is drawn,
            // so a translucent glass card is not tinted by it.
            .background(
                RoundedRectangle(cornerRadius: radius + Self.haloWidth, style: .continuous)
                    .strokeBorder(AskTheme.accent.opacity(listening ? 0.22 : 0), lineWidth: Self.haloWidth)
                    .padding(-Self.haloWidth)
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.18), value: listening)
    }

    static let haloWidth: CGFloat = 3
    /// One lap of the recording highlight.
    static let sheenPeriod: Double = 3

    static func sheenAngle(at time: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: sheenPeriod) / sheenPeriod * 360
    }

    /// Focus alone stays neutral: the accent colour has to keep meaning "recording".
    static func borderColor(listening: Bool, idle: Color = AskTheme.border) -> Color {
        if listening { return AskTheme.accent }
        return idle
    }

    static func borderWidth(listening: Bool) -> CGFloat { listening ? 1.5 : 1 }
}

/// Pure helpers behind the redesigned surfaces, kept separate so they can be
/// unit tested without rendering a window.
enum AskPresentation {
    /// Name shown in the sidebar footer: the profile name, else the email's local part.
    static func accountName(name: String?, email: String?) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard let local = email?.split(separator: "@", omittingEmptySubsequences: false).first, !local.isEmpty else { return nil }
        return String(local)
    }

    static func filterHistory(_ items: [AskConversationSummary], query: String) -> [AskConversationSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static func toolState(result: AskMessage?) -> AskActivityState {
        guard let result else { return .running }
        return result.isError == true ? .failed : .done
    }

    static func toolStatusText(result: AskMessage?) -> String {
        switch toolState(result: result) {
        case .running: return L("ask.tool.running")
        case .failed: return L("ask.tool.failed")
        default: return L(result?.image == nil ? "ask.tool.done" : "ask.image.captured")
        }
    }

    static func toolSymbol(_ call: AskToolCall) -> String {
        switch call.function.name {
        case "computer": return "desktopcomputer"
        case "browser": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    /// Clauses for the empty-state shortcut hint. Each sentence is split around
    /// its key so every language can place the key where its grammar wants it.
    /// An unset summon shortcut drops that clause; an unset voice shortcut falls
    /// back to the microphone button, which works without one.
    static func shortcutHint(summon: HotkeyBinding?, voice: HotkeyBinding?) -> [[AskHintSegment]] {
        func clause(_ prefix: String, _ binding: HotkeyBinding) -> [AskHintSegment] {
            var segments: [AskHintSegment] = []
            let before = L(prefix + ".before")
            if !before.isEmpty { segments.append(.text(before)) }
            segments.append(.key(HotkeyFormat.display(binding)))
            let after = L(prefix + ".after")
            if !after.isEmpty { segments.append(.text(after)) }
            return segments
        }
        var clauses: [[AskHintSegment]] = []
        if let summon { clauses.append(clause("ask.empty.summon", summon)) }
        if let voice {
            clauses.append(clause("ask.empty.voice", voice))
        } else {
            clauses.append([.text(L("ask.empty.voice.button"))])
        }
        return clauses
    }

    /// The same hint as one sentence for VoiceOver.
    static func spokenHint(_ clauses: [[AskHintSegment]]) -> String {
        clauses.map { clause in
            clause.map { segment -> String in
                switch segment {
                case let .text(value), let .key(value): return value
                }
            }.joined(separator: " ")
        }.joined(separator: " · ")
    }

    /// Quoting appends to the current draft instead of replacing it, so an
    /// unfinished follow-up is never lost.
    static func quote(existing: String, quoting text: String, limit: Int = 6) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var quoted = lines.prefix(limit).map { "> " + $0 }.joined(separator: "\n")
        if lines.count > limit { quoted += "\n> …" }
        let prefix = existing.isEmpty ? "" : existing.trimmingCharacters(in: .newlines) + "\n\n"
        return prefix + quoted + "\n\n"
    }
}

/// The conversation window's sidebar and content fills. They reuse the settings
/// window's tokens and material stack, so both windows read as one app.
struct AskWindowBackdrop: View {
    enum Role { case sidebar, content }
    @Environment(\.colorScheme) private var colorScheme
    let role: Role

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            switch role {
            case .sidebar:
                StudioTheme.sidebar
                if colorScheme == .light {
                    LinearGradient(colors: [Color.white.opacity(0.22), Color.clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            case .content:
                StudioTheme.shellSurface
            }
        }
    }
}

/// Thin line icons drawn from the design board's 24pt vector paths. The SF
/// Symbols closest to them (`chart.bar.xaxis`, `trash`) are filled and heavier.
struct AskLineGlyph: Shape {
    enum Kind { case usage, trash }
    var kind: Kind

    /// Polylines in a 24x24 grid, exactly as drawn on the design board.
    static func polylines(_ kind: Kind) -> [[CGPoint]] {
        switch kind {
        case .usage:
            return [[CGPoint(x: 4, y: 20), CGPoint(x: 4, y: 10)],
                    [CGPoint(x: 10, y: 20), CGPoint(x: 10, y: 4)],
                    [CGPoint(x: 16, y: 20), CGPoint(x: 16, y: 13)],
                    [CGPoint(x: 22, y: 20), CGPoint(x: 2, y: 20)]]
        case .trash:
            return [[CGPoint(x: 3, y: 6), CGPoint(x: 21, y: 6)],
                    [CGPoint(x: 8, y: 6), CGPoint(x: 8, y: 4), CGPoint(x: 16, y: 4), CGPoint(x: 16, y: 6)],
                    [CGPoint(x: 6, y: 6), CGPoint(x: 7, y: 20), CGPoint(x: 17, y: 20), CGPoint(x: 18, y: 6)]]
        }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        var path = Path()
        for line in Self.polylines(kind) {
            path.addLines(line.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) })
        }
        return path
    }
}

struct AskLineIcon: View {
    var kind: AskLineGlyph.Kind
    var size: CGFloat = 15

    var body: some View {
        AskLineGlyph(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: size * 2 / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Section title inside a composer popover.
struct AskPopoverHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A choice in a composer popover: title over caption, an optional trailing
/// accessory, and a checkmark column that keeps every row aligned.
struct AskPopoverRow<Accessory: View>: View {
    var title: String
    var caption: String?
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.8, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    if let caption, !caption.isEmpty {
                        Text(caption).font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                accessory()
                Image(systemName: "checkmark").font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(AskTheme.accent)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AskTheme.accentSoft : (hovering ? AskTheme.hoverFill : Color.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension AskPopoverRow where Accessory == EmptyView {
    init(title: String, caption: String?, selected: Bool, action: @escaping () -> Void) {
        self.init(title: title, caption: caption, selected: selected, action: action, accessory: { EmptyView() })
    }
}

/// The separated action at the bottom of a composer popover.
struct AskPopoverFooterButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hovering ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(5)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
    }
}

/// The price multiplier as a small badge: green at or below 1x, amber above.
struct AskMultiplierBadge: View {
    var multiplier: String

    static func text(_ multiplier: String) -> String? {
        CloudModelPricing(multiplier: multiplier).label.map { String($0.dropLast()) + "×" }
    }

    static func tone(_ multiplier: String) -> Color {
        guard let value = Decimal(string: multiplier, locale: Locale(identifier: "en_US_POSIX")) else {
            return StudioTheme.textSecondary
        }
        return value <= 1 ? StudioTheme.success : StudioTheme.warning
    }

    var body: some View {
        if let text = Self.text(multiplier) {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Self.tone(multiplier))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// A two-option segmented control in the design's neutral style: a recessed
/// track and a raised thumb, instead of the system control's blue fill.
struct AskSegmentedControl<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(selected ? AskTheme.panelCard : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: Color.black.opacity(selected ? 0.18 : 0), radius: 1.5, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(AskTheme.segmentTrack, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}
