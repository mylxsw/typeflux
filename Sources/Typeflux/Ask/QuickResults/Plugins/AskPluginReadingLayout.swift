import AppKit

extension AskPluginResultsView {
    /// Text is a reading surface; even a single application or file remains a list.
    static func isReadingOutput(_ output: AskPluginOutput) -> Bool {
        output.items.isEmpty && output.translation == nil && output.emoji == nil
            && output.wordCard == nil && output.image == nil && !output.applicationGrid
    }

    static func presentedOutput(_ display: AskPluginDisplay) -> AskPluginOutput? {
        guard display.hint == nil else { return nil }
        switch display.phase {
        case .running: return display.partial ?? display.previous
        case let .done(_, output): return output
        default: return nil
        }
    }

    /// The keyword chip already names the active tool. Lists retain their grouping label.
    static func showsSection(for display: AskPluginDisplay) -> Bool {
        if display.permission != nil { return false }
        guard let output = presentedOutput(display) else { return true }
        return !isReadingOutput(output) && output.translation == nil
    }

    static func contentViewportHeight(for display: AskPluginDisplay, viewportHeight: CGFloat?) -> CGFloat? {
        viewportHeight.map {
            max(0, $0 - 1 - listPadding * 2 - (showsSection(for: display) ? sectionHeight + rowSpacing : 0))
        }
    }

    /// Spend available space on text before scrolling. Short results keep their natural height.
    /// Header, comparison, note and actions are siblings of the scroll view and remain visible.
    static func readingBodyHeight(_ output: AskPluginOutput, comparing: Bool, contentHeight: CGFloat?) -> CGFloat {
        guard isReadingOutput(output) else {
            return output.markdown ? markdownHeight(output.body) : bodyHeight(output.body)
        }
        let measured = output.markdown ? markdownContentHeight(output.body)
            : max(22, textHeight(output.body, font: bodyFont, lineSpacing: bodyLineSpacing))
        let maximum = contentHeight.map { max(0, $0 - textCardChromeHeight(output, comparing: comparing)) }
            ?? (output.markdown ? maximumMarkdownHeight : maximumBodyHeight)
        return min(measured, maximum)
    }

    static func textCardChromeHeight(_ output: AskPluginOutput, comparing: Bool) -> CGFloat {
        cardPadding.top + headerHeight + 8 + cardPadding.bottom
            + (comparing ? originalHeight(output.original) + 9 : 0)
            + (output.note != nil ? 6 + noteHeight : 0) + 10 + actionsHeight
    }

    func readingBodyHeight(_ output: AskPluginOutput) -> CGFloat {
        Self.readingBodyHeight(output, comparing: display.comparing,
                               contentHeight: Self.contentViewportHeight(for: display, viewportHeight: viewportHeight))
    }
}
