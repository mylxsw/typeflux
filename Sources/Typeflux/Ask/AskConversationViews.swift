import AppKit
import SwiftUI

enum AskTheme {
    static let accent = StudioTheme.accent
    // Standalone windows need solid backplates. StudioTheme's translucent
    // surfaces are intended for layering inside an already-backed container.
    static let surface = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0.995, alpha: 1),
        dark: NSColor(calibratedWhite: 0.128, alpha: 1)
    )
    static let sidebarSurface = StudioTheme.dynamic(
        light: NSColor(calibratedRed: 0.955, green: 0.965, blue: 0.982, alpha: 1),
        dark: NSColor(calibratedWhite: 0.180, alpha: 1)
    )
    static func toolTitle(_ call: AskToolCall) -> String {
        let name = call.function.name
        guard name == "computer" || name == "browser" else { return name }
        let action = (try? AskLocalTools.arguments(call.function.arguments)["action"] as? String) ?? ""
        return L("ask.tool." + name) + " · " + L("ask.action." + action)
    }
}

struct AskLauncherView: View {
    @ObservedObject var model: AskConversationModel
    var onDismiss: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        AskComposer(model: model, launcher: true, onDismiss: onDismiss, onHeightChange: onHeightChange)
        .padding(14)
        .background(AskTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .modifier(AskVoiceBorder(voice: model.voiceInput, context: "launcher", radius: 14))
        .padding(6)
        .tint(AskTheme.accent)
        .onChange(of: model.launcherDraft) { _ in model.persistDrafts() }
    }
}

struct AskComposer: View {
    @ObservedObject var model: AskConversationModel
    var launcher: Bool
    var onDismiss: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @ObservedObject private var voice: AskVoiceInput
    init(model: AskConversationModel, launcher: Bool, onDismiss: @escaping () -> Void = {}, onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model; self.launcher = launcher
        self.onDismiss = onDismiss; self.onHeightChange = onHeightChange
        self.voice = model.voiceInput
    }
    private var contextID: String { launcher ? "launcher" : "chat:" + (model.selectedId ?? "new") }
    private var active: Bool { voice.context == contextID && voice.isActive }
    @State private var showingContext = false
    @State private var editorHeight: CGFloat = 32

    private var draft: Binding<AskDraft> { launcher ? $model.launcherDraft : $model.draft }
    private var canSend: Bool { launcher ? model.canSendLauncher : model.canSend }
    private func submit() { if launcher { model.submitLauncher() } else { model.submitDraft() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draft.wrappedValue.text.isEmpty {
                    Text(L(launcher ? "ask.input.placeholder" : "ask.followup.placeholder"))
                        .foregroundStyle(.secondary).padding(.leading, 5).padding(.top, 4)
                        .allowsHitTesting(false)
                }
                AskComposerTextView(text: draft.text, placeholder: L("ask.input.placeholder"), voice: voice, contextID: contextID, onSubmit: submit, onDismiss: onDismiss, onHeightChange: { editorHeight = $0 })
                    .frame(height: editorHeight)
                    .disabled(!launcher && model.isLoadingSelection)
            }
            HStack(spacing: 8) {
                Toggle(isOn: draft.includeScreenshot) { Text(L("ask.screenshot")) }
                    .toggleStyle(.checkbox)
                    .onChange(of: draft.wrappedValue.includeScreenshot) { included in
                        if included, draft.wrappedValue.screenshot == nil {
                            Task { await model.refreshScreenshot(launcher: launcher) }
                        }
                    }
                if draft.wrappedValue.includeScreenshot, draft.wrappedValue.screenshot == nil, let warning = model.captureWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(StudioTheme.warning)
                        Button(L(warning == L("ask.capture.permission") ? "ask.capture.settings" : "ask.capture.retry")) {
                            if warning == L("ask.capture.permission") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            } else { Task { await model.refreshScreenshot(launcher: launcher) } }
                        }.buttonStyle(.borderless)
                    }.font(.system(size: 11)).lineLimit(1).help(warning)
                }
                if draft.wrappedValue.screenshot != nil || draft.wrappedValue.selection != nil {
                    HStack(spacing: 6) {
                        Button { showingContext.toggle() } label: {
                            Label(draft.wrappedValue.selection == nil ? L("ask.preview") : L("ask.selection"), systemImage: "doc.text")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingContext) {
                            AskContextPreview(draft: draft, recapture: { Task { await model.refreshScreenshot(launcher: launcher) } })
                        }
                        if draft.wrappedValue.selection != nil {
                            Button { draft.wrappedValue.selection = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).help(L("ask.selection.remove")).accessibilityLabel(L("ask.selection.remove"))
                        }
                    }.foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(StudioTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 6))
                }
                if model.capturing { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                if active {
                    if voice.phase == .listening {
                        Circle().fill(AskTheme.accent).frame(width: 5, height: 5)
                        Text(L("ask.voice.listening")).foregroundStyle(AskTheme.accent)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(L("ask.voice.transcribing")).foregroundStyle(AskTheme.accent.opacity(0.8))
                    }
                }
                if !launcher, model.isBusy {
                    Button { model.stop() } label: { Image(systemName: "stop.fill").frame(width: 30, height: 30) }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                        .accessibilityLabel(L("ask.stop"))
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? Color.white : Color.secondary)
                        .background(canSend ? AskTheme.accent : Color.secondary.opacity(0.15), in: Circle())
                        .disabled(!canSend).accessibilityLabel(L("ask.send"))
                }
            }
            .font(.system(size: 12))
            if let error = voice.error { AskNotice(text: error).lineLimit(2) }
            if launcher, let error = model.error { AskNotice(text: error).lineLimit(2) }
        }
        .font(.system(size: 14))
        .onChange(of: editorHeight) { _ in reportHeight() }
        .onChange(of: model.error) { _ in reportHeight() }
        .onChange(of: voice.error) { _ in reportHeight() }
        .onAppear { reportHeight() }
    }

    private func reportHeight() {
        onHeightChange(editorHeight + 78 + (launcher && model.error != nil ? 32 : 0) + (voice.error != nil ? 32 : 0))
    }
}

private struct AskContextPreview: View {
    @Binding var draft: AskDraft
    var recapture: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("ask.context")).font(.headline)
            if let source = draft.source { Text(source).foregroundStyle(.secondary).lineLimit(2) }
            if let date = draft.capturedAt { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
            if let dataURL = draft.screenshot, let image = AskImage.decode(dataURL) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                HStack {
                    Button(L("ask.capture.refresh"), action: recapture)
                    Button(L("ask.remove")) { draft.screenshot = nil; draft.includeScreenshot = false }
                }
            }
            if let text = draft.selection {
                ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                Button(L("ask.selection.remove")) { draft.selection = nil }
            }
            Text(L("ask.context.notice")).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 420)
    }
}

enum AskImage {
    static func decode(_ value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

struct AskConversationView: View {
    @ObservedObject var model: AskConversationModel
    @State private var deleteId: String?
    @State private var pullDistance: CGFloat = 0
    @State private var restoredTranscript: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: StudioTheme.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(model.selected?.title ?? model.conversations.first(where: { $0.id == model.selectedId })?.title ?? L("ask.new")).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if model.isLoadingSelection, model.selected != nil { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 24).frame(height: 52)
                Divider()
                messages
                if let error = model.error {
                    HStack {
                        AskNotice(text: error)
                        Button(L("ask.retry")) { if model.selectionLoadFailed { model.retrySelection() } else { model.resume() } }.disabled(model.isBusy || model.isLoadingSelection)
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(.horizontal, 20).padding(.bottom, 8)
                }
                if let id = model.selected?.id, let call = model.pendingApprovals[id] {
                    approval(call, id: id)
                }
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small); Text(L("ask.working")).font(.caption).foregroundStyle(.secondary) }
                    else if let run = model.selected?.run, run.status == "failed" || run.status == "cancelled" {
                        Text(run.error ?? L("ask.cancelled")).font(.caption).foregroundStyle(.secondary)
                        Button(L("ask.retry")) { model.resume() }
                    }
                    if model.selected?.run == nil, model.selected?.messages.last?.role == "user", !model.isBusy {
                        Button(L("ask.resume")) { model.resume() }
                    }
                    if model.selected?.run?.isActive == true, let id = model.selected?.id, !model.busyIds.contains(id) {
                        Button(L("ask.resume")) { model.resume() }
                    }
                    Spacer()
                }.padding(.horizontal, 24)
                AskComposer(model: model, launcher: false)
                    .disabled(model.isLoadingSelection)
                    .padding(12).background(AskTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .modifier(AskVoiceBorder(voice: model.voiceInput, context: "chat:" + (model.selectedId ?? "new"), radius: 12))
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
            }.frame(minWidth: 480)
        }
        .frame(minWidth: 740, minHeight: 530)
        .background(AskTheme.surface)
        .tint(AskTheme.accent)
        .onChange(of: model.draft) { _ in model.persistDrafts() }
        .confirmationDialog(L("ask.delete.confirm"), isPresented: Binding(get: { deleteId != nil }, set: { if !$0 { deleteId = nil } })) {
            Button(L("ask.delete"), role: .destructive) { if let id = deleteId { Task { await model.delete(id) } }; deleteId = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("ask.history")).font(.system(size: 13, weight: .medium))
                Spacer()
                Button { model.newConversation() } label: { Image(systemName: "square.and.pencil").font(.system(size: 15)) }
                    .buttonStyle(.plain).help(L("ask.new")).accessibilityLabel(L("ask.new"))
            }.padding(.horizontal, 16).frame(height: 52)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(model.conversations.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || historyGroup(model.conversations[index - 1].updatedAt) != historyGroup(item.updatedAt) {
                            Text(historyGroup(item.updatedAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, index == 0 ? 0 : 12).padding(.bottom, 4)
                        }
                        Button { Task { await model.select(item.id) } } label: {
                            HStack(spacing: 8) {
                                Text(item.title).lineLimit(1)
                                Spacer(minLength: 0)
                                if model.busyIds.contains(item.id) { ProgressView().controlSize(.mini) }
                                else { Text(item.updatedAt, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary) }
                            }.font(.system(size: 13)).padding(.horizontal, 10).frame(height: 38)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedId == item.id ? AskTheme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.selectedId == item.id ? .isSelected : [])
                            .contextMenu { Button(L("ask.delete"), role: .destructive) { deleteId = item.id }.disabled(model.busyIds.contains(item.id)) }
                    }
                    if model.historyHasMore { Button(L("ask.loadMore")) { Task { await model.refreshHistory(loadMore: true) } } }
                    if model.conversations.isEmpty { Text(L("ask.history.empty")).font(.caption).foregroundStyle(.secondary).padding() }
                }.padding(.horizontal, 8)
                    .background(AskHistoryPullRefresh(isRefreshing: model.isRefreshingHistory, onDistance: { pullDistance = $0 }, onRefresh: { Task { await model.pullToRefreshHistory() } }))
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.isRefreshingHistory || pullDistance > 0 || model.historyRefreshError != nil {
                    HStack(spacing: 6) {
                        if model.isRefreshingHistory { ProgressView().controlSize(.mini) }
                        else { Image(systemName: model.historyRefreshError == nil ? "arrow.down" : "exclamationmark.circle") }
                        Text(model.historyRefreshError ?? L(model.isRefreshingHistory ? "ask.history.refreshing" : pullDistance >= AskHistoryPullGesture.threshold ? "ask.history.release" : "ask.history.pull"))
                            .lineLimit(2)
                    }.font(.system(size: 11)).foregroundStyle(AskTheme.accent).padding(8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(AskTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 8).padding(.bottom, 6)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAction(named: Text(L("ask.refresh"))) { Task { await model.pullToRefreshHistory() } }
        }.background(AskTheme.sidebarSurface)
    }

    private func historyGroup(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L("ask.today") }
        if Calendar.current.isDateInYesterday(date) { return L("ask.yesterday") }
        return L("ask.earlier")
    }

    private var messages: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if model.isLoadingSelection && model.selected == nil { ProgressView(L("ask.loading")).controlSize(.small).frame(maxWidth: .infinity).padding(.top, 24) }
                        if model.selectedId == nil { Text(L("ask.empty")).font(.system(size: 16)).foregroundStyle(.secondary).padding(.top, 90).frame(maxWidth: .infinity) }
                        ForEach((model.selected?.messages ?? []).filter { $0.role != "tool" }) { message in
                            AskMessageView(message: message, allMessages: model.selected?.messages ?? [])
                                .id(message.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: AskTranscriptFrames.self, value: [message.id: geometry.frame(in: .named("ask-transcript"))])
                                })
                        }
                        if let preview = model.selected?.run?.preview, !preview.isEmpty {
                            MarkdownSwiftUIView(markdown: preview).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: AskTranscriptFrames.self, value: ["bottom": geometry.frame(in: .named("ask-transcript"))])
                            })
                    }.padding(24)
                }
                .coordinateSpace(name: "ask-transcript")
                .onPreferenceChange(AskTranscriptFrames.self) { frames in
                    guard let id = model.selectedId, restoredTranscript == id else { return }
                    if let bottom = frames["bottom"], bottom.minY <= viewport.size.height + 24 {
                        model.transcriptPositions[id] = "bottom"
                    } else if let first = frames.filter({ $0.key != "bottom" && $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY }) {
                        model.transcriptPositions[id] = first.key
                    }
                }
                .onChange(of: model.selectedId) { _ in restoredTranscript = nil }
                .onChange(of: model.selected?.id) { _ in restoreTranscript(proxy) }
                .onAppear { restoreTranscript(proxy) }
                .onChange(of: model.selected?.run?.preview) { _ in
                    if let id = model.selectedId, restoredTranscript == id, model.transcriptPositions[id] == "bottom" {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: model.selected?.messages.count) { _ in
                    if let id = model.selectedId, restoredTranscript == id, model.transcriptPositions[id] == "bottom" {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func restoreTranscript(_ proxy: ScrollViewProxy) {
        guard let id = model.selected?.id, restoredTranscript != id else { return }
        let anchor = model.transcriptPositions[id] ?? "bottom"
        DispatchQueue.main.async {
            guard model.selectedId == id else { return }
            proxy.scrollTo(anchor, anchor: anchor == "bottom" ? .bottom : .top)
            restoredTranscript = id
        }
    }

    private func approval(_ call: AskToolCall, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("ask.tool.approval"), systemImage: "hand.raised").font(.headline)
            Text(AskTheme.toolTitle(call)).font(.subheadline.bold())
            if let source = model.selected?.messages.first(where: { $0.role == "user" })?.source {
                Label(source, systemImage: "macwindow").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(L("ask.details")) {
                ScrollView { Text(call.function.arguments).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 100)
            }.font(.caption)
            HStack {
                Text(L("ask.tool.approvalHint")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("ask.deny")) { model.approve(conversationId: id, allowed: false) }
                Button(L("ask.allowOnce")) { model.approve(conversationId: id, allowed: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(16).background(AskTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 20)
    }
}

private struct AskMessageView: View {
    let message: AskMessage
    let allMessages: [AskMessage]
    @State private var showImage = false
    var body: some View {
        if message.role != "tool" {
            HStack(alignment: .top, spacing: 12) {
                if message.role == "assistant", !message.text.isEmpty {
                    RoundedRectangle(cornerRadius: 2).fill(AskTheme.accent).frame(width: 3)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if !message.text.isEmpty {
                        if message.role == "user" {
                            HStack(alignment: .top, spacing: 12) {
                                Text(L("ask.you")).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 9)
                                .background(StudioTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
                        } else { MarkdownSwiftUIView(markdown: message.text).textSelection(.enabled) }
                    }
                    if message.image != nil || message.selection != nil {
                        DisclosureGroup(L("ask.context")) {
                            if let text = message.selection { Text(text).font(.caption).textSelection(.enabled) }
                            if let source = message.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                            if let url = message.image, let image = AskImage.decode(url) {
                                Button { showImage.toggle() } label: { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 100) }
                                    .buttonStyle(.plain).popover(isPresented: $showImage) { Image(nsImage: image).resizable().scaledToFit().frame(width: 650).padding() }
                            }
                        }.font(.caption)
                    }
                    ForEach(message.toolCalls ?? []) { call in
                        let result = allMessages.first { $0.toolCallId == call.id }
                        DisclosureGroup {
                            Text(call.function.arguments).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            if let result {
                                Text(result.text).font(.system(size: 12)).textSelection(.enabled)
                                if let url = result.image, let image = AskImage.decode(url) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Label(AskTheme.toolTitle(call), systemImage: result == nil ? "clock" : (result?.isError == true ? "exclamationmark.circle" : "checkmark.circle"))
                                Text(L("ask.details")).foregroundStyle(AskTheme.accent)
                            }.font(.system(size: 12)).foregroundStyle(result?.isError == true ? Color.red : Color.secondary)
                        }.padding(10).background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !message.text.isEmpty, message.role != "user" {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(L("ask.copy"))
                    }
                }
                Spacer(minLength: 8)
                Text(message.createdAt, style: .time).font(.system(size: 11)).foregroundStyle(.tertiary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AskNotice: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct AskTranscriptFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Apply voice feedback to the complete card; ordinary focus stays neutral.
private struct AskVoiceBorder: ViewModifier {
    @ObservedObject var voice: AskVoiceInput
    var context: String
    var radius: CGFloat
    private var listening: Bool { voice.context == context && voice.phase == .listening }
    private var active: Bool { voice.context == context && voice.isActive }
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: radius)
            .stroke(listening ? AskTheme.accent : active ? AskTheme.accent.opacity(0.4) : StudioTheme.border, lineWidth: listening ? 1.5 : 1)
            .allowsHitTesting(false))
            .shadow(color: AskTheme.accent.opacity(listening ? 0.22 : 0), radius: 5)
    }
}
