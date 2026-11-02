import SwiftUI

/// Whether Typeflux has what it needs comes first, then the questions by topic, with the ones
/// a missing permission explains on top; a last resort asks the AI or gives feedback.
struct HelpQuestionsPage: View {
    @ObservedObject var model: HelpGuideModel
    @State private var askText = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HelpStatusCard(model: model)
                    topics.padding(.top, 20).padding(.bottom, 12)
                    HelpBlock {
                        ForEach(Array(model.visibleQuestions.enumerated()), id: \.element.id) { index, question in
                            questionRow(question, first: index == 0).id(question.id)
                        }
                    }
                    stuck.padding(.top, 20)
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .onAppear { if let id = model.openQuestionID { proxy.scrollTo(id) } }
        }
    }

    private var topics: some View {
        HelpFlowLayout(spacing: 6) {
            HelpFilterChip(title: L("help.group.all"), selected: model.questionTopic == nil) {
                model.setQuestionTopic(nil)
            }
            ForEach(HelpQuestionTopic.allCases) { topic in
                HelpFilterChip(title: topic.title,
                               count: model.catalog.questions.filter { $0.topic == topic }.count,
                               selected: model.questionTopic == topic) { model.setQuestionTopic(topic) }
            }
        }
    }

    private func questionRow(_ question: HelpQuestion, first: Bool) -> some View {
        let open = model.openQuestionID == question.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.toggleQuestion(question.id) }
            } label: {
                HStack(spacing: 12) {
                    HelpSymbolTile(symbol: question.topic.symbol, tint: question.topic.tint, size: 26)
                    Text(question.question).font(.system(size: 13.5)).lineLimit(1)
                    if model.isRelevant(question) {
                        Text(L("help.faq.relevant"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().fill(StudioTheme.warning))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(question.question)
            .accessibilityValue(model.isRelevant(question) ? L("help.faq.relevant") : "")
            .overlay(alignment: .top) {
                if !first { Rectangle().fill(AskTheme.separator).frame(height: 1) }
            }
            if open { answer(question) }
        }
    }

    private func answer(_ question: HelpQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let steps = question.steps
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(AskTheme.hoverFill))
                    Text(step)
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                if let permission = question.permission, model.missingPermissions.contains(where: { $0.id == permission }) {
                    HelpButton(title: L("help.faq.fix"), prominent: true) { model.fix(permission) }
                }
                if let destination = question.destination {
                    HelpButton(title: L("help.faq.openSettings")) { model.openSettings(destination) }
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, 52)
        .padding(.trailing, 18)
        .padding(.bottom, 14)
    }

    private var stuck: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                stuckTitle
                Spacer(minLength: 0)
                askField.frame(width: 300)
                feedback
            }
            VStack(alignment: .leading, spacing: 10) {
                stuckTitle
                HStack(spacing: 10) {
                    askField
                    feedback
                }
            }
        }
        .padding(14)
        .background(LinearGradient(colors: [HelpCoreAction.chat.tint.opacity(0.14), .clear],
                                   startPoint: .leading, endPoint: .trailing).clipShape(shape))
        .overlay(shape.strokeBorder(AskTheme.border))
    }

    private var stuckTitle: some View {
        HStack(spacing: 12) {
            HelpSymbolTile(symbol: "sparkles", tint: HelpCoreAction.chat.tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("help.faq.stuck.title")).font(.system(size: 13.5, weight: .semibold)).fixedSize()
                Text(L("help.faq.stuck.detail")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize()
            }
        }
    }

    private var askField: some View {
        HStack(spacing: 8) {
            TextField(L("help.faq.stuck.placeholder"), text: $askText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit { model.askAI(askText) }
            HelpButton(title: L("help.search.askAI"), prominent: true) { model.askAI(askText) }
                .disabled(askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AskTheme.hoverFill))
    }

    private var feedback: some View {
        Menu {
            HelpFeedbackOptions(model: model)
        } label: {
            Text(L("help.link.feedback")).font(.system(size: 12.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L("help.link.feedback"))
    }
}

/// Everything a permission can get in the way of, summed up beside each permission's state.
struct HelpStatusCard: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let missing = model.missingPermissions.count
        let tint = missing > 0 ? StudioTheme.warning : StudioTheme.success
        let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 16 : style.help.blockCorner, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HelpSymbolTile(symbol: missing > 0 ? "exclamationmark.triangle" : "checkmark.shield",
                               tint: tint, size: 42)
                    .padding(.bottom, 10)
                Text(missing > 0 ? L("help.faq.attention.title", missing) : L("help.faq.ready.title"))
                    .font(.system(size: 17, weight: .semibold))
                Text(L(missing > 0 ? "help.faq.attention.detail" : "help.faq.ready.detail"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(width: 230, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(RadialGradient(colors: [tint.opacity(0.24), .clear], center: .topLeading,
                                       startRadius: 0, endRadius: 240))
            Rectangle().fill(AskTheme.separator).frame(width: 1)
            VStack(spacing: 0) {
                ForEach(Array(model.permissions.enumerated()), id: \.element.id) { index, permission in
                    row(permission, first: index == 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
    }

    private func row(_ permission: HelpPermissionStatus, first: Bool) -> some View {
        let tint = permission.granted ? StudioTheme.success : StudioTheme.warning
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13))
                if !permission.detail.isEmpty {
                    Text(permission.detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(L(permission.granted ? "help.faq.granted" : "help.faq.notGranted"))
                .font(.system(size: 12))
                .foregroundStyle(permission.granted ? StudioTheme.textSecondary : StudioTheme.warning)
                .fixedSize()
            if !permission.granted {
                HelpButton(title: L("help.faq.fix"), prominent: true) { model.fix(permission.id) }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(AskTheme.separator).frame(height: 1) }
        }
    }
}
