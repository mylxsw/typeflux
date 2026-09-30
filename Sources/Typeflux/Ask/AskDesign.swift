// swiftlint:disable file_length
import AppKit
import SwiftUI

/// Design tokens for the Ask surfaces.
///
/// The launcher and the workspace are standalone windows placed directly over
/// the desktop, so every backplate has to be opaque. Only the rounded exterior,
/// the drop shadow and the recording glow are allowed to be translucent.
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
    static let launcherCorner: CGFloat = 18
    static let composerCorner: CGFloat = 14
    /// Breathing room around the launcher card.
    static let launcherGutter: CGFloat = 6
    static let editorTopInset: CGFloat = 15
    static let editorBottomInset: CGFloat = 11
    static let footerHeight: CGFloat = 44
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
    static let composerMaxWidth: CGFloat = 780
    static let transcriptMaxWidth: CGFloat = 680
    static let bubbleMaxWidth: CGFloat = 560
    static let assistantIndent: CGFloat = 30

    /// Height of the launcher panel, including its transparent gutter.
    static func launcherHeight(editor: CGFloat, banners: Int) -> CGFloat {
        editor + editorTopInset + editorBottomInset + footerHeight + launcherGutter * 2
            + CGFloat(banners) * (bannerHeight + bannerSpacing)
    }
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
    enum Style { case neutral, active, warning, dashed }

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
        .overlay(Capsule().strokeBorder(stroke, style: strokeStyle))
        .contentShape(Capsule())
        .onTapGesture { if !disabled { action?() } }
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .opacity(disabled ? 0.55 : 1)
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
        case .dashed: return StudioTheme.textTertiary
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

    private var strokeStyle: StrokeStyle {
        style == .dashed ? StrokeStyle(lineWidth: 1, dash: [3, 2]) : StrokeStyle(lineWidth: 1)
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

struct AskSendButton: View {
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : StudioTheme.textTertiary)
        .background(enabled ? AskTheme.accent : AskTheme.controlSurface, in: Circle())
        .disabled(!enabled)
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

struct AskAvatar: View {
    var size: CGFloat = 22
    var corner: CGFloat?

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.30, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.36, blue: 0.96)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: corner ?? size / 2, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

struct AskGhostButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10.5))
                Text(title).font(.system(size: 11.5))
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A subtle recording outline complements the fixed voice control.
/// Focus and transcription keep the neutral border.
struct AskVoiceBorder: ViewModifier {
    @ObservedObject var voice: AskVoiceInput
    var context: String
    var radius: CGFloat

    private var listening: Bool { voice.context == context && voice.phase == .listening }

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Self.borderColor(listening: listening),
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }

    /// Focus alone stays neutral: the accent colour has to keep meaning "recording".
    static func borderColor(listening: Bool) -> Color {
        if listening { return AskTheme.accent.opacity(0.45) }
        return AskTheme.border
    }
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
