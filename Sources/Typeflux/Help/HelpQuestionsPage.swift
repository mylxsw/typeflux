import SwiftUI

/// The permissions at a glance, the questions with the likely ones first, and the AI for the
/// rest. An answer stays folded until asked for.
struct HelpQuestionsPage: View {
    @ObservedObject var model: HelpGuideModel
    @State private var askText = ""
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HelpStatusStrip(model: model)
                    HelpBlock {
                        ForEach(Array(model.orderedQuestions.enumerated()), id: \.element.id) { index, question in
                            questionRow(question, first: index == 0).id(question.id)
                        }
                    }
                    askField
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .onAppear { if let id = model.openQuestionID { proxy.scrollTo(id) } }
        }
    }

    private func questionRow(_ question: HelpQuestion, first: Bool) -> some View {
        let open = model.openQuestionID == question.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.toggleQuestion(question.id) }
            } label: {
                HStack(spacing: 10) {
                    Text(question.question).font(.system(size: 13.5)).lineLimit(1)
                    if model.isRelevant(question) {
                        Circle().fill(StudioTheme.warning).frame(width: 7, height: 7)
                            .help(L("help.faq.relevant"))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(question.answer)
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let permission = question.permission, model.missingPermissions.contains(where: { $0.id == permission }) {
                    HelpButton(title: L("help.faq.fix"), prominent: true) { model.fix(permission) }
                }
                if let destination = question.destination {
                    HelpButton(title: L("help.faq.openSettings")) { model.openSettings(destination) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var askField: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(StudioTheme.aiIcon)
                .accessibilityHidden(true)
            TextField(L("help.faq.stuck.placeholder"), text: $askText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { model.askAI(askText) }
            HelpButton(title: L("help.search.askAI"), prominent: true) { model.askAI(askText) }
                .disabled(askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
    }
}

/// Each permission and whether it is allowed; what it is for is its tooltip.
struct HelpStatusStrip: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        if !model.permissions.isEmpty {
            HelpFlowLayout(spacing: 18) {
                ForEach(model.permissions) { permission in
                    HStack(spacing: 7) {
                        Circle().fill(permission.granted ? StudioTheme.success : StudioTheme.warning)
                            .frame(width: 7, height: 7)
                        Text(permission.title).font(.system(size: 13))
                        if !permission.granted {
                            HelpButton(title: L("help.faq.fix"), prominent: true) { model.fix(permission.id) }
                        }
                    }
                    .fixedSize()
                    .frame(height: 28)
                    .help(permission.detail)
                    .accessibilityElement(children: .contain)
                    .accessibilityValue(L(permission.granted ? "help.faq.granted" : "help.faq.notGranted"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(HelpTheme.blockFill(style)))
            .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
        }
    }
}
