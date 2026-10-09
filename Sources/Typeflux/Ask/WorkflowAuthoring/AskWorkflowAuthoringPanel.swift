// swiftlint:disable file_length type_body_length
import SwiftUI

/// The draft in the transcript: its real state, highlighted while the panel shows it.
struct AskWorkflowAuthoringCard: View {
    @ObservedObject var session: AskWorkflowAuthoringSession
    /// The panel beside the transcript shows this draft.
    var selected = false
    var open: () -> Void
    var close: () -> Void = {}

    var body: some View {
        let checklist = session.checklist
        let status = AskWorkflowDraftStatus.resolve(checklist: checklist, isDirty: session.isDirty)
        let keywords = session.draft.manifest?.keywords.map(\.keyword) ?? []
        Button(action: selected ? close : open) {
            HStack(spacing: 12) {
                AskWorkflowToolIcon(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.draft.manifest?.name ?? L("ask.workflow.chat.title"))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)
                        AskWorkflowStatusChip(status: status, long: true)
                    }
                    Text([session.draft.manifest?.description ?? L("ask.workflow.chat.draft"),
                          L("ask.workflow.chat.keywordLine", keywords.isEmpty
                              ? L("ask.workflow.chat.keywordNone")
                              : keywords.joined(separator: L("ask.workflow.chat.check.separator")))]
                        .joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if selected {
                    Text(L("ask.workflow.chat.openedBeside"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.horizontal, 10)
                } else {
                    Text(L(checklist.isComplete ? "ask.workflow.chat.try" : "ask.workflow.chat.view"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(AskTheme.hoverFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(AskTheme.border))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? AskTheme.accent : AskTheme.border, lineWidth: selected ? 1.5 : 1))
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(selected ? AskTheme.accent.opacity(0.18) : .clear).padding(-3))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(status.cardLabel)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("ask.workflow.card")
    }
}

/// The right-hand draft panel: header, tabs, content, and a fixed footer.
struct AskWorkflowAuthoringPanel: View {
    enum Tab: Hashable { case test, code }

    @ObservedObject var session: AskWorkflowAuthoringSession
    var focusCloseOnAppear = false
    var close: () -> Void
    var discard: (() -> Void)?
    /// Asks the conversation's AI to finish what is missing; nil where there is no conversation.
    var complete: ((String) -> Void)?
    /// The conversation is working, possibly on this very completion.
    var completing = false
    /// Nothing else holds the conversation, so a request can start right away.
    var canComplete = true
    /// The tab shown first; the user switches freely afterwards.
    var initialTab = Tab.test
    @State private var chosenTab: Tab?
    @State private var confirmsRun = false
    @State private var confirmsDiscard = false
    @State private var approvedRevision: UUID?
    @State private var showsCode = false
    @State private var showsSelection = false
    @State private var path = AskWorkflowManifest.fileName
    @State private var previewPath = AskWorkflowManifest.fileName
    @State private var testTask: Task<Void, Never>?
    @FocusState private var closeFocused: Bool
    @FocusState private var inputFocused: Bool

    var body: some View {
        let checklist = session.checklist
        let status = AskWorkflowDraftStatus.resolve(checklist: checklist, isDirty: session.isDirty)
        VStack(alignment: .leading, spacing: 0) {
            header(status: status)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .test:
                        if !checklist.isComplete { checklistSection(checklist) }
                        testSection(checklist)
                        resultSection(checklist)
                        if let message = session.message {
                            Text(message).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    case .code:
                        codeSection
                    }
                }
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 20)
            }
            footer(status: status)
        }
        .background(AskTheme.glassFill, in: RoundedRectangle(cornerRadius: 18))
        .padding(8)
        .confirmationDialog(L("ask.workflow.chat.runNotice"), isPresented: $confirmsRun, titleVisibility: .visible) {
            Button(L("ask.workflow.chat.run")) {
                guard approvedRevision == session.revision else { return }
                let input = AskWorkflowTestInput(query: session.query,
                    selection: session.selection.isEmpty ? nil : session.selection, keyword: session.keyword)
                testTask = Task { _ = await session.testLatestProposal([input]) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(([L("ask.workflow.chat.actionsPreview")] + session.risks.sorted().map(\.title)).joined(separator: "\n"))
        }
        .sheet(isPresented: $showsCode) { codeEditor }
        .confirmationDialog(L("ask.workflow.chat.discardNotice"), isPresented: $confirmsDiscard) {
            Button(L("ask.workflow.chat.discard"), role: .destructive) { discard?() }
            Button(L("common.cancel"), role: .cancel) {}
        }
        .onDisappear { testTask?.cancel(); session.cancel() }
        .onAppear {
            closeFocused = focusCloseOnAppear
            showsSelection = !session.selection.isEmpty
        }
        .accessibilityIdentifier("ask.workflow.preview")
    }

    private var tab: Tab { chosenTab ?? initialTab }

    // MARK: Header

    private func header(status: AskWorkflowDraftStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AskWorkflowToolIcon(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(session.draft.manifest?.name ?? L("ask.workflow.chat.title"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .lineLimit(1)
                        AskWorkflowStatusChip(status: status, long: false)
                    }
                    Text(session.draft.manifest?.description ?? L("ask.workflow.chat.draft"))
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                moreMenu
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.textSecondary)
                .help(L("ask.artifact.close"))
                .accessibilityLabel(L("ask.artifact.close"))
                .accessibilityIdentifier("ask.workflow.close").focused($closeFocused)
            }
            HStack(spacing: 18) {
                tabButton(.test, title: L("ask.workflow.chat.tab.test"))
                tabButton(.code, title: L("ask.workflow.chat.tab.code"), count: session.draft.paths.count)
                Spacer()
            }
            .overlay(alignment: .bottom) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
        }
        .padding(.leading, 18).padding(.trailing, 12).padding(.top, 14)
    }

    private var moreMenu: some View {
        Menu {
            Button { openEditor(AskWorkflowManifest.fileName) } label: {
                Label(L("ask.workflow.chat.openEditor"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            if session.canUndo {
                Button { session.undo() } label: {
                    Label(L("ask.workflow.chat.undo"), systemImage: "arrow.uturn.backward")
                }
            }
            if discard != nil {
                Divider()
                Button(role: .destructive) { confirmsDiscard = true } label: {
                    Label(L("ask.workflow.chat.discardMenu"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("ask.search.actions"))
        .accessibilityLabel(L("ask.search.actions"))
        .accessibilityIdentifier("ask.workflow.more")
    }

    private func tabButton(_ value: Tab, title: String, count: Int? = nil) -> some View {
        Button { chosenTab = value } label: {
            HStack(spacing: 4) {
                Text(title)
                if let count {
                    Text(String(count))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tab == value ? StudioTheme.textPrimary : StudioTheme.textTertiary)
            .padding(.bottom, 9)
            .overlay(alignment: .bottom) {
                if tab == value {
                    Capsule().fill(AskTheme.accent).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? [.isSelected] : [])
        .accessibilityIdentifier(value == .test ? "ask.workflow.tab.test" : "ask.workflow.tab.code")
    }

    // MARK: Checklist

    private func checklistSection(_ checklist: AskWorkflowChecklist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("ask.workflow.chat.check.title"))
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    AskWorkflowProgressRing(done: checklist.completed, total: checklist.rows.count)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("ask.workflow.chat.check.remaining", checklist.missing))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                        Text(L("ask.workflow.chat.check.subtitle"))
                            .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                ForEach(checklist.rows, id: \.item) { row in
                    Rectangle().fill(AskTheme.separator).frame(height: 1)
                    checklistRow(row)
                }
                if complete != nil {
                    Rectangle().fill(AskTheme.separator).frame(height: 1)
                    HStack(spacing: 10) {
                        Text(L(completing ? "ask.workflow.chat.completing"
                                : (canComplete ? "ask.workflow.chat.completeHint" : "ask.workflow.chat.completeBlocked")))
                            .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { complete?(checklist.completionRequest) } label: {
                            HStack(spacing: 6) {
                                if completing {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                                }
                                Text(L("ask.workflow.chat.complete"))
                            }
                        }
                        .buttonStyle(AskCapsuleButtonStyle())
                        .disabled(completing || !canComplete)
                        .accessibilityIdentifier("ask.workflow.complete")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AskTheme.panelCard.opacity(0.6))
                }
            }
            .background(AskTheme.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func checklistRow(_ row: AskWorkflowChecklist.Row) -> some View {
        HStack(spacing: 10) {
            Group {
                if row.isComplete {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioTheme.success)
                        .background(Circle().fill(AskTheme.successSoft).frame(width: 18, height: 18))
                } else {
                    Text(verbatim: "!").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StudioTheme.warning)
                        .background(Circle().fill(AskTheme.warningSoft).frame(width: 18, height: 18))
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(row.item.titleKey)).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textPrimary)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !row.isComplete, row.item == .keywords {
                Button(L("ask.workflow.chat.check.addManually")) { openEditor(AskWorkflowManifest.fileName) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AskTheme.accentText)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: Test run

    private func testSection(_ checklist: AskWorkflowChecklist) -> some View {
        let ready = checklist.isComplete
        let keywords = session.draft.manifest?.keywords ?? []
        let takesSelection = session.draft.manifest?.input.selection != .never
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(L("ask.workflow.chat.tab.test"))
                Spacer()
                if !ready {
                    Text(L("ask.workflow.chat.afterComplete")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
            }
            if ready, !keywords.isEmpty {
                AskWorkflowKeywordChips(keywords: keywords, selection: $session.keyword)
            }
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if session.query.isEmpty {
                        Text(L(ready ? "ask.workflow.chat.inputPlaceholder" : "ask.workflow.chat.inputLocked"))
                            .font(.system(size: 13.5)).foregroundStyle(StudioTheme.textTertiary)
                            .padding(.horizontal, 13).padding(.top, 11)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $session.query)
                        .font(.system(size: 13.5))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 8).padding(.top, 11)
                        .frame(minHeight: 76)
                        .focused($inputFocused)
                        .accessibilityLabel(L("ask.workflow.chat.input"))
                }
                if showsSelection, takesSelection {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.cursor").font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textTertiary).padding(.top, 2)
                        TextEditor(text: $session.selection)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 34, maxHeight: 90)
                            .accessibilityLabel(L("ask.workflow.chat.selection"))
                        Button { showsSelection = false; session.selection = "" } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                        .accessibilityLabel(L("ask.artifact.close"))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 10)
                }
                HStack(spacing: 8) {
                    if takesSelection, !showsSelection {
                        Button { showsSelection = true } label: {
                            Label(L("ask.workflow.chat.selection"), systemImage: "plus")
                                .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    runButton(ready: ready)
                }
                .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 8)
            }
            .background(AskTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(inputFocused ? AskTheme.accent : AskTheme.border, lineWidth: inputFocused ? 1.5 : 1))
            .disabled(!ready)
            .opacity(ready ? 1 : 0.55)
            Label(L("ask.workflow.chat.actionsPreview"), systemImage: "checkmark.shield")
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
        }
    }

    @ViewBuilder private func runButton(ready: Bool) -> some View {
        if session.isRunning {
            Button { testTask?.cancel(); session.cancel() } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("ask.workflow.chat.cancel"))
                }
            }
            .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
        } else {
            Button { requestRun() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text(L("ask.workflow.chat.run"))
                    Text(verbatim: "⌘↵").font(.system(size: 10.5, design: .monospaced)).opacity(0.75)
                }
            }
            .buttonStyle(AskCapsuleButtonStyle())
            // Only while typing the test input: an approval card in the transcript
            // answers Command-Return too, and must never be pressed by mistake.
            .modifier(AskWorkflowRunShortcut(enabled: inputFocused))
            .disabled(!ready)
            .accessibilityIdentifier("ask.workflow.run")
        }
    }

    private func requestRun() {
        guard session.problems.isEmpty, !session.isRunning else { return }
        approvedRevision = session.revision
        confirmsRun = true
    }

    // MARK: Result

    private func resultSection(_ checklist: AskWorkflowChecklist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("ask.workflow.chat.result"))
            if session.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("ask.workflow.chat.running")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(AskTheme.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
            } else if let preview = session.currentPreview {
                previewResult(preview)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 14))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 9))
                    Text(L(checklist.isComplete ? "ask.workflow.chat.empty" : "ask.workflow.chat.emptyLocked"))
                        .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AskTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }

    private func previewResult(_ preview: AskWorkflowAuthoringSession.Preview) -> some View {
        let result = preview.result
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: result.succeeded ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(L(result.succeeded ? "ask.workflow.chat.resultOK" : "ask.workflow.chat.resultFailed"))
                    .fontWeight(.medium)
                Text(verbatim: "· " + String(format: "%.1fs", result.duration) + " · "
                     + L("ask.workflow.chat.exitCode", Int(result.exitCode)))
                    .foregroundStyle(StudioTheme.textTertiary)
                Spacer(minLength: 0)
                Text(L("ask.workflow.chat.launcherPreview")).foregroundStyle(StudioTheme.textTertiary)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(result.succeeded ? StudioTheme.success : StudioTheme.warning)
            .padding(.horizontal, 12).padding(.vertical, 9)
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            AskWorkflowLauncherPreview(name: preview.manifest.name,
                keyword: result.input.keyword ?? preview.manifest.keywords.first?.keyword ?? "",
                query: result.input.query, result: result, output: preview.manifest.output,
                timeout: preview.manifest.timeout, showsInput: false, folder: preview.folder)
            if !result.actionSteps.isEmpty {
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("ask.workflow.chat.actionsPreview")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(result.actionSteps.enumerated()), id: \.offset) { _, step in
                        Label(step.title + ": " + step.detail, systemImage: step.symbol)
                            .font(.caption).textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            DisclosureGroup {
                Text(Self.log(result))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Text(L("ask.workflow.chat.log")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(AskTheme.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The run log: the arguments it got, then what it wrote to stderr.
    static func log(_ result: AskWorkflowTestResult) -> String {
        var lines = ["$ " + (result.arguments.isEmpty ? "run" : result.arguments.joined(separator: " "))]
        if let failure = result.failure { lines.append(failure) }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(stderr.isEmpty ? L("ask.workflow.chat.logEmpty") : stderr)
        return lines.joined(separator: "\n")
    }

    // MARK: Code

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle(L("ask.workflow.chat.files"))
                    Spacer()
                    Text(L("ask.workflow.chat.readOnly")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(session.draft.paths.enumerated()), id: \.element) { index, file in
                        if index > 0 { Rectangle().fill(AskTheme.separator).frame(height: 1) }
                        Button { previewPath = file } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").font(.system(size: 13))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                Text(file).font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(L("ask.workflow.chat.lines", Self.lineCount(session.draft.text(of: file))))
                                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(file == previewPath ? AskTheme.accentSoft : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(AskTheme.panelCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(previewPath)
                ScrollView([.horizontal, .vertical]) {
                    Text(session.draft.text(of: previewPath) ?? "")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .background(AskTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.border))
            }
            Button { openEditor(previewPath) } label: {
                Label(L("ask.workflow.chat.openEditor"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(AskCapsuleButtonStyle(kind: .secondary, expands: true))
        }
        .onAppear {
            if !session.draft.paths.contains(previewPath) { previewPath = AskWorkflowManifest.fileName }
        }
    }

    static func lineCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
            - (text.hasSuffix("\n") ? 1 : 0)
    }

    private func openEditor(_ file: String) {
        path = session.draft.paths.contains(file) ? file : AskWorkflowManifest.fileName
        showsCode = true
    }

    // MARK: Footer

    private func footer(status: AskWorkflowDraftStatus) -> some View {
        let hint = AskWorkflowSaveHint.resolve(status: status, isRunning: session.isRunning,
                                               lastResult: session.currentPreview?.result,
                                               keyword: session.draft.manifest?.keywords.first?.keyword)
        return VStack(spacing: 8) {
            Button {
                do { try session.save() } catch { session.message = error.localizedDescription }
            } label: {
                HStack(spacing: 6) {
                    if status == .saved { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                    Text(L(status == .saved ? "ask.workflow.chat.saved" : "ask.workflow.chat.save"))
                }
            }
            .buttonStyle(AskCapsuleButtonStyle(expands: true))
            .disabled(!hint.allowsSave)
            .accessibilityIdentifier("ask.workflow.save")
            HStack(spacing: 5) {
                if hint.isPositive { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(hint.text)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(hint.isPositive ? StudioTheme.success : StudioTheme.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("ask.workflow.saveHint")
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
    }

    /// Uses the workflow editor's syntax-aware native code component against the
    /// same draft. Closing returns to Chat without saving or making a second copy.
    private var codeEditor: some View {
        VStack(spacing: 12) {
            HStack {
                Picker(L("ask.workflow.chat.advanced"), selection: $path) {
                    ForEach(session.draft.paths, id: \.self) { Text($0).tag($0) }
                }
                Button(L("ask.workflow.chat.back")) { showsCode = false }
            }
            AskWorkflowCodeView(text: Binding(get: { session.draft.text(of: path) ?? "" },
                set: { session.edit(text: $0, path: path) }), language: .detect(path: path))
                .id(path)
            Text(L("ask.workflow.chat.editNotice")).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 660, minHeight: 460)
    }
}

private struct AskWorkflowRunShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.return, modifiers: .command) } else { content }
    }
}

/// The draft's state as a small capsule.
struct AskWorkflowStatusChip: View {
    let status: AskWorkflowDraftStatus
    /// The card's label ("Incomplete · 2 missing") rather than the panel's badge.
    var long = false

    var body: some View {
        Text(long ? status.cardLabel : status.badge)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(background, in: Capsule())
            .fixedSize()
    }

    private var foreground: Color {
        switch status {
        case .incomplete: StudioTheme.warning
        case .draft: StudioTheme.textSecondary
        case .saved: StudioTheme.success
        }
    }

    private var background: Color {
        switch status {
        case .incomplete: AskTheme.warningSoft
        case .draft: AskTheme.controlSurface
        case .saved: AskTheme.successSoft
        }
    }
}

struct AskWorkflowToolIcon: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.23, green: 0.63, blue: 1),
                                                Color(red: 0.09, green: 0.41, blue: 0.89)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18)))
            .accessibilityHidden(true)
    }
}

private struct AskWorkflowProgressRing: View {
    let done: Int
    let total: Int

    var body: some View {
        let fraction = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        ZStack {
            Circle().stroke(AskTheme.controlSurface, lineWidth: 3)
            Circle().trim(from: 0, to: fraction)
                .stroke(done == total ? StudioTheme.success : StudioTheme.warning,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(done)/\(total)").font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(StudioTheme.textPrimary)
        }
        .frame(width: 30, height: 30)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "\(done)/\(total)"))
    }
}

/// Keywords as chips: one choice for the test run.
private struct AskWorkflowKeywordChips: View {
    let keywords: [AskWorkflowManifest.Keyword]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keywords, id: \.keyword) { keyword in
                let selected = keyword.keyword == selection
                Button { selection = keyword.keyword } label: {
                    Text(keyword.title ?? keyword.keyword)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(selected ? AskTheme.accentText : StudioTheme.textSecondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(selected ? AskTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? AskTheme.accent : AskTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .accessibilityLabel(L("ask.workflow.chat.keyword"))
    }
}
