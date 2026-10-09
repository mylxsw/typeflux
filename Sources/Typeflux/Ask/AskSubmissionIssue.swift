import SwiftUI

/// A refusal before sending. Its actions fix the input or model configuration.
struct AskSubmissionIssue: Equatable, LocalizedError {
    var text: String
    var offersModels = false
    var offersSignIn = false
    var errorDescription: String? { text }
}

struct AskSubmissionIssueView: View {
    let issue: AskSubmissionIssue
    var onModels: () -> Void
    var onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(issue.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            if issue.offersModels || issue.offersSignIn {
                HStack(spacing: 8) {
                    if issue.offersSignIn {
                        Button(L("ask.submission.signIn"), action: onSignIn)
                            .buttonStyle(AskCapsuleButtonStyle(kind: .primary))
                            .accessibilityIdentifier("ask.submission.signIn")
                    }
                    if issue.offersModels {
                        Button(L("ask.submission.models"), action: onModels)
                            .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                            .accessibilityIdentifier("ask.submission.models")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.warningSoft, in: RoundedRectangle(cornerRadius: 10))
    }
}
