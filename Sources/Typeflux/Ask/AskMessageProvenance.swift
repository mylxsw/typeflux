import SwiftUI

/// Facts from the sent message, independent of the composer's current draft.
enum AskMessageProvenance {
    enum Item: Equatable, Identifiable {
        case source(app: String, detail: String)
        case selection(String)
        case screenshot(String)

        var id: String {
            switch self {
            case .source: return "source"
            case .selection: return "selection"
            case .screenshot: return "screenshot"
            }
        }

        var label: String {
            switch self {
            case .source(let app, _): return L("ask.context.selection.source", app)
            case .selection(let text):
                let lines = AskPresentation.lineCount(text)
                return L(lines == 1 ? "ask.message.selection.line" : "ask.message.selection.lines", lines)
            case .screenshot: return L("ask.context.screen.full")
            }
        }
    }

    static func items(for message: AskMessage) -> [Item] {
        guard message.role == "user" else { return [] }
        var items: [Item] = []
        if let rawSource = message.source {
            let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            let app = AskContextChips.sourceParts(rawSource).app.trimmingCharacters(in: .whitespacesAndNewlines)
            if !app.isEmpty { items.append(.source(app: app, detail: source)) }
        }
        if let selection = message.selection, !selection.isEmpty { items.append(.selection(selection)) }
        if let image = message.image, !image.isEmpty { items.append(.screenshot(image)) }
        return items
    }
}

/// The summary replaces the captured attachment chips while retaining their previews.
struct AskMessageProvenanceView: View {
    let message: AskMessage
    @State private var showSelection = false
    @State private var showImage = false

    var body: some View {
        let items = AskMessageProvenance.items(for: message)
        if !items.isEmpty {
            AskFlowLayout(spacing: 5, alignment: .trailing) {
                ForEach(items) { item in
                    HStack(spacing: 5) {
                        if item.id != items.first?.id { Text("·").accessibilityHidden(true) }
                        content(item)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(StudioTheme.textSecondary)
            .accessibilityIdentifier("ask.message.provenance")
        }
    }

    @ViewBuilder private func content(_ item: AskMessageProvenance.Item) -> some View {
        switch item {
        case .source(_, let detail):
            Text(item.label).lineLimit(1).help(detail)
        case .selection(let text):
            Button { showSelection.toggle() } label: { Text(item.label) }
                .buttonStyle(.plain)
                .help(L("ask.context.previewHint"))
                .accessibilityIdentifier("ask.message.selection")
                .popover(isPresented: $showSelection) {
                    ScrollView {
                        Text(text).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 380, height: 220)
                    .padding(14)
                }
        case .screenshot(let url):
            Button { showImage.toggle() } label: { Text(item.label) }
                .buttonStyle(.plain)
                .help(L("ask.context.previewHint"))
                .accessibilityIdentifier("ask.message.screenshot")
                .popover(isPresented: $showImage) {
                    if let image = AskImage.decode(url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 650).padding()
                    } else {
                        Text(L("ask.image.previewUnavailable")).font(.system(size: 12)).padding()
                    }
                }
        }
    }
}
