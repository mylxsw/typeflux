import AppKit
import SwiftUI

/// What the window's buttons do; the window controller supplies them.
struct TerminalRunnerActions {
    var copy: () -> Void
    var insert: () -> Void
    var rerun: () -> Void
    var openExternal: () -> Void
    var stop: () -> Void
    var close: () -> Void
    var togglePin: () -> Void
}

/// The built-in terminal window: a header with the command and its state, the terminal,
/// and a footer with what can be done now. See GUL-431's design.
struct TerminalRunnerView: View {
    static let headerHeight: CGFloat = 40
    static let footerHeight: CGFloat = 40
    /// Room for the window's traffic-light buttons.
    static let titleInset: CGFloat = 84

    @ObservedObject var model: TerminalRunModel
    let terminal: NSView
    let actions: TerminalRunnerActions
    @Binding var pinned: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioTheme.border).frame(height: TFMetrics.borderWidth)
            TerminalRunnerHost(view: terminal)
            Rectangle().fill(StudioTheme.border).frame(height: TFMetrics.borderWidth)
            footer
        }
        .environment(\.tfControlSize, .small)
        .background(Color(nsColor: TerminalRunnerPalette.chrome))
        // The header is the title bar: it runs under the traffic-light buttons.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            indicator.frame(width: 16, height: 16)
            (Text("$ ").foregroundColor(StudioTheme.textTertiary) + Text(model.command))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .help(model.command)
                .accessibilityIdentifier("terminal.runner.command")
            Spacer(minLength: 8)
            tag(model.directoryLabel, monospaced: true).help(model.launch.directory)
            elapsed
            Button(action: actions.togglePin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pinned ? StudioTheme.accent : StudioTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(pinned ? "terminal.runner.unpin" : "terminal.runner.pin"))
            .accessibilityIdentifier("terminal.runner.pin")
        }
        .padding(.leading, Self.titleInset).padding(.trailing, 10)
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .running:
            if model.readsHiddenInput {
                dot(StudioTheme.warning)
            } else if model.alternateScreen {
                dot(StudioTheme.accent)
            } else {
                TFSpinner(size: .regular)
            }
        case .finished(0): dot(StudioTheme.success)
        case .finished, .failedToStart: dot(StudioTheme.danger)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    @ViewBuilder private var elapsed: some View {
        if model.isRunning {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                tag(TerminalRunModel.format(model.duration), monospaced: false)
            }
        } else {
            tag(TerminalRunModel.format(model.duration), monospaced: false)
        }
    }

    private func tag(_ text: String, monospaced: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .monospacedDigit()
            .foregroundStyle(StudioTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7).frame(height: 20)
            .background(TFColors.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            status.layoutPriority(0)
            Spacer(minLength: 8)
            footerActions.fixedSize()
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(height: Self.footerHeight)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .running:
                if model.readsHiddenInput {
                    dot(StudioTheme.warning)
                    strong(L("terminal.runner.status.waiting"))
                    secondary(L("terminal.runner.status.hiddenInput"))
                } else if model.alternateScreen {
                    dot(StudioTheme.accent)
                    strong(L("terminal.runner.status.fullScreen"))
                } else {
                    strong(L("terminal.runner.status.running"))
                    secondary(model.launch.shellName + " · " + L(model.settings.shell == .interactive
                            ? "terminal.runner.shell.interactive" : "terminal.runner.shell.login"))
                }
            case let .finished(code) where code == 0:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StudioTheme.success)
                strong(copied ? L("terminal.runner.copied") : L("terminal.runner.status.done"))
                secondary(L("terminal.runner.status.exit", Int(code), TerminalRunModel.format(model.duration)))
            case let .finished(code):
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StudioTheme.danger)
                strong(copied ? L("terminal.runner.copied") : L("terminal.runner.status.failed"),
                       color: copied ? StudioTheme.textPrimary : StudioTheme.danger)
                secondary(L("terminal.runner.status.exit", Int(code), TerminalRunModel.format(model.duration)))
            case let .failedToStart(message):
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StudioTheme.danger)
                strong(L("terminal.runner.status.notStarted"), color: StudioTheme.danger)
                secondary(message).help(message)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.runner.status")
    }

    private func strong(_ text: String, color: Color = StudioTheme.textPrimary) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private var footerActions: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .running:
                Text(L("terminal.runner.interruptHint")).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                TFButton(title: L(model.interruptSent ? "terminal.runner.forceStop" : "terminal.runner.stop"),
                         systemImage: "stop.fill", destructive: model.interruptSent, action: actions.stop)
                    .accessibilityIdentifier("terminal.runner.stop")
            case .finished:
                TFButton(title: L("terminal.runner.copy"), systemImage: "doc.on.doc") {
                    actions.copy()
                    flashCopied()
                }
                .disabled(!model.hasOutput)
                .accessibilityIdentifier("terminal.runner.copy")
                TFButton(title: L("terminal.runner.rerun"), systemImage: "arrow.clockwise", action: actions.rerun)
                    .accessibilityIdentifier("terminal.runner.rerun")
                TFButton(title: L("terminal.command.runIn", model.externalTerminal.title),
                         systemImage: "arrow.up.forward.app", kind: .plain, iconOnly: true,
                         action: actions.openExternal)
                    .accessibilityIdentifier("terminal.runner.external")
                TFButton(title: insertTitle + "  ⌘↩", systemImage: "arrow.down.to.line", kind: .primary,
                         action: actions.insert)
                    .disabled(!model.hasOutput)
                    .accessibilityIdentifier("terminal.runner.insert")
            case .failedToStart:
                TFButton(title: L("terminal.runner.rerun"), systemImage: "arrow.clockwise", action: actions.rerun)
                TFButton(title: L("terminal.runner.close"), kind: .primary, action: actions.close)
            }
        }
    }

    private var insertTitle: String {
        model.targetAppName.map { L("terminal.runner.insertInto", $0) } ?? L("terminal.runner.insert")
    }

    private func flashCopied() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Hosts the AppKit terminal view, inset from the window edges on the terminal's own background.
struct TerminalRunnerHost: NSViewRepresentable {
    static let inset = NSEdgeInsets(top: 8, left: 12, bottom: 6, right: 4)
    let view: NSView

    func makeNSView(context _: Context) -> NSView {
        let container = TerminalRunnerContainer(terminal: view)
        return container
    }

    func updateNSView(_: NSView, context _: Context) {}
}

/// Paints the terminal's background around its inset so the gap does not show the window.
final class TerminalRunnerContainer: NSView {
    private let terminal: NSView

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        let inset = TerminalRunnerHost.inset
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom)
        ])
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = TerminalRunnerPalette.forAppearance(effectiveAppearance).background.cgColor
    }
}
