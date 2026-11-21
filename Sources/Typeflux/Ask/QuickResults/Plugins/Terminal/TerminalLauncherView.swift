import AppKit
import SwiftUI

struct TerminalLauncherView: View {
    @ObservedObject var model: TerminalLauncherModel
    @ObservedObject var session: TerminalSession
    let sessions: [TerminalSession]
    let select: (UUID) -> Void
    let new: () -> Void
    let close: () -> Void
    let move: (() -> Void)?
    let dismiss: () -> Void
    let insert: (String) -> Void
    let commands: () -> [String]
    let error: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(L("terminal.launcher.label"), systemImage: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 7) {
                    Label(session.displayDirectory(session.cwd), systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                        .help(session.cwd)
                    if let git = session.git {
                        Text("⎇ " + git.branch + (git.dirty ? "*" : ""))
                            .foregroundStyle(Color.purple)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                Spacer(minLength: 8)
                if sessions.count > 1 {
                    Menu {
                        ForEach(sessions) { candidate in
                            Button {
                                select(candidate.id)
                            } label: {
                                let icon = candidate.id == session.id ? "checkmark" : "terminal"
                                Label(name(candidate), systemImage: icon)
                            }
                        }
                    } label: {
                        Text(name(session)).lineLimit(1).frame(maxWidth: 140)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(L("terminal.launcher.sessions"))
                }
                terminalButton("plus", L("terminal.launcher.new") + " ⌘T", action: new)
                if let move {
                    terminalButton("macwindow.badge.plus", L("terminal.launcher.move") + " ⌘O", action: move)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            if session.alternateScreen {
                TerminalAlternateScreenView(session: session)
            } else {
                TerminalSessionContent(model: model, session: session, commands: commands, new: new,
                                       insert: insert, error: error)
            }
        }
        .background(TerminalKeyCapture { event in
            let editor = event.window?.firstResponder as? NSTextView
            guard editor?.hasMarkedText() != true else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if session.alternateScreen, modifiers != .command || event.keyCode != 31 { return false }
            if modifiers == .command, event.keyCode == 13 {
                if !event.isARepeat { close() }
                return true
            }
            guard let key = AskCommandKey(event) else { return false }
            switch key {
            case .commandT: if !event.isARepeat { new() }
            case .commandO:
                guard let move else { return false }
                move()
            case .escape:
                if !model.cancelRisk(), !model.resetCompletion(), !model.deselect() { dismiss() }
            case let .number(number):
                if sessions.indices.contains(number - 1) { select(sessions[number - 1].id) }
            default: return false
            }
            return true
        })
    }

    private func name(_ candidate: TerminalSession) -> String {
        candidate.blocks.last?.command ?? candidate.displayDirectory(candidate.cwd)
    }
}

/// Shared command blocks and prompt. Each host renders the same persisted shell.
struct TerminalSessionContent: View {
    @ObservedObject var model: TerminalLauncherModel
    @ObservedObject var session: TerminalSession
    let commands: () -> [String]
    let new: () -> Void
    let insert: (String) -> Void
    let error: (String) -> Void

    @State private var atTail = true
    @State private var hovered: UUID?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            blockList
            if let risk = model.pendingRisk {
                TerminalRiskCard(risk: risk, cancel: { model.cancelRisk() }, confirm: { model.confirmRisk() })
            }
            if !model.completionCandidates.isEmpty {
                completionList
            }
            Divider()
            prompt
        }
        .background(TerminalKeyCapture(handler: handle))
        .task(id: model.prompt) {
            model.synchronizePrompt()
            await Task.yield()
            if !Task.isCancelled { focused = model.prompt != .running }
        }
        .onDisappear { model.secret = "" }
    }

    private var blockList: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(session.blocks) { block in
                            row(block, viewportHeight: viewport.size.height)
                        }
                        Color.clear.frame(height: 1).id("terminal-tail")
                            .onAppear { atTail = true }
                            .onDisappear { atTail = false }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, TerminalRunnerHost.inset.left)
                }
                .onChange(of: session.blocks.last?.id) { _ in
                    if atTail { scroll.scrollTo("terminal-tail", anchor: .bottom) }
                }
                .onChange(of: session.blocks.last?.endedAt) { _ in
                    if atTail { scroll.scrollTo("terminal-tail", anchor: .bottom) }
                }
                .onChange(of: session.liveOutputRows) { _ in
                    if atTail { scroll.scrollTo("terminal-tail", anchor: .bottom) }
                }
                .onChange(of: model.selected) { id in
                    if let id { scroll.scrollTo(id) }
                }
                .onAppear { scroll.scrollTo("terminal-tail", anchor: .bottom) }
            }
            .frame(height: viewport.size.height)
        }
        .background(Color(nsColor: palette.background))
    }

    private var palette: TerminalRunnerPalette {
        appearance == .dark ? .dark : .light
    }

    private func row(_ block: TerminalCommandBlock, viewportHeight: CGFloat) -> some View {
        let running = block.endedAt == nil
        let selected = model.selected == block.id
        let collapsed = model.collapsed.contains(block.id)
        let failed = block.exitCode.map { $0 != 0 } ?? false
        let tint: NSColor = selected ? .controlAccentColor : appearance == .dark ? .white : .black
        let background = palette.background.blended(withFraction: selected ? 0.12 : 0.04, of: tint)
            ?? palette.background
        return VStack(alignment: .leading, spacing: 6) {
            blockHeader(block, running: running, selected: selected, collapsed: collapsed, failed: failed)
            if running {
                let rowHeight = session.terminalView.rowHeight
                let availableRows = max(1, Int(max(0, viewportHeight - 50) / rowHeight))
                let height = CGFloat(min(session.liveOutputRows, availableRows)) * rowHeight
                TerminalLiveOutput(session: session, background: background,
                                   availableRows: viewportHeight > 0 ? availableRows : 0)
                    .frame(height: height).allowsHitTesting(false)
            } else if collapsed {
                Text(L("terminal.launcher.lines", block.output.string.components(separatedBy: "\n").count))
                    .foregroundStyle(.secondary)
            } else if block.output.length > 0 {
                let plain = AttributedString(block.output.string)
                let output = (try? AttributedString(block.output, including: \.appKit)) ?? plain
                Text(output).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(9)
        .background(Color(nsColor: background), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            if selected || failed {
                Capsule().fill(selected ? Color.accentColor : .red).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? block.id : (hovered == block.id ? nil : hovered) }
    }

    private func blockHeader(_ block: TerminalCommandBlock, running: Bool, selected: Bool,
                             collapsed: Bool, failed: Bool) -> some View {
        HStack(spacing: 7) {
            Text("❯").foregroundStyle(Color.green)
            Text(block.command).lineLimit(1).truncationMode(.middle)
                .help(block.command)
            if block.cwd != session.cwd {
                Label(session.displayDirectory(block.cwd), systemImage: "folder")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: 4)
            if selected || hovered == block.id {
                if running {
                    terminalButton("stop.circle", L("terminal.launcher.interrupt") + " ⌃C",
                                   action: session.interrupt)
                } else {
                    blockActions(block, collapsed: collapsed)
                }
            }
            if let end = block.endedAt {
                Text(TerminalRunModel.format(end.timeIntervalSince(block.startedAt)))
                    .foregroundStyle(.secondary)
                Text(TerminalLauncherModel.mark(block))
                    .foregroundStyle(failed ? Color.red : Color.green)
            } else {
                TimelineView(.periodic(from: block.startedAt, by: 1)) { context in
                    Text(TerminalRunModel.format(context.date.timeIntervalSince(block.startedAt)))
                        .foregroundStyle(.secondary)
                }
                ProgressView().controlSize(.small).scaleEffect(0.65)
            }
        }
    }

    @ViewBuilder
    private func blockActions(_ block: TerminalCommandBlock, collapsed: Bool) -> some View {
        if block.output.length > 0 {
            terminalButton("doc.on.doc", L("terminal.launcher.copy") + " ⌘C") { copy(block.output.string) }
            terminalButton(collapsed ? "chevron.down" : "chevron.up",
                           L(collapsed ? "terminal.launcher.expand" : "terminal.launcher.collapse")) {
                model.toggleCollapsed(block.id)
            }
        }
        if block.state != .cancelled && (block.output.length > 0 || model.settings.insert == .commandAndOutput) {
            terminalButton("arrow.down.to.line", insertTitle + " ⌘↩") { model.insert(block, using: insert) }
        }
        terminalButton("arrow.clockwise", L("terminal.launcher.rerun") + " ⌘R") { rerun(block) }
            .disabled(model.prompt != .idle)
    }

    private var insertTitle: String {
        if let name = model.source?.localizedName { return L("terminal.launcher.insertInto", name) }
        return L("terminal.runner.insert")
    }

    private var completionList: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.completionCandidates, id: \.self) { candidate in
                        Text(candidate)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(model.completionSelection == candidate
                                ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                            .id(candidate)
                    }
                }
                .padding(.horizontal, 14)
            }
            .onChange(of: model.completionSelection) { candidate in
                if let candidate { scroll.scrollTo(candidate) }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(height: 24)
    }

    private var prompt: some View {
        let state = model.prompt
        return HStack(spacing: 8) {
            if state == .secure {
                Image(systemName: "lock.fill").foregroundStyle(Color.orange)
            }
            if state == .secure || state == .input {
                Text(session.runningBlock?.command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
                    .lineLimit(1)
            }
            Text(state == .input ? "›" : "❯")
                .foregroundStyle(state == .secure ? Color.orange : state == .input ? .blue : .green)
            if state == .secure {
                SecureField("", text: $model.secret)
                    .accessibilityLabel(L("terminal.launcher.password"))
                    .focused($focused)
                    .onSubmit(submit)
            } else {
                TextField(state == .ended ? L("terminal.launcher.ended") : "", text: Binding(get: { model.text }, set: {
                    model.resetCompletion()
                    model.text = $0
                }))
                    .accessibilityLabel(L("terminal.command.placeholder"))
                    .focused($focused)
                    .disabled(state == .running)
                    .onSubmit(submit)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .opacity(state == .running ? 0.45 : 1)
    }

    private func submit() {
        if model.prompt == .ended { new(); return }
        if !model.submit(), model.prompt == .idle, !model.text.isEmpty,
           let problem = TerminalCommandRequest.problem(with: model.text) {
            error(problem)
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        AskQuickResults.copy(text)
        error(L("terminal.runner.copied"))
    }

    private func rerun(_ block: TerminalCommandBlock?) {
        guard let block, model.prompt == .idle else { return }
        model.fill(block.command)
        submit()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let editor = event.window?.firstResponder as? NSTextView
        guard editor?.hasMarkedText() != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if let key = AskCommandKey(event), model.pendingRisk != nil {
            switch key {
            case .commandEnter:
                if !event.isARepeat { model.confirmRisk() }
                return true
            case .escape: return model.cancelRisk()
            case .enter, .tab, .commandR: return true
            default: break
            }
        }
        if focused, model.prompt == .idle, AskCommandKey(event) == .tab {
            let selection = editor?.selectedRange()
            guard selection == nil || selection == NSRange(location: model.text.utf16.count, length: 0) else {
                return false
            }
            if model.complete(), let editor {
                // Keep the live field editor and the model in sync between consecutive Tab events.
                editor.string = model.text
                editor.setSelectedRange(NSRange(location: model.text.utf16.count, length: 0))
            }
            return true
        }
        switch (modifiers, event.keyCode) {
        case (.control, 8):
            model.secret = ""
            session.interrupt()
            return true
        case (.control, 2):
            guard session.runningBlock != nil || model.text.isEmpty else { return false }
            model.secret = ""
            session.eof()
            return true
        case (.command, 40): model.clear(); return true
        default:
            guard let key = AskCommandKey(event) else { return false }
            return handle(key, hasSelection: (editor?.selectedRange().length ?? 0) > 0)
        }
    }

    private func handle(_ key: AskCommandKey, hasSelection: Bool) -> Bool {
        switch key {
        case .up, .down:
            guard focused, model.prompt == .idle else { return false }
            model.recall(key == .up ? 1 : -1, commands: commands())
        case .escape: return model.resetCompletion()
        case .optionUp, .optionDown: model.select(key == .optionUp ? -1 : 1)
        case .commandEnter: model.insertSelected(using: insert)
        case .commandC:
            guard !hasSelection, model.selected != nil, let block = model.actionBlock else { return false }
            copy(block.output.string)
        case .commandR: rerun(model.actionBlock)
        default: return false
        }
        return true
    }
}

private func terminalButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .help(title)
    .accessibilityLabel(title)
}

/// Intercepts session shortcuts only while that host's window is receiving keys.
private struct TerminalKeyCapture: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> Listener { Listener() }
    func updateNSView(_ view: Listener, context: Context) { view.handler = handler }
    static func dismantleNSView(_ view: Listener, coordinator: ()) { view.stop() }

    final class Listener: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, event.window === window, window.isVisible,
                      window.attachedSheet == nil, handler?(event) == true else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
