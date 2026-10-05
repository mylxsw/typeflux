import AppKit
import SwiftUI

/// The launcher's captured context as one compact token before the editor:
/// the app's icon, a short window title, the selected lines and the screenshot
/// thumbnail. Clicking it, or ⌘K, opens `AskLauncherContextPanel`.
struct AskLauncherContextTokenView: View {
    var token: AskLauncherContext.Token
    var thumbnail: NSImage?
    var action: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 30
    static let titleMaxWidth: CGFloat = 150

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if token.hasSource { appIcon }
                if let title = token.title {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: Self.titleMaxWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let lines = token.selectionLines {
                    HStack(spacing: 3) {
                        Image(systemName: "text.quote").font(.system(size: 10, weight: .semibold))
                        Text("\(lines)").font(.system(size: 12).monospacedDigit())
                    }
                    .foregroundStyle(StudioTheme.textSecondary)
                }
                if token.screenshot != .none {
                    if token.hasSource || token.selectionLines != nil {
                        Rectangle().fill(AskTheme.separator).frame(width: 1, height: 16)
                    }
                    screenshot
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 7)
            .frame(height: Self.height)
            .background(hovering ? AskTheme.hoverFill : AskTheme.hoverFill.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(token.screenshot == .failed ? StudioTheme.warning.opacity(0.6) : AskTheme.border,
                              lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help([token.help, L("ask.context.token.help")].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel(L("ask.context"))
        .accessibilityValue(token.help ?? "")
        .accessibilityHint(L("ask.context.token.help"))
        .accessibilityIdentifier("ask.context.token")
        .animation(.easeOut(duration: 0.18), value: token)
    }

    private var appIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            if let bundle = token.bundleID, let icon = AskContextChips.appIcon(bundle) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "app").font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 18, height: 18)
            }
            if token.restored {
                Image(systemName: "clock.fill")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .frame(width: 11, height: 11)
                    .background(Circle().fill(AskTheme.composerSurface))
                    .overlay(Circle().strokeBorder(AskTheme.border, lineWidth: 0.5))
                    .offset(x: 4, y: 4)
                    .accessibilityHidden(true)
            }
        }
        .opacity(token.sourceOff ? 0.4 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var screenshot: some View {
        switch token.screenshot {
        case .capturing:
            ProgressView().controlSize(.mini).frame(width: 27, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(StudioTheme.warning)
                .frame(width: 27, height: 18)
        case .attached, .off:
            thumbnailFace
                .opacity(token.screenshot == .off ? 0.35 : 1)
                .overlay {
                    if token.screenshot == .off {
                        Rectangle().fill(StudioTheme.textPrimary).frame(width: 30, height: 1.5)
                            .rotationEffect(.degrees(-30))
                    }
                }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var thumbnailFace: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "display").font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .frame(width: 27, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(AskTheme.border, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Everything the token stands for, one switch per item: the source app and
/// window, the screenshot with a preview, and the selected text; then taking
/// the current app instead of a restored one.
struct AskLauncherContextPanel: View {
    @Binding var draft: AskDraft
    var thumbnail: NSImage?
    var screenshotState: AskScreenshotState
    var restored: Bool
    /// The draft's captured content is being replaced; source and selection wait.
    var capturing: Bool
    var screenshotCapturing: Bool
    var setIncluded: (AskCapturedContentKind, Bool) -> Void
    /// Switches the screenshot on or off; nil when it cannot change now.
    var toggleScreenshot: (() -> Void)?
    /// Grants access or retries a failed screenshot.
    var fixScreenshot: (() -> Void)?
    var recapture: () -> Void
    var refresh: (() -> Void)?
    var refreshTitle: String

    static let width: CGFloat = 340

    private var source: (app: String, window: String?)? {
        guard let value = draft.source, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AskContextChips.sourceParts(value)
    }

    private var screenshotFailure: (permission: Bool, message: String)? {
        switch screenshotState {
        case let .failed(permission, message): return (permission, message)
        case let .unavailable(reason): return (false, reason)
        case .attached, .off: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let source { sourceRow(source) }
            screenshotRow
            if draft.includeScreenshot, !screenshotCapturing, let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AskTheme.border))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .accessibilityLabel(L("ask.context.screen.full"))
            }
            if let selection = draft.selection, !selection.isEmpty { selectionRow(selection) }
            if let refresh {
                Divider().padding(.horizontal, 6).padding(.vertical, 2)
                Button(action: refresh) {
                    Label(refreshTitle, systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(capturing)
                .accessibilityIdentifier("ask.context.refresh")
            }
            Text(L("ask.context.source.metadataOnly"))
                .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.top, 4)
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .padding(10)
        .frame(width: Self.width)
        .accessibilityIdentifier("ask.context.panel")
    }

    private func sourceRow(_ source: (app: String, window: String?)) -> some View {
        let detail = [restored ? L("ask.context.source.previous") : nil, source.window]
            .compactMap { $0 }.joined(separator: " · ")
        return row(title: source.app, detail: detail.isEmpty ? nil : detail, isOn: draft.sourceOff != true,
                   disabled: capturing, identifier: "ask.context.panel.source",
                   toggle: { setIncluded(.source, $0) }) {
            if let bundle = draft.sourceBundleID, let icon = AskContextChips.appIcon(bundle) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").font(.system(size: 14)).foregroundStyle(StudioTheme.textSecondary)
            }
        }
    }

    @ViewBuilder private var screenshotRow: some View {
        let failure = screenshotFailure
        let detail: String = if screenshotCapturing {
            L("ask.context.screen.capturing")
        } else if draft.includeScreenshot, let failure {
            failure.message
        } else if draft.includeScreenshot {
            L("ask.context.screen.scope")
        } else {
            L("ask.context.screen.excluded")
        }
        row(title: L("ask.context.screen.full"), detail: detail, isOn: draft.includeScreenshot,
            disabled: toggleScreenshot == nil, identifier: "ask.context.panel.screenshot",
            toggle: { _ in toggleScreenshot?() }) {
            Image(systemName: failure != nil && draft.includeScreenshot ? "exclamationmark.triangle" : "display")
                .font(.system(size: 13))
                .foregroundStyle(failure != nil && draft.includeScreenshot ? StudioTheme.warning : StudioTheme.textSecondary)
        } trailing: {
            if draft.includeScreenshot, let failure, let fixScreenshot {
                Button(L(failure.permission ? "ask.context.screen.grant" : "ask.context.screen.retry"),
                       action: fixScreenshot)
                    .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
            } else if draft.includeScreenshot, thumbnail != nil, !screenshotCapturing {
                Button(action: recapture) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.textSecondary)
                .help(L("ask.capture.refresh"))
                .accessibilityLabel(L("ask.capture.refresh"))
            }
        }
    }

    private func selectionRow(_ selection: String) -> some View {
        let lines = AskPresentation.lineCount(selection)
        let count = L(lines == 1 ? "ask.context.selection.singleLine" : "ask.context.selection.lineCount", lines)
        return row(title: L("ask.context.panel.selection"),
                   detail: "“" + AskContextChips.selectionPreview(selection) + "” · " + count,
                   isOn: draft.selectionOff != true, disabled: capturing, identifier: "ask.context.panel.selection",
                   toggle: { setIncluded(.selection, $0) }) {
            Image(systemName: "text.quote").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AskTheme.accent)
        }
    }

    private func row<Icon: View, Trailing: View>(
        title: String, detail: String?, isOn: Bool, disabled: Bool, identifier: String,
        toggle: @escaping (Bool) -> Void, @ViewBuilder icon: () -> Icon,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 10) {
            icon().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            trailing()
            Toggle(title, isOn: Binding(get: { isOn }, set: toggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(disabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
