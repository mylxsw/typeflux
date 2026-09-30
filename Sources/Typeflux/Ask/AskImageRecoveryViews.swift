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

struct AskImageRecoveryPicker: View {
    @ObservedObject var model: AskConversationModel
    @ObservedObject private var auth = AuthState.shared
    let target: AskImageRecoveryTarget
    var dismiss: () -> Void
    @State private var candidate = ""
    @State private var refreshGeneration = 0
    @State private var refreshing = false
    private var loading: Bool { refreshing || model.modelLibrary.loading }

    private var choices: [RegisteredProvider] {
        model.modelLibrary.selectableProviders(loggedIn: auth.isLoggedIn, hasImage: true)
    }
    private var valid: Bool { choices.contains { $0.models.contains { $0.reference == candidate } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("ask.image.pickerHint")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            HStack {
                Button(L("ask.image.refreshModels")) { refreshGeneration += 1 }
                    .disabled(loading)
                if loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 12)
            if let error = model.modelLibrary.catalogError {
                Text(error).font(.caption).foregroundStyle(StudioTheme.warning).padding(.horizontal, 12)
            }
            if choices.isEmpty {
                if !loading, model.modelLibrary.catalogError == nil {
                    Text(L("ask.image.noModels")).font(.callout).padding(.horizontal, 12)
                }
                Button(L("ask.image.configure")) { dismiss(); model.onOpenSettings?() }.padding(.horizontal, 12)
            } else {
                AskModelChoices(library: model.modelLibrary, reference: $candidate,
                                showsDefaultAction: false, hasImage: true, loggedIn: auth.isLoggedIn,
                                preferredProviderID: model.modelLibrary.registry.resolve(model.modelReference(launcher: false))?.0.id,
                                showsUnavailableSelection: false)
            }
            HStack {
                Button(L("ask.image.cancel"), action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(valid ? L("ask.image.continue", model.modelLibrary.name(for: candidate)) : L("ask.image.choose")) {
                    model.resumeImage(target, reference: candidate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || loading || model.isBusy || model.isLoadingSelection)
            }.padding(.horizontal, 12)
        }
        .padding(.vertical, 12).frame(width: 360)
        .background(ModelVisualStyle.input)
        .onAppear { if model.canResumeImage { candidate = model.modelReference(launcher: false) } }
        .task(id: refreshGeneration) {
            guard model.modelLibrary.automaticallyLoadsCatalog || refreshGeneration > 0 else { return }
            refreshing = true
            await model.refreshImageModels()
            refreshing = false
        }
        .onChange(of: model.selectedId) { _ in dismiss() }
        .onChange(of: model.selected?.run?.id) { _ in dismiss() }
    }
}
