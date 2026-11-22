import AppKit
import SwiftUI

struct AskApprovalDetails: View {
    let call: AskToolCall
    let hostAccount: Bool
    let workingDirectory: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hostAccount {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text(L("ask.approval.command.account")).foregroundStyle(StudioTheme.textSecondary)
                        Text(L("ask.approval.command.localAccount"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let workingDirectory {
                        let path = (workingDirectory as NSString).abbreviatingWithTildeInPath
                        GridRow {
                            Text(L("ask.approval.command.directory")).foregroundStyle(StudioTheme.textSecondary)
                            Button {
                                let url = URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Text(verbatim: path).font(.system(size: 11.5, design: .monospaced))
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).help(L("ask.approval.reveal", path))
                        }
                    }
                }
                .font(.system(size: 12))
            }
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(L("ask.approval.command.arguments")).fontWeight(.medium)
                    Text(verbatim: AskToolPolicy.action(call)).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer(minLength: 4)
                    Button {
                        copied = AskQuickResults.copy(call.function.arguments)
                    } label: {
                        Label(L(copied ? "ask.copied" : "ask.copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { copied = false }
                    }
                    .onDisappear { copied = false }
                }
                .font(.system(size: 11.5)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(AskTheme.controlSurface)
                AskApprovalSource(source: Self.displayArguments(call.function.arguments), language: .json)
                    .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .background(AskTheme.monoSurface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(AskTheme.border) }
        }
        .accessibilityIdentifier("ask.approval.details.content")
    }

    static func displayArguments(_ raw: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return raw }
        return String(decoding: data, as: UTF8.self)
    }

}

struct AskApprovalSource: View {
    let source: String
    var language: AskWorkflowSyntaxHighlighter.Language = .plain
    var height: CGFloat = 150
    @Environment(\.colorScheme) private var colorScheme

    private func codeColor(_ token: AskWorkflowSyntaxHighlighter.Token) -> NSColor {
        let dark = colorScheme == .dark
        switch token {
        case .key:
            return dark ? NSColor(srgbRed: 0.65, green: 0.76, blue: 0.89, alpha: 1)
                : NSColor(srgbRed: 0.17, green: 0.36, blue: 0.57, alpha: 1)
        case .string:
            return dark ? NSColor(srgbRed: 0.75, green: 0.82, blue: 0.73, alpha: 1)
                : NSColor(srgbRed: 0.24, green: 0.42, blue: 0.30, alpha: 1)
        default:
            return token.color
        }
    }

    var body: some View {
        let attributed = NSMutableAttributedString(string: source)
        if attributed.length <= AskWorkflowSyntaxHighlighter.fullHighlightLimit {
            for span in AskWorkflowSyntaxHighlighter(language: language).spans(in: source) {
                attributed.addAttribute(.foregroundColor, value: codeColor(span.token), range: span.range)
            }
        }
        let content = Text(AttributedString(attributed))
            .font(.system(size: language == .shell ? 12.5 : 11.5, design: .monospaced))
            .lineSpacing(2).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxHeight: height)
        .fixedSize(horizontal: false, vertical: true)
    }
}
