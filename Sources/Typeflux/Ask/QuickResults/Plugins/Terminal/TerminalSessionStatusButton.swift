import AppKit
import SwiftUI

struct TerminalSessionStatusButton: View {
    let sessions: [TerminalSession]
    let open: (UUID) -> Void
    let end: (UUID) -> Void
    @State private var showingSessions = false
    @State private var hovering = false
    @State private var selection: UUID?

    var body: some View {
        let ordered = TerminalSessionStatus.ordered(sessions)
        if let first = ordered.first {
            let count = TerminalSessionStatus.countBadge(ordered.count)
            let title = L("terminal.launcher.sessions")
            Button {
                toggleList(first.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal").font(.system(size: 15, weight: .medium))
                    TerminalSessionStatusDot(status: first.status)
                    if let count {
                        Text(count, format: .number)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(hovering || showingSessions ? AskTheme.hoverFill : AskTheme.launcherTile,
                            in: RoundedRectangle(cornerRadius: 8))
                .frame(height: AskMetrics.composerControlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .foregroundStyle(StudioTheme.textSecondary)
            .help(title + " ⌘J")
            .accessibilityLabel(title)
            .accessibilityValue(count.map { $0.formatted() } ?? "")
            .accessibilityIdentifier("terminal.sessions.status")
            .background(TerminalKeyCapture { handle($0, sessions: ordered) })
            .popover(isPresented: $showingSessions, arrowEdge: .bottom) {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(ordered) { session in
                                TerminalSessionStatusRow(session: session, selected: session.id == selection, open: {
                                    openSession(session.id)
                                }, end: { end(session.id) })
                                .id(session.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selection) { id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
                .frame(width: 360, height: CGFloat(min(ordered.count, 8) * 46 + 12))
                .background {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                }
                .accessibilityIdentifier("terminal.sessions.list")
                .background(TerminalKeyCapture { handle($0, sessions: ordered) })
            }
            .onChange(of: ordered.map(\.id)) { ids in
                if showingSessions, !ids.contains(where: { $0 == selection }) { selection = ids.first }
            }
            .onDisappear { showingSessions = false }
        }
    }

    private func toggleList(_ first: UUID) {
        if !showingSessions { selection = first }
        showingSessions.toggle()
    }

    private func openSession(_ id: UUID) {
        showingSessions = false
        open(id)
    }

    private func handle(_ event: NSEvent, sessions: [TerminalSession]) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "j" {
            if !event.isARepeat, let first = sessions.first { toggleList(first.id) }
            return true
        }
        guard showingSessions, let key = AskCommandKey(event),
              let index = sessions.firstIndex(where: { $0.id == selection }) else { return false }
        switch key {
        case .up: selection = sessions[max(0, index - 1)].id
        case .down: selection = sessions[min(sessions.count - 1, index + 1)].id
        case .enter:
            if !event.isARepeat { openSession(sessions[index].id) }
        default: return false
        }
        return true
    }
}

private struct TerminalSessionStatusRow: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let open: () -> Void
    let end: () -> Void
    @State private var hovered = false

    var body: some View {
        let highlighted = hovered || selected
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 8) {
                    TerminalSessionStatusDot(status: session.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.statusRowTitle)
                            .font(.system(size: 12, design: .monospaced))
                        if let subtitle = session.statusRowSubtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 6)
                    Group {
                        if session.status == .waiting {
                            Text(L("terminal.launcher.waiting")).foregroundStyle(Color.orange)
                        } else if let start = session.runningBlock?.startedAt {
                            TimelineView(.periodic(from: start, by: 1)) { context in
                                Text(TerminalRunModel.format(context.date.timeIntervalSince(start)))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .layoutPriority(1)
                    if case .window = session.host {
                        Image(systemName: "macwindow").foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("terminal.session.open.\(session.id)")
            .accessibilityAction(named: L("terminal.session.end"), end)
            Button(action: end) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .help(L("terminal.session.end"))
            .accessibilityLabel(L("terminal.session.end"))
            .accessibilityIdentifier("terminal.session.end.\(session.id)")
            .opacity(highlighted ? 1 : 0)
            .allowsHitTesting(highlighted)
            .accessibilityHidden(!highlighted)
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .background(highlighted ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

extension TerminalSession {
    var statusRowTitle: String {
        if let command = blocks.last?.command { return command }
        return displayDirectory(cwd) == "~" ? "~" : tabFolder
    }

    var statusRowSubtitle: String? {
        let directory = displayDirectory(cwd)
        return directory == statusRowTitle ? nil : directory
    }
}
