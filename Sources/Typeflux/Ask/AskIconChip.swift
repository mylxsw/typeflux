import AppKit
import SwiftUI

/// Context tokens preserve their preview, toggle and removal actions.
struct AskIconChip: View {
    let item: AskContextItem
    var action: (() -> Void)?
    var onRemove: (() -> Void)?
    /// Captured screenshot preview, supplied by the launcher only.
    var screenshot: NSImage?
    /// Full captured text for the launcher's scrollable selection preview.
    var selection: String?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.askUsesLibraryTokens) private var libraryTokens
    @State private var hovering = false
    @State private var showingCard = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var anchor = AskHoverAnchor.Holder()
    @State private var cardID = UUID()

    private struct CardContent: Equatable {
        let item: AskContextItem
        let screenshot: NSImage?
        let selection: String?
    }

    private var cardContent: CardContent { CardContent(item: item, screenshot: screenshot, selection: selection) }

    var body: some View {
        chipControl
            .onHover(perform: hover)
            .onDisappear(perform: dismissCard)
            .onChange(of: cardContent) { content in
                if showingCard { showCard(content) } else if hovering { scheduleCard(content) }
            }
            .onChange(of: enabled) { if !$0 { hovering = false; dismissCard() } }
            // The card never takes key status: a popover swallowed the click
            // meant for the chip. Selection cards accept scrolling only.
            .background(AskHoverAnchor(holder: anchor))
            .accessibilityElement(children: libraryTokens ? .contain : .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(item.title)
            .accessibilityValue(selection == nil ? "" : L(item.style == .active
                ? "ask.context.selection.enabled" : "ask.context.selection.disabled"))
            .accessibilityHint([item.sourceAppName.map { L("ask.context.selection.source", $0) },
                                item.detail, item.hint].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAction {
                dismissCard()
                if let action { action() } else { explain() }
            }
            .accessibilityActions {
                if selection != nil {
                    Button(L("ask.context.details")) { explain() }
                }
                if item.removable {
                    Button(L("ask.remove")) { onRemove?() }
                }
            }
    }

    @ViewBuilder private var chipControl: some View {
        if libraryTokens {
            TypefluxToken(item.title, removeLabel: L("ask.remove"), systemImage: item.systemImage, action: {
                dismissCard()
                if let action { action() } else { explain() }
            }, onRemove: item.removable ? onRemove : nil)
                .foregroundStyle(item.style == .warning ? TypefluxColor.warning.color : TypefluxColor.label.color)
        } else {
            Button {
                dismissCard()
                // A read-only chip answers a click with its explanation, so it never feels dead.
                if let action { action() } else { explain() }
            } label: {
                AskIconChipFace(item: item, hovering: hovering)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if hovering, item.removable, let onRemove {
                    Button {
                        dismissCard()
                        onRemove()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 14, height: 14)
                            .background(Color(nsColor: .systemGray), in: Circle())
                            .overlay(Circle().strokeBorder(TypefluxColor.controlBackground.color, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    // Mostly inside the chip, so reaching for it never ends the hover.
                    .offset(x: 1, y: -1)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func hover(_ inside: Bool) {
        hovering = inside && enabled
        hoverTask?.cancel()
        guard hovering else {
            if selection != nil, showingCard { scheduleDismissal() } else { dismissCard() }
            return
        }
        scheduleCard(cardContent)
    }

    /// Let the pointer cross the small gap into the preview and scroll it.
    /// Screenshot and memory cards retain their original click-through behavior.
    private func scheduleDismissal() {
        hoverTask = Task { @MainActor in
            repeat {
                try? await Task.sleep(nanoseconds: AskContextChips.hoverDelay)
                guard !Task.isCancelled, !hovering else { return }
            } while AskHoverCardPresenter.shared.containsPointer(owner: cardID)
            dismissCard()
        }
    }

    private func scheduleCard(_ content: CardContent) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: AskContextChips.hoverDelay)
            guard !Task.isCancelled, hovering else { return }
            showCard(content)
        }
    }

    /// Shows the card for a click. Leaving the chip hides it as usual; opened
    /// without the pointer on the chip (keyboard, VoiceOver) it closes by itself.
    private func explain() {
        showCard(cardContent)
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: AskContextChips.explainDuration)
            guard !Task.isCancelled, !hovering else { return }
            dismissCard()
        }
    }

    private func showCard(_ content: CardContent) {
        guard enabled, let view = anchor.view else { return }
        if let selection = content.selection {
            AskHoverCardPresenter.shared.show(AskSelectionHoverCard(item: content.item, text: selection),
                                              owner: cardID, anchor: view, interactive: true)
        } else {
            AskHoverCardPresenter.shared.show(AskContextCard(items: [content.item], screenshot: content.screenshot),
                                              owner: cardID, anchor: view)
        }
        showingCard = true
    }

    private func dismissCard() {
        hoverTask?.cancel()
        showingCard = false
        AskHoverCardPresenter.shared.hide(owner: cardID)
    }
}
