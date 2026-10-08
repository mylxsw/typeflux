// swiftlint:disable file_length
import AppKit
import SwiftUI

/// Design tokens for the Ask surfaces.
///
/// The workspace is a standalone window placed directly over the desktop, so its
/// backplates are opaque. The launcher card is the one exception: it is glass
/// (`AskGlassBackground`), and falls back to `launcherSurface` when the user
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
    /// Marks conversations kept on this Mac (the lock icon, the header chip).
    static let privateTint = Color(nsColor: .systemPurple)
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
    /// The floating launcher's frost and opaque fallback. A deeper neutral in
    /// dark mode keeps bright windows behind the panel from washing out its text;
    /// a cool off-white in light mode keeps the glass from reading as paper.
    static let launcherSurface = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.980, alpha: 1),
        dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.110, alpha: 1)
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
    /// The launcher's idle edge. It floats over arbitrary windows, so it needs a
    /// firmer outline than the workspace composer's `border` to read as a panel.
    static let floatingBorder = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.12),
        dark: NSColor(calibratedWhite: 1, alpha: 0.18)
    )
    /// The launcher's hairline on glass. The light card is clear enough to vanish
    /// into a white window without it; dark glass keeps its own rim.
    static let floatingGlassEdge = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08),
        dark: .clear
    )

    // The launcher's own washes. Its card is glass over arbitrary windows, so in
    // light mode these are translucent and take on the backdrop instead of
    // pasting opaque greys on it. Dark mode keeps the shared opaque tokens.

    /// Rules inside the launcher: under the editor and above its bottom bar.
    static let launcherSeparator = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )
    /// The highlighted home row or keyword chip, outlined by `launcherSelectionEdge`.
    static let launcherSelection = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.94, alpha: 0.13),
        dark: NSColor(calibratedRed: 0.082, green: 0.149, blue: 0.243, alpha: 1)
    )
    static let launcherSelectionEdge = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.94, alpha: 0.18),
        dark: .clear
    )
    /// The `fy`, `dict` keyword labels.
    static let launcherKeyword = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.94, alpha: 0.11),
        dark: NSColor(calibratedRed: 0.082, green: 0.149, blue: 0.243, alpha: 1)
    )
    /// A neutral row icon's tile: a raised white chip in light mode instead of a grey wash.
    static let launcherTile = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72),
        dark: NSColor(calibratedWhite: 0.720, alpha: 0.14)
    )
    static let launcherTileEdge = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10),
        dark: .clear
    )
    /// Keyword chips at rest.
    static let launcherChipFill = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5),
        dark: .clear
    )
    static let launcherChipEdge = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )
    /// The ⌘1…⌘9 badges: a faint well in light mode, an outline in dark.
    static let launcherShortcutFill = StudioTheme.dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.045),
        dark: .clear
    )
    static let launcherShortcutEdge = StudioTheme.dynamic(
        light: .clear,
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )
    /// Times, shortcut badges and the key hint: a step below secondary text in
    /// light mode so titles lead. Dark mode keeps secondary text.
    static let launcherMetaText = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0.40, alpha: 1),
        dark: NSColor(calibratedWhite: 0.720, alpha: 1)
    )
    /// A footer switch that is on (screenshot, memory): a tinted well behind the
    /// accent icon, so "on" reads by shape as well as colour.
    static let switchOnFill = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.94, alpha: 0.14),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 0.22)
    )
    static let switchOnEdge = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.94, alpha: 0.30),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 0.35)
    )
    /// The design board's glass tint for in-window panels (sidebar, header
    /// pills, composer): a cool graphite in dark, white in light. Frosted at
    /// `AskGlassPlacement.inWindow.frost(dark:)`, so the backdrop's glows show through.
    static let glassFill = StudioTheme.dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.204, alpha: 1)
    )
    /// The pressed (or hovered field) wash, one step above `hoverFill`.
    static let pressFill = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.09),
        dark: NSColor(calibratedWhite: 1, alpha: 0.12)
    )
    /// Translucent hover wash, so borderless controls read the same on any surface.
    static let hoverFill = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    static let monoSurface = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.957, green: 0.965, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.063, green: 0.071, blue: 0.086, alpha: 1)
    )

    /// A readable title for a tool call; raw tool names never reach the transcript.
    /// `mcpServer` names the server of an MCP tool when the caller knows it.
    static func toolTitle(_ call: AskToolCall, mcpServer: String? = nil) -> String {
        let name = call.function.name
        if ["workflow_start", "workflow_list", "workflow_read", "workflow_environment", "workflow_check_keyword",
            "workflow_propose", "workflow_test", "workflow_save"].contains(name) {
            return L("ask.tool." + name)
        }
        if name == "web_search" || name == "web_fetch" {
            let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any]
            let detail = name == "web_search"
                ? args?["query"] as? String
                : (args?["url"] as? String).flatMap { URL(string: $0)?.host }
            let title = L(name == "web_search" ? "ask.tool.webSearch" : "ask.tool.webFetch")
            return detail.map { title + " · " + $0 } ?? title
        }
        let args = (try? AskLocalTools.jsonArguments(call.function.arguments)) ?? [:]
        switch name {
        case "generate_image": return L("imagegen.title")
        case "artifact": return L("ask.artifact.title")
        case "project_files": return L("ask.project.title") + " · " + (args["action"] as? String ?? "")
        case "update_plan": return L("ask.tool.update_plan")
        case "research":
            let question = (args["question"] as? String).map { String($0.prefix(60)) }
            return question.map { L("ask.tool.research") + " · " + $0 } ?? L("ask.tool.research")
        case "files":
            // Files actions carry their own verbs: "read" is shared with the browser's "read page".
            let action = args["action"] as? String ?? ""
            let title = ["list", "read", "search", "write", "edit"].contains(action) ? L("ask.files.action." + action) : L("ask.tool.files")
            let target = action == "search" ? args["query"] as? String : (args["path"] as? String).map { ($0 as NSString).lastPathComponent }
            return target.flatMap { $0.isEmpty ? nil : title + " · " + $0 } ?? title
        default: break
        }
        if name.hasPrefix("mcp_") {
            return (mcpServer ?? "MCP") + " · " + String(name.dropFirst(4))
        }
        if ["memory", "run_code", "skill"].contains(name) {
            let title = L("ask.tool." + name)
            if name == "skill", let skill = args["name"] as? String { return title + " · " + skill }
            if name == "run_code", let language = args["language"] as? String { return title + " · " + language }
            if let action = args["action"] as? String, !action.isEmpty { return title + " · " + L("ask.action." + action) }
            return title
        }
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
    /// Compact corners for the floating launcher, shared by its glass and content clip.
    static let launcherCardCorner: CGFloat = 16
    /// Height of every footer control: menus, context chips, microphone and send.
    static let composerControlHeight: CGFloat = 34
    /// Horizontal padding inside the footer's text menus (model, reasoning).
    static let composerControlPadding: CGFloat = 10
    static let bannerHeight: CGFloat = 32
    static let bannerSpacing: CGFloat = 6
    static let sidebarWidth: CGFloat = 264
    /// The usage panel's glass card; it floats inset like the sidebar.
    static let usagePanelWidth: CGFloat = 330
    /// Height of the title bar row; the unified toolbar centres the traffic lights in it.
    static let titleBarRowHeight: CGFloat = 52
    /// Space above the sidebar's first row, clearing the title bar tools.
    static let sidebarTopInset: CGFloat = 52
    /// Vertical strip reserved for the window's traffic-light buttons.
    static let trafficLightStrip: CGFloat = 32
    /// Leading space for the title bar tools, past the traffic lights with an
    /// 8pt gap so the collapsed pill never touches the zoom button.
    static let trafficLightInset: CGFloat = 86
    /// Width of an icon button in the title bar row (compose, sidebar, search).
    static let titleBarButtonWidth: CGFloat = 30
    /// Header title inset when the sidebar is collapsed: past the pill holding
    /// the toggle, search and compose buttons, plus the gap between pills.
    static let collapsedTitleInset: CGFloat = trafficLightInset + titleBarButtonWidth * 3 + 6 + 12
    /// One centred reading column shared by the transcript and the composer, so
    /// questions, answers and the input line up instead of spanning the window.
    /// The design board's reading column is 720pt of content; the composer
    /// card is 20pt wider on each side so its text lines up with the column.
    static let columnWidth: CGFloat = 768
    static let columnInset: CGFloat = 24
    static let composerMaxWidth: CGFloat = 760
    /// The empty state's three suggestion cards.
    static let suggestionsMaxWidth: CGFloat = 680
    static let transcriptMaxWidth: CGFloat = columnWidth - columnInset * 2
    static let bubbleMaxWidth: CGFloat = 560
    /// The sidebar floats as a glass panel inset from the window edges; its
    /// corner is concentric with the 12pt rows inset 8pt inside it.
    static let sidebarPanelInset: CGFloat = 8
    static let sidebarPanelCorner: CGFloat = 20
    static let sidebarRowCorner: CGFloat = 12
    /// Where text starts in the sidebar: the list's 8pt inset plus a row's 10pt
    /// padding, so the account name lines up with the history titles.
    static let sidebarTextLeading: CGFloat = sidebarPanelInset + 10
    /// Title and action capsules floating in the header over the transcript.
    static let headerCapsuleHeight: CGFloat = 38
    /// How far the transcript fades out where it meets the window's top and bottom edges.
    static let transcriptEdgeFade: CGFloat = 28
    /// Space between the window's bottom edge and the composer card. Nothing
    /// sits under the card: notices live inside it, confirmations in its footer.
    static let composerBottomInset: CGFloat = 22
    /// Notice rows inside the composer card are inset this far from its edges.
    static let composerNoticeInset: CGFloat = 8
    /// The footer's confirmation note never grows past this.
    static let footnoteMaxWidth: CGFloat = 220
    /// Top of the header pills: centred in the title bar row.
    static var headerCapsuleTop: CGFloat { (titleBarRowHeight - headerCapsuleHeight) / 2 }
    /// The ⌘K search card, a glass card over the dimmed window.
    static let paletteCorner: CGFloat = 22
    /// Widest the composer's model name may grow before it truncates in the middle.
    static let modelMenuMaxWidth: CGFloat = 132
    /// The saved-screenshot card above the composer and its thumbnail.
    static let recoveryCardCorner: CGFloat = 12
    static let recoveryThumbnail = CGSize(width: 54, height: 36)

    /// Height of the launcher panel, including its transparent gutter.
    /// `banners` counts the notice rows inside the card; each adds its height plus the gap above it.
    /// `suggestions` is the height of the launcher's home under the editor (`AskLauncherSuggestions`).
    static func launcherHeight(editor: CGFloat, banners: Int, suggestions: CGFloat = 0, attachments: Bool = false,
                               attachmentHeight: CGFloat? = nil) -> CGFloat {
        let chrome = AskComposerChrome.launcher
        return launcherHeaderHeight(editor: editor) + chrome.footerHeight + launcherGutter * 2
            + CGFloat(banners) * (bannerHeight + bannerSpacing)
            + max(0, suggestions)
            + (attachments ? attachmentHeight.map { max(0, $0) + 10 } ?? attachmentStripHeight : 0)
    }

    /// The attachment strip above the editor: one row of chips and its top padding.
    static let attachmentStripHeight: CGFloat = 40

    /// The launcher's first row: the editor beside the context token and the
    /// microphone and send buttons. One line of text keeps it at 58pt.
    static func launcherHeaderHeight(editor: CGFloat) -> CGFloat {
        let chrome = AskComposerChrome.launcher
        return max(composerControlHeight, editor) + chrome.editorTopInset + chrome.editorBottomInset
    }
}

/// Surface of the shared composer. The launcher and the workspace are the same
/// feature behind different triggers, so they share every control, state and
/// metric: one glass card floating over whatever is behind it. The launcher's
/// glass samples the windows under its panel; the workspace's samples the
/// transcript scrolling beneath it.
struct AskComposerChrome: Equatable {
    var fill: Color
    var corner: CGFloat
    var editorFontSize: CGFloat
    var horizontalInset: CGFloat
    var idleBorder: Color
    /// Draws the card with `AskGlassBackground` instead of `fill`.
    var glass = false
    var placement: AskGlassPlacement = .floating
    var editorTopInset: CGFloat = 15
    var editorBottomInset: CGFloat = 11
    var footerHeight: CGFloat = 44
    var footerLeadingInset: CGFloat = 12

    /// The launcher reads as a search field first: its editor is the first row,
    /// in larger text, and the model and switches sit in a quieter bottom bar.
    static let launcher = AskComposerChrome(
        fill: AskTheme.launcherSurface,
        corner: AskMetrics.launcherCardCorner,
        editorFontSize: 17,
        horizontalInset: 12,
        idleBorder: AskTheme.floatingBorder,
        glass: true,
        editorTopInset: 12,
        editorBottomInset: 12,
        footerHeight: 42,
        footerLeadingInset: 7
    )

    /// The launcher's card inside the conversation window. It sits on the
    /// window's own surface, so the opaque fallback needs only the regular border.
    static let workspace: AskComposerChrome = {
        var chrome = launcher
        chrome.idleBorder = AskTheme.border
        chrome.placement = .inWindow
        chrome.fill = AskTheme.glassFill
        // The design board's in-window card: 28pt corners, 15pt text 20pt in, a 48pt footer.
        chrome.corner = 28
        chrome.editorFontSize = 15
        chrome.horizontalInset = 20
        chrome.editorTopInset = 14
        chrome.editorBottomInset = 4
        chrome.footerHeight = 48
        chrome.footerLeadingInset = 10
        return chrome
    }()

    static func of(launcher: Bool) -> AskComposerChrome { launcher ? .launcher : .workspace }

    /// The card's outline at rest. A floating panel's glass lights its own edge;
    /// in-window glass is frosted with the window's own colours and would
    /// dissolve into a white window without its hairline.
    func idleBorder(on material: AskGlassMaterial?, increasedContrast: Bool) -> Color {
        guard let material, placement == .floating else { return idleBorder }
        return material.idleBorder(idleBorder, increasedContrast: increasedContrast)
    }

    /// The card's glass, falling back to `fill` when transparency is reduced.
    func glassBackground(_ material: AskGlassMaterial) -> AskGlassBackground {
        AskGlassBackground(material: material, corner: corner, opaqueFill: fill, placement: placement)
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

/// Monospaced block used for tool arguments and results.
struct AskMonoBlock: View {
    var title: String
    var text: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(isError ? StudioTheme.danger : StudioTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.separator))
        }
    }
}

/// Disconnects, voice failures and attachment refusals all use the same bar so
/// they never interrupt the transcript with red body text.
struct AskBanner: View {
    enum Tone { case info, warning, danger }

    var text: String
    var tone: Tone = .info
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?
    /// "+N" on the composer's first notice, expanding the others.
    var more: String?
    var onMore: (() -> Void)?
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
            if let more, let onMore {
                Button(action: onMore) {
                    Text(more).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .fixedSize()
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

/// A conversation event in the transcript, such as an automatic model switch:
/// a centred caption between two hairlines, with an optional link.
struct AskSystemLine: View {
    var text: String
    var systemImage: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            rule
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
                Text(text).lineLimit(2).multilineTextAlignment(.center).textSelection(.enabled)
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle).fontWeight(.semibold).foregroundStyle(AskTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                if let onDismiss {
                    Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("ask.remove"))
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(StudioTheme.textTertiary)
            .layoutPriority(1)
            rule
        }
        .frame(maxWidth: .infinity)
    }

    private var rule: some View {
        Rectangle().fill(AskTheme.separator).frame(height: 0.5).frame(minWidth: 16)
    }
}

/// Capsule buttons for Ask's own cards and sheets, in place of the stock
/// bordered buttons: `primary` fills with the design blue, `secondary` is a
/// quiet outline, `destructive` fills red for actions that cannot be undone. All dim when disabled.
struct AskCapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
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
                .foregroundStyle(kind == .secondary ? StudioTheme.textPrimary : Color.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(fill, in: Capsule())
                // A lit top edge on filled buttons, like the board's glass buttons.
                .overlay {
                    if kind != .secondary {
                        Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.18), .clear],
                                                      startPoint: .top, endPoint: .bottom))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(Capsule().strokeBorder(kind == .secondary ? AskTheme.border : Color.white.opacity(0.3),
                                                lineWidth: kind == .secondary ? 1 : 0.5))
                .shadow(color: kind == .primary ? AskTheme.accent.opacity(0.4) : .clear, radius: 7, y: 3)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                .fixedSize()
        }

        private var fill: Color {
            switch kind {
            case .primary: AskTheme.accent
            case .secondary: AskTheme.hoverFill
            case .destructive: StudioTheme.danger
            }
        }
    }
}

struct AskSendButton: View {
    static let size: CGFloat = 36
    var enabled: Bool
    /// Lit in the private tint for a conversation kept on this Mac.
    var tint: Color = AskTheme.accent
    /// Unlit but still clickable while Return does something else, such as
    /// opening the launcher's highlighted application.
    var prominent = true
    var action: () -> Void

    private var lit: Bool { enabled && prominent }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: AskSendButton.size, height: AskSendButton.size)
                .contentShape(Circle())
        }
        .buttonStyle(AskPressableStyle())
        .foregroundStyle(lit ? Color.white : enabled ? StudioTheme.textSecondary : StudioTheme.textTertiary)
        // The only solid control in the composer: a lit accent drop when it can send,
        // a faint translucent well otherwise, so it sits on glass and opaque cards alike.
        .background(Circle().fill(lit ? tint : AskTheme.hoverFill))
        .overlay {
            if lit {
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.32), .clear],
                                             center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: 22))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: lit ? tint.opacity(0.5) : .clear, radius: 9, y: 3)
        // Becoming sendable, the button lights up with a small spring.
        .scaleEffect(lit ? 1 : 0.94)
        .disabled(!enabled)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: lit)
        // The keys live here rather than in a hint row under the composer.
        .help(L("ask.send.help"))
        .accessibilityLabel(L("ask.send"))
    }
}

/// The send button's place while a run works and nothing is typed: a filled
/// stop square, so stopping never needs a separate control above the composer.
struct AskStopButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // Just the square, like every other composer icon: no circle around it.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StudioTheme.textPrimary)
                .frame(width: 12, height: 12)
                .frame(width: AskSendButton.size, height: AskSendButton.size)
                .contentShape(Circle())
        }
        .buttonStyle(AskPressableStyle())
        .keyboardShortcut(".", modifiers: .command)
        .help(L("ask.stop") + " ⌘.")
        .accessibilityLabel(L("ask.stop"))
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
    /// The travelling highlight; the launcher shows the voice in its own row instead.
    var sheen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listening: Bool { voice.context == context && voice.phase == .listening }

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Self.borderColor(listening: listening, idle: idle),
                                  lineWidth: Self.borderWidth(listening: listening))
                    .allowsHitTesting(false)
            )
            // The travelling highlight is a Core Animation layer, so it never
            // makes SwiftUI redraw the glass card per frame.
            .overlay {
                if sheen, Self.showsSheen(listening: listening, reduceMotion: reduceMotion) {
                    AskRecordingSheen(cornerRadius: radius, lineWidth: Self.borderWidth(listening: true), animated: true)
                        .allowsHitTesting(false)
                }
            }
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

    static func showsSheen(listening: Bool, reduceMotion: Bool) -> Bool { listening && !reduceMotion }

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
    /// Whether the transcript is scrolled to its end. The end marker starts
    /// right after the last message; the composer floats over the bottom
    /// `coveredBottom` points, so "at the end" means the marker begins above the card.
    static func isFollowingBottom(markerTop: CGFloat, viewport: CGFloat, coveredBottom: CGFloat,
                                  tolerance: CGFloat = 24) -> Bool {
        markerTop <= viewport - max(0, coveredBottom) + tolerance
    }

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
        if let contract = result.harness {
            guard contract.version == 1 else { return .failed }
            if let outcome = contract.outcome { return outcome.safeStatus == .ok ? .done : .failed }
        }
        return result.isError == true ? .failed : .done
    }

    /// An image from the screen or a page is a capture; any other tool produced its image.
    static func toolStatusText(result: AskMessage?, call: AskToolCall? = nil) -> String {
        if call?.function.name == "project_terminal", let result,
           let receipt = AskProjectTerminalReceipt.decode(result.resultText) {
            return receipt.status.exitCode.map { L("ask.terminal.exit", String($0)) } ?? receipt.status.state.rawValue
        }
        switch toolState(result: result) {
        case .running: return L("ask.tool.running")
        case .failed: return L("ask.tool.failed")
        default:
            guard result?.resultImages.isEmpty == false else { return L("ask.tool.done") }
            let captures = call.map { ["computer", "browser"].contains($0.function.name) } ?? true
            return L(captures ? "ask.image.captured" : "ask.image.generated")
        }
    }

    static func toolSymbol(_ call: AskToolCall) -> String {
        switch call.function.name {
        case "generate_image": return "photo.badge.plus"
        case "computer": return "desktopcomputer"
        case "browser": return "globe"
        case "web_search": return "magnifyingglass"
        case "web_fetch": return "network"
        case "artifact": return "doc.richtext"
        case "files", "project_files": return "folder"
        case "run_code", "project_terminal": return "terminal"
        case "skill": return "book"
        case "memory": return "brain"
        case "update_plan": return "list.bullet.clipboard"
        case "research": return "doc.text.magnifyingglass"
        case let name where name.hasPrefix("mcp_"): return "point.3.connected.trianglepath.dotted"
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

/// The conversation window's surface under both the floating sidebar and the
/// transcript. It reuses the settings window's tokens and material stack, so
/// both windows read as one app.
/// The workspace's canvas: frosted glass over the desktop. The window blurs
/// whatever is behind it and lays the app's own tint over that, so a colourful
/// wallpaper reads only as a soft cast, never as the window's colour.
struct AskWindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The app's own tint over the blurred desktop.
    static func base(dark: Bool) -> Color {
        dark ? Color(red: 0.094, green: 0.094, blue: 0.110) : Color(red: 0.969, green: 0.969, blue: 0.976)
    }

    /// How much of the tint covers the blur: enough to keep the window calm
    /// and legible on any wallpaper, light enough that it still reads as frosted.
    static func tintOpacity(dark: Bool, reduceTransparency: Bool) -> Double {
        if reduceTransparency { return 1 }
        return dark ? 0.78 : 0.72
    }

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            StudioVisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow, cornerRadius: nil)
            Self.base(dark: dark).opacity(Self.tintOpacity(dark: dark, reduceTransparency: reduceTransparency))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    /// A column label at the trailing edge, e.g. the models' credit multiplier.
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing { Text(trailing) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A choice in a composer popover: a leading checkmark column that keeps every
/// row aligned, title over caption, then an optional trailing accessory. The
/// selection is the checkmark alone; only the pointer fills a row.
struct AskPopoverRow<Accessory: View>: View {
    static var corner: CGFloat { 10 }

    var title: String
    /// Quiet text after the title, such as "Default".
    var note: String?
    var caption: String?
    var selected: Bool
    /// Listed but not choosable, e.g. a model that cannot read this conversation's images.
    var enabled = true
    var modelIcon: ModelIcon? = nil
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AskTheme.accentText)
                    .frame(width: 14)
                    .opacity(selected ? 1 : 0)
                if let modelIcon { modelIcon }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 13))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        if let note {
                            Text(verbatim: "· " + note).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .lineLimit(1).fixedSize()
                        }
                    }
                    if let caption, !caption.isEmpty {
                        Text(caption).font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory()
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A soft hover wash matches the launcher and keeps text colours stable.
            .background(hovering ? AskTheme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = enabled && $0 }
        .padding(.horizontal, 6)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension AskPopoverRow where Accessory == EmptyView {
    init(title: String, note: String? = nil, caption: String?, selected: Bool, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.init(title: title, note: note, caption: caption, selected: selected, enabled: enabled, action: action,
                  accessory: { EmptyView() })
    }
}

/// The separated action at the bottom of a composer popover: a quiet accent
/// link on the trailing side, under a hairline.
struct AskPopoverFooterButton: View {
    var title: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isEnabled ? AskTheme.accentText : StudioTheme.textTertiary)
                    .underline(hovering && isEnabled)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 10)
        }
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

/// Motion shared by the conversation window's panels and transcript, so the
/// sidebar, the usage panel and loaded conversations move the same way.
/// Reduce Motion keeps the state change but drops the travel.
enum AskMotion {
    static func panel(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    static func panelAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.88)
    }

    /// A loaded transcript fades in once it sits at its reading position.
    static func revealAnimation(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.1 : 0.22)
    }

    /// Loads that finish sooner (a cached conversation) never flash a spinner.
    static let progressDelay: Duration = .milliseconds(300)
}

/// A spinner that only appears when loading takes longer than `AskMotion.progressDelay`.
struct AskDelayedProgress: View {
    var title: String
    @State private var visible = false

    var body: some View {
        ProgressView(title).controlSize(.small)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: AskMotion.progressDelay)
                withAnimation(.easeOut(duration: 0.18)) { visible = true }
            }
    }
}

/// Reports the height of the banners and composer floating over the transcript.
struct AskBottomChromeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A mask over the transcript where it meets the floating chrome: hidden in
/// the strips outside the header pills and under the composer (`topClear`,
/// `bottomClear`), then fading in over `fade` points. Without the clear strips
/// unblurred text showed above the title pill and below the composer card.
struct AskEdgeFade: View {
    var topClear: CGFloat = 0
    var bottomClear: CGFloat = 0
    var fade: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topClear)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
            Color.clear.frame(height: bottomClear)
        }
        .allowsHitTesting(false)
    }
}

/// An icon button in the title bar row: borderless like the toolbar items of
/// native apps, with a hover wash and the shortcut in its tooltip.
struct AskTitleBarButton: View {
    var symbol: String
    var label: String
    var shortcut: String?
    var action: () -> Void
    @State private var hovering = false

    static var size: CGSize { CGSize(width: AskMetrics.titleBarButtonWidth, height: 28) }

    static func help(label: String, shortcut: String?) -> String {
        shortcut.map { label + " " + $0 } ?? label
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .frame(width: Self.size.width, height: Self.size.height)
                .background(hovering ? AskTheme.hoverFill : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Self.help(label: label, shortcut: shortcut))
        .accessibilityLabel(label)
    }
}
