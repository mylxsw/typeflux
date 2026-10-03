import SwiftUI

/// Resolve empty states before offering an action: a failed fetch is not a configuration problem.
struct AskImagePickerState: Equatable {
    enum Content: Equatable { case choices, loading, failed, empty, signedOut }
    let content: Content
    let loading: Bool
    let catalogFailed: Bool

    init(hasChoices: Bool, loading: Bool, catalogFailed: Bool, loggedIn: Bool) {
        self.loading = loading
        self.catalogFailed = catalogFailed
        if !loggedIn { content = .signedOut }
        else if hasChoices { content = .choices }
        else if loading { content = .loading }
        else if catalogFailed { content = .failed }
        else { content = .empty }
    }

    var offersSettings: Bool { content == .empty }
    var offersRetry: Bool { content == .failed }
    var showsCloudFailure: Bool { content == .choices && catalogFailed && !loading }
    func canContinue(candidate: String, providers: [RegisteredProvider], busy: Bool) -> Bool {
        content == .choices && !busy && providers.contains { provider in
            (!provider.isCloud || (!loading && !catalogFailed)) && provider.models.contains { $0.reference == candidate }
        }
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

    var body: some View {
        AskImagePickerContent(library: model.modelLibrary, candidate: $candidate,
                              currentReference: model.modelReference(launcher: false),
                              loggedIn: model.cloudAvailable && auth.isLoggedIn, loading: refreshing || model.modelLibrary.loading,
                              hasSavedScreenshot: model.hasConversationImages,
                              busy: model.isBusy || model.isLoadingSelection || model.imageRecoveryTarget != target,
                              dismiss: dismiss, refresh: { refreshGeneration += 1 },
                              configure: { dismiss(); model.onOpenSettings?(.models) },
                              signIn: { dismiss(); LoginWindowController.shared.show() },
                              resume: { model.resumeImage(target, reference: candidate); dismiss() })
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

struct AskImagePickerContent: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var candidate: String
    let currentReference: String
    let loggedIn: Bool
    let loading: Bool
    let hasSavedScreenshot: Bool
    let busy: Bool
    var dismiss: () -> Void
    var refresh: () -> Void
    var configure: () -> Void
    var signIn: () -> Void
    var resume: () -> Void

    private var providers: [RegisteredProvider] {
        library.imageRecoveryProviders(loggedIn: loggedIn)
    }
    private var state: AskImagePickerState {
        AskImagePickerState(hasChoices: !providers.isEmpty, loading: loading,
                            catalogFailed: library.catalogError != nil, loggedIn: loggedIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("ask.image.pickerTitle")).font(.system(size: 14, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if loading { ProgressView().controlSize(.small).accessibilityLabel(L("ask.image.loading")) }
                    else if state.content == .choices || state.content == .empty {
                        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary)
                            .help(L("ask.image.refreshModels")).accessibilityLabel(L("ask.image.refreshModels"))
                    }
                }
                Text(L(hasSavedScreenshot ? "ask.image.pickerHint" : "ask.image.pickerHintWithoutScreenshot"))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(16)
            Divider()
            Group {
                switch state.content {
                case .choices:
                    VStack(alignment: .leading, spacing: 0) {
                        if state.showsCloudFailure {
                            HStack(alignment: .top, spacing: 10) {
                                Text(L("ask.image.cloudUnavailable")).font(.system(size: 12))
                                    .foregroundStyle(StudioTheme.textSecondary)
                                Spacer(minLength: 0)
                                Button(L("ask.image.retry"), action: refresh).controlSize(.small)
                            }.padding(12)
                        }
                        AskModelChoices(library: library, reference: $candidate,
                                        showsDefaultAction: false, hasImage: true, loggedIn: loggedIn,
                                        preferredProviderID: library.registry.resolve(currentReference)?.0.id,
                                        showsUnavailableSelection: false, recoveryProviders: providers)
                    }
                case .loading: message("ask.image.loading", icon: "")
                case .failed: message("ask.image.loadFailed", icon: "exclamationmark.circle")
                case .empty: message("ask.image.noModels", icon: "photo")
                case .signedOut: message("ask.image.signInHint", icon: "person.crop.circle")
                }
            }
            Divider()
            HStack {
                Button(L("ask.image.cancel"), action: dismiss)
                    .buttonStyle(ModelActionStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if state.offersRetry {
                    primary("ask.image.retry", action: refresh)
                } else if state.offersSettings {
                    primary("ask.image.configure", action: configure)
                } else if state.content == .signedOut {
                    primary("auth.account.signIn", action: signIn)
                } else if state.content == .choices {
                    primary(candidate == currentReference ? "ask.image.resume" : "ask.image.switchAndContinue", action: resume)
                        .disabled(!state.canContinue(candidate: candidate, providers: providers, busy: busy))
                }
            }.padding(16)
        }
        .frame(width: 360).background(ModelVisualStyle.input).tint(AskTheme.accent)
    }

    private func primary(_ key: String, action: @escaping () -> Void) -> some View {
        Button(L(key), action: action).buttonStyle(ModelActionStyle(primary: true)).keyboardShortcut(.defaultAction)
    }

    private func message(_ key: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if !icon.isEmpty { Image(systemName: icon).accessibilityHidden(true) }
            Text(L(key)).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary).padding(16)
    }
}

extension AskModelLibrary {
    func imageRecoveryProviders(loggedIn: Bool) -> [RegisteredProvider] {
        // A cloud retry needs a fresh catalog. Local models remain usable when that fetch fails.
        // A retry needs a model known to read images; an unknown one may be what just failed.
        selectableProviders(loggedIn: loggedIn, hasImage: true, confirmedVision: true)
            .filter { catalogError == nil || !$0.isCloud }
    }
}
