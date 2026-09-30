import SwiftUI

struct AskImageRecoveryCard: View {
    @ObservedObject var model: AskConversationModel
    let target: AskImageRecoveryTarget
    @State private var choosingModel = false
    @State private var previewing = false

    private var busy: Bool { model.recoveringImage == target }
    private var reference: String { model.modelReference(launcher: false) }
    private var screenshot: AskMessage? { model.selected?.messages.last(where: { $0.image != nil }) }

    private var recoveryHint: String {
        if model.canResumeImage { return L("ask.image.ready") }
        switch model.screenshotCapability(launcher: false) {
        case .unsupported: return L("ask.image.recoveryHint")
        case .unknown: return L("ask.image.unknown")
        case .unavailable, .supported: return L("ask.models.unavailable")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "photo.badge.checkmark").foregroundStyle(AskTheme.accent) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(busy ? "ask.image.resuming" : "ask.image.saved"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(busy ? L("ask.image.processing", model.modelLibrary.name(for: reference))
                         : recoveryHint)
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    if !busy, let error = model.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
                    }
                }
            }
            HStack(spacing: 12) {
                if !busy {
                    Button(model.canResumeImage ? L("ask.image.continue", model.modelLibrary.name(for: reference))
                           : L("ask.image.choose")) {
                        if model.canResumeImage { model.resumeImage(target, reference: reference) }
                        else { choosingModel = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.isLoadingSelection)
                    .popover(isPresented: $choosingModel) {
                        AskImageRecoveryPicker(model: model, target: target) { choosingModel = false }
                    }
                }
                Button(L("ask.preview")) { previewing = true }
                    .buttonStyle(.plain)
                    .popover(isPresented: $previewing) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let shot = screenshot, let data = shot.image, let image = AskImage.decode(data) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 300)
                                Text(shot.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                            } else { Text(L("ask.image.previewUnavailable")) }
                        }.padding(12)
                    }
            }
            .font(.system(size: 12))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(AskTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
    }
}
