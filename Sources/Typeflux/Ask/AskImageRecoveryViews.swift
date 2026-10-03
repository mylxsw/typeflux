import AppKit
import SwiftUI

/// The saved-screenshot card above the workspace composer.
///
/// One row in the composer's column: the screenshot itself (a thumbnail that
/// opens the preview), what happened and what to do next, then a single
/// primary action. It used to be a full-width block with a stock prominent
/// button and a bare "Preview" link, wider than the composer it belongs to.
struct AskImageRecoveryCard: View {
    @ObservedObject var model: AskConversationModel
    let target: AskImageRecoveryTarget
    @State private var choosingModel = false
    @State private var previewing = false
    /// Decoded once per screenshot; the card re-renders while a resume streams.
    @State private var thumbnail: NSImage?

    private var busy: Bool { model.recoveringImage == target }
    private var reference: String { model.modelReference(launcher: false) }
    private var modelName: String { model.modelLibrary.name(for: reference) }
    private var screenshot: AskMessage? { model.selected?.messages.last(where: { $0.image != nil }) }

    private var copy: AskImageRecoveryCopy {
        AskImageRecoveryCopy(busy: busy, canResume: model.canResumeImage,
                             capability: model.screenshotCapability(launcher: false), modelName: modelName)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            previewButton
            VStack(alignment: .leading, spacing: 3) {
                Text(copy.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(copy.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary)
                if !busy, let error = model.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
                }
            }
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            } else {
                primaryAction
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: AskMetrics.recoveryCardCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AskMetrics.recoveryCardCorner, style: .continuous)
            .strokeBorder(AskTheme.border))
        .task(id: screenshot?.id) { thumbnail = screenshot?.image.flatMap(AskImage.decode) }
    }

    /// The screenshot is the subject of the card, so it is shown, not described;
    /// clicking it replaces the separate text link.
    private var previewButton: some View {
        Button { previewing = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AskTheme.accentText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AskTheme.accentSoft)
                    }
                }
                .frame(width: AskMetrics.recoveryThumbnail.width, height: AskMetrics.recoveryThumbnail.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AskTheme.border))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(AskTheme.raisedSurface, in: Circle())
                    .overlay(Circle().strokeBorder(AskTheme.border))
                    .offset(x: 4, y: 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("ask.preview"))
        .help(L("ask.preview"))
        .popover(isPresented: $previewing) {
            VStack(alignment: .leading, spacing: 8) {
                if let shot = screenshot, let image = thumbnail {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 300)
                    Text(shot.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                } else { Text(L("ask.image.previewUnavailable")) }
            }.padding(12)
        }
    }

    private var primaryAction: some View {
        let resumable = model.canResumeImage
        return Button {
            if resumable { model.resumeImage(target, reference: reference) } else { choosingModel = true }
        } label: {
            HStack(spacing: 6) {
                Text(resumable ? L("ask.image.continue", modelName) : L("ask.image.choose"))
                Image(systemName: resumable ? "arrow.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .buttonStyle(AskCapsuleButtonStyle())
        .disabled(model.isBusy || model.isLoadingSelection)
        .popover(isPresented: $choosingModel) {
            AskImageRecoveryPicker(model: model, target: target) { choosingModel = false }
        }
    }
}

/// Wording for the saved-screenshot card, kept apart from the view so each
/// state can be unit tested.
///
/// The title used to say "choose another model" even after a model that can
/// read images was already selected, contradicting the line beneath it.
struct AskImageRecoveryCopy: Equatable {
    var busy: Bool
    var canResume: Bool
    var capability: AskImageCapability
    var modelName: String

    var title: String {
        if busy { return L("ask.image.resuming") }
        return L(canResume ? "ask.image.savedReady" : "ask.image.saved")
    }

    var detail: String {
        if busy { return L("ask.image.processing", modelName) }
        if canResume { return L("ask.image.ready") }
        switch capability {
        case .unsupported: return L("ask.image.recoveryHint")
        case .unknown: return L("ask.image.unknown")
        case .untested: return L("ask.image.untested")
        case .unavailable, .supported: return L("ask.models.unavailable")
        }
    }
}
