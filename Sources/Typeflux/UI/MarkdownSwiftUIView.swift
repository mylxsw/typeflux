import Markdown
import SwiftUI

struct MarkdownSwiftUIView: View {
    let markdown: String

    private var document: Markdown.Document {
        Markdown.Document(parsing: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TypefluxSpacing.small.value(for: .classic)) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { _, child in
                blockView(child)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockView(_ markup: Markup) -> AnyView {
        if let paragraph = markup as? Paragraph {
            return AnyView(inlineChildren(paragraph)
                .font(.system(.body, weight: .regular))
                .foregroundStyle(TypefluxColor.label.color)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading))
        } else if let heading = markup as? Heading {
            return AnyView(inlineChildren(heading)
                .font(.system(headingTextStyle(for: heading.level), weight: .bold))
                .foregroundStyle(TypefluxColor.label.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, heading.level <= 2 ? TypefluxSpacing.small.value(for: .classic) : 0))
        } else if let unorderedList = markup as? UnorderedList {
            return AnyView(listView(unorderedList.children.map(\.self), orderedStart: nil))
        } else if let orderedList = markup as? OrderedList {
            return AnyView(listView(orderedList.children.map(\.self), orderedStart: Int(orderedList.startIndex)))
        } else if let blockQuote = markup as? BlockQuote {
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blockQuote.children.enumerated()), id: \.offset) { _, child in
                    blockView(child)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(TypefluxColor.separator.color)
                    .frame(width: 3)
            })
        } else if let codeBlock = markup as? CodeBlock {
            return AnyView(SwiftUI.Text(codeBlock.code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(TypefluxColor.label.color)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: .classic), style: .continuous)
                        .fill(TypefluxColor.controlBackground.color.opacity(0.92))
                ))
        } else if markup is ThematicBreak {
            return AnyView(Divider()
                .padding(.vertical, TypefluxSpacing.small.value(for: .classic)))
        } else {
            let fallback = plainText(in: markup).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !fallback.isEmpty {
                return AnyView(SwiftUI.Text(fallback)
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(TypefluxColor.label.color)
                    .frame(maxWidth: .infinity, alignment: .leading))
            }
        }

        return AnyView(EmptyView())
    }

    private func listView(_ items: [Markup], orderedStart: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: TypefluxSpacing.small.value(for: .classic)) {
                    SwiftUI.Text(listMarker(index: index, orderedStart: orderedStart))
                        .font(.system(.body, weight: .regular))
                        .foregroundStyle(TypefluxColor.label.color)
                        .frame(width: orderedStart == nil ? 14 : 28, alignment: .trailing)

                    listItemContent(item)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func listItemContent(_ item: Markup) -> AnyView {
        if let listItem = item as? ListItem,
           listItem.childCount == 1,
           let paragraph = listItem.child(at: 0) as? Paragraph {
            return AnyView(inlineChildren(paragraph)
                .font(.system(.body, weight: .regular))
                .foregroundStyle(TypefluxColor.label.color)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading))
        } else {
            let text = plainText(in: item).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return AnyView(SwiftUI.Text(text)
                .font(.system(.body, weight: .regular))
                .foregroundStyle(TypefluxColor.label.color)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading))
        }
    }

    private func listMarker(index: Int, orderedStart: Int?) -> String {
        if let orderedStart {
            return "\(orderedStart + index)."
        }

        return "•"
    }

    private func inlineChildren(_ markup: Markup) -> SwiftUI.Text {
        markup.children.reduce(SwiftUI.Text("")) { partial, child in
            partial + inlineText(child)
        }
    }

    private func inlineText(_ markup: Markup) -> SwiftUI.Text {
        if let text = markup as? Markdown.Text {
            return SwiftUI.Text(text.string)
        }

        if markup is SoftBreak {
            return SwiftUI.Text("\n")
        }

        if markup is LineBreak {
            return SwiftUI.Text("\n")
        }

        if let inlineCode = markup as? InlineCode {
            return SwiftUI.Text(inlineCode.code)
                .font(.system(.callout, design: .monospaced))
        }

        if let strong = markup as? Strong {
            return inlineChildren(strong).fontWeight(.semibold)
        }

        if let emphasis = markup as? Emphasis {
            return inlineChildren(emphasis).italic()
        }

        if let strikethrough = markup as? Strikethrough {
            return inlineChildren(strikethrough).strikethrough()
        }

        if let link = markup as? Markdown.Link {
            return inlineChildren(link).underline()
        }

        return inlineChildren(markup)
    }

    private func plainText(in markup: Markup) -> String {
        if let text = markup as? Markdown.Text {
            return text.string
        }

        if markup is SoftBreak || markup is LineBreak {
            return "\n"
        }

        if let inlineCode = markup as? InlineCode {
            return inlineCode.code
        }

        if let codeBlock = markup as? CodeBlock {
            return codeBlock.code
        }

        return markup.children.map { plainText(in: $0) }.joined()
    }

    private func headingTextStyle(for level: Int) -> Font.TextStyle {
        switch level {
        case 1:
            .title2
        case 2:
            .title3
        default:
            .title3
        }
    }
}
