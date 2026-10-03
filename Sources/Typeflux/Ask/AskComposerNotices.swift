import AppKit
import SwiftUI

/// Something the composer needs the user to know or fix. It sits inside the
/// card, above the editor, so nothing ever hangs below the input.
struct AskComposerNotice: Identifiable, Equatable {
    /// Declared most urgent first: the order is the display priority.
    enum Kind: Int, CaseIterable, Comparable {
        case sendError, voice, attachment, screenshot

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var kind: Kind
    var text: String
    var id: Kind { kind }

    var tone: AskBanner.Tone { kind == .screenshot ? .info : .warning }

    var systemImage: String? {
        switch kind {
        case .sendError: return nil
        case .voice: return "mic.slash"
        case .attachment: return "paperclip"
        case .screenshot: return nil
        }
    }

    /// The notices to show, most urgent first; empty texts are skipped.
    static func resolve(sendError: String?, voiceError: String?, attachment: String?,
                        screenshot: String?) -> [AskComposerNotice] {
        let candidates: [(Kind, String?)] = [
            (.sendError, sendError), (.voice, voiceError), (.attachment, attachment), (.screenshot, screenshot)
        ]
        return candidates.compactMap { kind, text in
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AskComposerNotice(kind: kind, text: text)
        }
        .sorted { $0.kind < $1.kind }
    }

    /// Rows the card shows: the first notice, or all of them once expanded.
    static func visibleCount(total: Int, expanded: Bool) -> Int {
        expanded ? total : min(total, 1)
    }
}

/// The card's notice rows: one at a time, the rest counted on its "+N" button.
struct AskComposerNoticeStack: View {
    var notices: [AskComposerNotice]
    @Binding var expanded: Bool
    /// Nil for a notice that clears itself when its cause is fixed.
    var dismiss: (AskComposerNotice.Kind) -> (() -> Void)?

    var body: some View {
        let shown = AskComposerNotice.visibleCount(total: notices.count, expanded: expanded)
        VStack(spacing: AskMetrics.bannerSpacing) {
            ForEach(Array(notices.prefix(shown).enumerated()), id: \.element.id) { index, notice in
                AskBanner(text: notice.text, tone: notice.tone, systemImage: notice.systemImage,
                          more: index == 0 ? moreTitle : nil,
                          onMore: index == 0 && notices.count > 1 ? { expanded.toggle() } : nil,
                          onDismiss: dismiss(notice.kind))
                    .transition(.opacity)
            }
        }
        .padding(.top, AskMetrics.bannerSpacing)
        .padding(.horizontal, AskMetrics.composerNoticeInset)
        .onChange(of: notices.count) { count in if count < 2 { expanded = false } }
    }

    private var moreTitle: String? {
        guard notices.count > 1 else { return nil }
        return expanded ? L("ask.notice.less") : L("ask.notice.more", notices.count - 1)
    }
}

/// A confirmation such as "Switched to coding/auto": one quiet line in the
/// footer's empty space, with no fill or outline, that fades in and out.
/// The control it describes already shows the new value.
struct AskComposerFootnote: View {
    var text: String

    var body: some View {
        // Shown whole or not at all: a truncated confirmation reads as noise.
        // VoiceOver hears it either way (see `AskAnnouncer`).
        ViewThatFits(in: .horizontal) {
            label.fixedSize()
            Color.clear.frame(width: 0, height: 0)
        }
        .accessibilityHidden(true)
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 11.5)).lineLimit(1)
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 6)
        .frame(maxWidth: AskMetrics.footnoteMaxWidth, alignment: .trailing)
    }
}

/// Reads a confirmation out to VoiceOver, since the footnote is visual only.
enum AskAnnouncer {
    static func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }
}
