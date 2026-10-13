import SwiftUI

/// One complete explanation and one grant action; narrow composers wrap the text.
struct AskScreenshotPermissionNotice: View {
    let text: String
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: TypefluxSpacing.small.value(for: .classic)) {
            Image(systemName: "info.circle").accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ask.screenshot.permission.explanation")
            TypefluxButton(L("ask.context.screen.grant"), kind: .borderless, action: grant)
                .fixedSize()
                .accessibilityIdentifier("ask.screenshot.permission.grant")
        }
        .font(.subheadline)
        .foregroundStyle(TypefluxColor.secondaryLabel.color)
        .accessibilityElement(children: .contain)
    }
}
