import SwiftUI

/// Generation and image download are different operations; a download retry never creates a job.
enum AskImageCardState: Equatable {
    case hidden, generating, interrupted, failed, ready(AskGeneratedImage)

    static func isImageTool(_ name: String) -> Bool { ["image_generate", "image_edit"].contains(name) }

    static func resolve(result: AskMessage?, status: AskActivity.Status, active: Bool, started: Bool) -> Self {
        if let result {
            if result.isError != true, let image = result.generatedImage,
               AskRemoteImageLoader.eligible(image) != nil { return .ready(image) }
            if let outcome = result.harness?.outcome,
               outcome.safeStatus == .denied || outcome.safeStatus == .invalid || outcome.eventDispatched == false ||
                (outcome.safeStatus == .cancelled && !started && outcome.eventDispatched != true) { return .hidden }
            guard started || result.generatedImage != nil || result.harness?.outcome?.eventDispatched == true else { return .hidden }
            return .failed
        }
        guard started else { return .hidden }
        if !active || status == .paused { return .interrupted }
        return .generating
    }
}

private struct AskEditGeneratedImageKey: EnvironmentKey {
    static let defaultValue: ((AskGeneratedImage) -> Void)? = nil
}
extension EnvironmentValues {
    var askEditGeneratedImage: ((AskGeneratedImage) -> Void)? {
        get { self[AskEditGeneratedImageKey.self] }
        set { self[AskEditGeneratedImageKey.self] = newValue }
    }
}

struct AskImageGenerationCard: View {
    let call: AskToolCall
    let result: AskMessage?
    let status: AskActivity.Status
    let active: Bool
    let startedAt: Date?

    private var state: AskImageCardState { .resolve(result: result, status: status, active: active, started: startedAt != nil) }

    var body: some View {
        Group {
            switch state {
            case .ready(let image): AskRemoteImageView(asset: image)
            case .hidden: EmptyView()
            case .generating:
                let startedAt = startedAt ?? .now
                TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                    AskImagePlaceholder(title: L("ask.image.creating"),
                        detail: L("ask.image.elapsed", max(0, Int(timeline.date.timeIntervalSince(startedAt)))),
                        hint: L("ask.image.waitHint"), spinning: true)
                }
            case .interrupted:
                AskImagePlaceholder(title: L("ask.image.interrupted"), detail: nil,
                                    hint: L("ask.image.interruptedHint"), spinning: false)
            case .failed:
                AskImagePlaceholder(title: L("ask.image.failed"), detail: nil,
                                    hint: L("ask.image.failedHint"), spinning: false)
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
        .padding(.bottom, state == .hidden ? 0 : 10)
        .accessibilityIdentifier("ask.image.card." + call.id)
    }
}

struct AskImagePlaceholder: View {
    let title: String
    let detail: String?
    let hint: String
    let spinning: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(StudioTheme.textPrimary.opacity(0.045))
            VStack(spacing: 14) {
                if spinning { ProgressView().controlSize(.large) }
                else { Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(StudioTheme.textSecondary) }
                Text(title).font(.system(size: 16, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 13)).monospacedDigit().foregroundStyle(StudioTheme.textSecondary) }
                Text(hint).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .multilineTextAlignment(.center).padding(.top, 8)
            }
            .padding(24)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 400)
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.textPrimary.opacity(0.09)))
        .accessibilityElement(children: .combine)
    }
}

/// Session-local display evidence recorded only after dispatch authorization succeeds.
struct AskImageExecutionStart {
    let identity: AskExecutionIdentity
    let date: Date
}
