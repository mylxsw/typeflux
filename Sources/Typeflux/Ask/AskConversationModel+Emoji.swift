import Foundation

extension AskConversationModel {
    /// Resolve only the current output, never an item retained by an earlier view render.
    func selectedEmoji(copying text: String) -> EmojiResult? {
        guard plugins.isPlanCurrent, let output = plugins.output,
              let result = output.emoji?.results.first(where: { $0.id == output.selected?.id }),
              result.sequence == text else { return nil }
        return result
    }

    func recordEmoji(_ result: EmojiResult?) {
        guard let result else { return }
        emojiUsage.record(id: result.id, sequence: result.sequence)
    }

    func performEmojiAction(_ action: EmojiAction) {
        guard plugins.isPlanCurrent, let output = plugins.output, let presentation = output.emoji else { return }
        var selected = output.selected?.id ?? ""
        var variant = ""
        switch action {
        case let .favorite(id):
            guard presentation.results.contains(where: { $0.id == id }) else { return }
            emojiUsage.toggleFavorite(id)
            selected = id
        case let .variant(id, sequence):
            guard let result = presentation.results.first(where: { $0.id == id }),
                  sequence == result.entry.sequence || result.entry.variants
                  .contains(where: { $0.sequence == sequence }) else { return }
            emojiUsage.setVariant(sequence, for: id)
            selected = id
            variant = sequence
        case .copyAndStay:
            if let result = presentation.results
                .first(where: { $0.id == output.selected?.id }) {
                copyPluginText(result.sequence)
            }
            return
        case .clearRecent: emojiUsage.clearRecent()
        }
        plugins.rerun(
            with: ["selectedID": selected, "selectedQuery": launcherDraft.text, "selectedVariant": variant],
            selection: nil,
            text: launcherDraft.text,
            language: AppLocalization.shared.language
        )
    }
}
