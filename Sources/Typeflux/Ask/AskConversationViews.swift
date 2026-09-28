import AppKit
import SwiftUI

enum AskTheme {
    static let accent = Color(red: 0.40, green: 0.35, blue: 0.91)
    static func toolTitle(_ call: AskToolCall) -> String {
        let name = call.function.name
        guard name == "computer" || name == "browser" else { return name }
        let action = (try? AskLocalTools.arguments(call.function.arguments)["action"] as? String) ?? ""
        return L("ask.tool." + name) + " · " + L("ask.action." + action)
    }
}

struct AskLauncherView: View {
    @ObservedObject var model: AskConversationModel
    var onVoice: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            AskComposer(model: model, launcher: true, onVoice: onVoice, onDismiss: onDismiss)
            if let message = model.captureWarning ?? model.error {
                AskNotice(text: message)
            }
        }
        .padding(22)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 36).stroke(.primary.opacity(0.12), lineWidth: 1))
        .padding(1)
        .tint(AskTheme.accent)
        .onChange(of: model.launcherDraft) { _ in model.persistDrafts() }
    }
}

struct AskComposer: View {
    @ObservedObject var model: AskConversationModel
    var launcher: Bool
    var onVoice: () -> Void
    var onDismiss: () -> Void = {}
    @State private var showingContext = false

    private var draft: Binding<AskDraft> { launcher ? $model.launcherDraft : $model.draft }
    private var canSend: Bool { launcher ? model.canSendLauncher : model.canSend }
    private func submit() { if launcher { model.submitLauncher() } else { model.submitDraft() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if draft.wrappedValue.text.isEmpty {
                    Text(L(launcher ? "ask.input.placeholder" : "ask.followup.placeholder"))
                        .foregroundStyle(.secondary).padding(.leading, 9).padding(.top, 8)
                }
                AskComposerTextView(text: draft.text, placeholder: L("ask.input.placeholder"), onSubmit: submit, onDismiss: onDismiss)
                    .frame(height: launcher ? 78 : 64)
            }
            HStack(spacing: 12) {
                Toggle(isOn: draft.includeScreenshot) { Text(L("ask.screenshot")) }
                    .toggleStyle(.checkbox)
                    .onChange(of: draft.wrappedValue.includeScreenshot) { included in
                        if included, draft.wrappedValue.screenshot == nil {
                            Task { await model.refreshScreenshot(launcher: launcher) }
                        }
                    }
                if draft.wrappedValue.screenshot != nil || draft.wrappedValue.selection != nil {
                    Button { showingContext.toggle() } label: {
                        Label(draft.wrappedValue.selection == nil ? L("ask.preview") : [L("ask.selection"), draft.wrappedValue.source?.components(separatedBy: " — ").first].compactMap { $0 }.joined(separator: " · "), systemImage: "rectangle.on.rectangle")
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingContext) {
                        AskContextPreview(draft: draft, recapture: { Task { await model.refreshScreenshot(launcher: launcher) } })
                    }
                }
                if model.capturing { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                Button(action: onVoice) { Image(systemName: "mic").font(.system(size: 19)) }
                    .buttonStyle(.plain).help(L("ask.voice"))
                    .accessibilityLabel(L("ask.voice"))
                if !launcher, model.isBusy {
                    Button { model.stop() } label: { Image(systemName: "stop.fill").frame(width: 38, height: 38) }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                        .accessibilityLabel(L("ask.stop"))
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 20, weight: .medium)).frame(width: 40, height: 40) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? Color.white : Color.secondary)
                        .background(canSend ? AskTheme.accent : Color.secondary.opacity(0.15), in: Circle())
                        .disabled(!canSend).accessibilityLabel(L("ask.send"))
                }
            }
            .font(.system(size: 13))
        }
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
    var onVoice: () -> Void
    @State private var deleteId: String?
    @State private var showContext = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 205)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(model.selected?.title ?? L("ask.new")).font(.headline).lineLimit(1)
                    Spacer()
                    Button { showContext.toggle() } label: { Label(L("ask.context"), systemImage: "text.bubble") }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showContext) { contextDetails }
                }.padding(20)
                Divider()
                messages
                if let error = model.error {
                    HStack {
                        AskNotice(text: error)
                        Button(L("ask.retry")) { model.resume() }.disabled(model.isBusy)
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
                AskComposer(model: model, launcher: false, onVoice: onVoice)
                    .padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
                    .padding(20)
            }.frame(minWidth: 480)
        }
        .frame(minWidth: 740, minHeight: 530)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(AskTheme.accent)
        .onChange(of: model.draft) { _ in model.persistDrafts() }
        .confirmationDialog(L("ask.delete.confirm"), isPresented: Binding(get: { deleteId != nil }, set: { if !$0 { deleteId = nil } })) {
            Button(L("ask.delete"), role: .destructive) { if let id = deleteId { Task { await model.delete(id) } }; deleteId = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { model.newConversation() } label: { Label(L("ask.new"), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.bordered).padding(.horizontal, 14).padding(.top, 20)
            HStack { Text(L("ask.history")).font(.caption).foregroundStyle(.secondary); Spacer(); Button { Task { await model.refreshHistory() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help(L("ask.refresh")) }.padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.conversations) { item in
                        Button { Task { await model.select(item.id) } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left")
                                Text(item.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if model.busyIds.contains(item.id) { ProgressView().controlSize(.mini) }
                            }.font(.system(size: 13)).padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selected?.id == item.id ? AskTheme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                            .contextMenu { Button(L("ask.delete"), role: .destructive) { deleteId = item.id }.disabled(model.busyIds.contains(item.id)) }
                    }
                    if model.historyHasMore { Button(L("ask.loadMore")) { Task { await model.refreshHistory(loadMore: true) } } }
                    if model.conversations.isEmpty { Text(L("ask.history.empty")).font(.caption).foregroundStyle(.secondary).padding() }
                }.padding(.horizontal, 8)
            }
        }.background(AskTheme.accent.opacity(0.045))
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if model.selected == nil { Text(L("ask.empty")).font(.title2).foregroundStyle(.secondary).padding(.top, 90).frame(maxWidth: .infinity) }
                    ForEach(model.selected?.messages ?? []) { message in
                        AskMessageView(message: message, allMessages: model.selected?.messages ?? [])
                            .id(message.id)
                    }
                    if let preview = model.selected?.run?.preview, !preview.isEmpty {
                        MarkdownSwiftUIView(markdown: preview).textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(24)
            }
            .onChange(of: model.selected?.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var contextDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ask.context")).font(.headline)
            Text(L("ask.context.history"))
            if let summary = model.selected?.summary {
                Text(L("ask.context.summary")).font(.subheadline.bold())
                ScrollView { Text(summary).textSelection(.enabled) }.frame(maxHeight: 260)
            }
            Text(L("ask.context.newHint")).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 400)
    }

    private func approval(_ call: AskToolCall, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("ask.tool.approval"), systemImage: "hand.raised").font(.headline)
            Text(AskTheme.toolTitle(call)).font(.subheadline.bold())
            if let source = model.selected?.messages.first(where: { $0.role == "user" })?.source {
                Label(source, systemImage: "macwindow").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView { Text(call.function.arguments).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 100)
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
                if message.role == "user" { Spacer(minLength: 60) }
                VStack(alignment: .leading, spacing: 10) {
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
                    if !message.text.isEmpty {
                        MarkdownSwiftUIView(markdown: message.text).textSelection(.enabled)
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
                            Label(AskTheme.toolTitle(call), systemImage: result == nil ? "clock" : (result?.isError == true ? "exclamationmark.circle" : "checkmark.circle"))
                                .font(.system(size: 13)).foregroundStyle(result?.isError == true ? Color.red : Color.secondary)
                        }.padding(10).background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !message.text.isEmpty {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(L("ask.copy"))
                    }
                }.padding(message.role == "user" ? 14 : 0)
                    .background(message.role == "user" ? AskTheme.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                if message.role != "user" { Spacer(minLength: 24) }
            }
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
