import SwiftUI

struct AskQuickAskView: View {
    @ObservedObject var model: AskConversationModel
    @ObservedObject var viewport: AskLauncherViewport
    var chrome: CGFloat
    var available: CGFloat?
    var natural: CGFloat
    var onSubmit: () -> Void
    @State private var followsBottom = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.modelLibrary.name(for: model.quickAskConversation?.modelRef ?? model.modelReference(launcher: true)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let quick = model.quickAsk, quick.owner == model.session()?.owner {
                Text(quick.submitted.text).font(.system(size: 13, weight: .medium))
                    .lineLimit(2).textSelection(.enabled)
            }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.quickAskAnswer.isEmpty {
                                Text(L(model.quickAskRunning ? "ask.quickAsk.thinking" : "ask.quickAsk.placeholder"))
                                    .foregroundStyle(.secondary)
                            } else {
                                AskTranscriptText(text: model.quickAskAnswer, onSaveNote: nil)
                            }
                            Color.clear.frame(height: 1).id("quickAskBottom")
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: AskQuickAskBottom.self,
                                                           value: geometry.frame(in: .named("quickAskScroll")).maxY)
                                })
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: "quickAskScroll")
                    .onPreferenceChange(AskQuickAskBottom.self) { bottom in
                        followsBottom = bottom <= viewport.size.height + 30
                    }
                    .onChange(of: model.quickAskAnswer) { _ in
                        if followsBottom { proxy.scrollTo("quickAskBottom", anchor: .bottom) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsBottom {
                            Button { followsBottom = true; proxy.scrollTo("quickAskBottom", anchor: .bottom) } label: {
                                Label(L("ask.quickAsk.bottom"), systemImage: "arrow.down")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if let error = model.quickAskError {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if model.quickAskRunning {
                    ProgressView().controlSize(.small)
                    Button(L("ask.quickAsk.stop")) { model.stopQuickAsk() }
                        .accessibilityIdentifier("ask.quickAsk.stop")
                } else if !model.quickAskAnswer.isEmpty {
                    Button(L("ask.quickAsk.copy")) { model.copyPluginText(model.quickAskAnswer) }
                        .accessibilityIdentifier("ask.quickAsk.copy")
                    Button(L("ask.quickAsk.followUp")) {
                        Task { await model.openQuickAskInChat(focusComposer: true) }
                    }
                    .accessibilityIdentifier("ask.quickAsk.followUp")
                    .disabled(model.quickAsk?.persisted != true || model.isOpeningChat)
                }
                Spacer(minLength: 0)
                Button(L("ask.quickAsk.open")) { Task { await model.openChatFromLauncher() } }
                    .accessibilityIdentifier("ask.quickAsk.open")
                    .disabled(!model.canOpenChatFromLauncher || (model.quickAsk?.conversationId != nil && model.quickAsk?.persisted != true))
                if model.quickAsk?.conversationId != nil {
                    Button(L("ask.quickAsk.new")) { model.newQuickAskQuestion() }
                        .accessibilityIdentifier("ask.quickAsk.new")
                        .disabled(model.quickAskRunning || model.isOpeningChat)
                } else {
                    Button(L("ask.quickAsk.send"), action: onSubmit)
                        .accessibilityIdentifier("ask.quickAsk.send")
                        .disabled(!model.canSubmitQuickAsk)
                }
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(height: max(120, viewport.resultsHeight(chrome: chrome, available: available, natural: natural)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.quickAsk.panel")
    }
}

private struct AskQuickAskBottom: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
