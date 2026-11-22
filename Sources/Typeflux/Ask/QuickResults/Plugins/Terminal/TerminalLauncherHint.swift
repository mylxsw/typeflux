import SwiftUI

struct TerminalLauncherHint: View {
    let keyword: AskKeyword
    let text: String
    let directory: String?
    let recent: [String]
    let sessions: [TerminalSession]
    @Binding var highlighted: Int
    let activate: () -> Void

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(0, text.isEmpty ? L("terminal.launcher.open") : text, "terminal",
                        detail: directory, shortcut: "↩")
                    if !text.isEmpty {
                        let alternate = TerminalRunSettings.alternateRunner(in: keyword.options)
                        row(1, L(alternate == .window ? "terminal.launcher.window" : "terminal.launcher.runInLauncher"),
                            alternate == .window ? "macwindow" : "terminal", shortcut: "⌘↩")
                        let app = TerminalApplication.configured(in: keyword.options) ?? .terminal
                        row(2, L("terminal.command.runIn", app.title), "arrow.up.forward.app", shortcut: "⌥↩")
                    }
                    if !recent.isEmpty {
                        heading("terminal.launcher.recent")
                        ForEach(Array(recent.enumerated()), id: \.offset) { index, command in
                            row(offset + index, command, "clock", match: text)
                        }
                    }
                    if !sessions.isEmpty {
                        heading("terminal.launcher.sessions")
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            let command = session.blocks.last?.command ?? L("terminal.command.title")
                            row(offset + recent.count + index, command,
                                session.host == .launcher ? "terminal" : "macwindow",
                                detail: session.displayDirectory(session.cwd))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .onChange(of: highlighted) { scroll.scrollTo($0) }
        }
    }

    private var offset: Int { text.isEmpty ? 1 : 3 }

    private func heading(_ key: String) -> some View {
        Text(L(key)).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 5)
    }

    private func row(_ index: Int, _ title: String, _ symbol: String, detail: String? = nil,
                     shortcut: String? = nil, match: String? = nil) -> some View {
        Button {
            highlighted = index
            activate()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                Text(matchedTitle(title, match: match ?? "")).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let detail { Text(detail).lineLimit(1).foregroundStyle(.secondary) }
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(Color.accentColor.opacity(index == highlighted && match == nil ? 0.15 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if index == highlighted, match != nil {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(AskTheme.accentText.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .id(index)
    }

    private func matchedTitle(_ title: String, match: String) -> AttributedString {
        var result = AttributedString(title)
        if !match.isEmpty, let range = result.range(of: match, options: .caseInsensitive) {
            result[range].foregroundColor = AskTheme.accentText
        }
        return result
    }
}
