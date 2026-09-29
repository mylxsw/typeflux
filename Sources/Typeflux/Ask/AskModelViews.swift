import SwiftUI

struct AskModelMenu: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    var disabled = false
    @State private var managing = false

    var body: some View {
        Menu {
            Section("Typeflux Cloud") {
                ForEach(library.cloud) { item in choice(item.name, value: item.reference) }
            }
            Section(L("ask.models.custom")) {
                ForEach(library.profiles) { item in choice(item.name, value: item.reference) }
            }
            Divider()
            Button(L("ask.models.manage")) { managing = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reference.hasPrefix("custom:") ? "server.rack" : "cloud")
                Text(library.name(for: reference)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 130)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(disabled)
        .help(L("ask.models.conversationOnly"))
        .task { if library.automaticallyLoadsCatalog { await library.refresh(token: AuthState.shared.accessToken) } }
        .sheet(isPresented: $managing) { AskModelLibraryView(library: library) }
    }

    private func choice(_ name: String, value: String) -> some View {
        Button { reference = value } label: {
            if reference == value { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }
}

struct AskModelPurposeView: View {
    @ObservedObject var library: AskModelLibrary
    let speechProviderName: String
    @State private var managing = false

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("ask.models.byPurpose")).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(L("ask.models.manage")) { managing = true }.buttonStyle(.link)
                }
                HStack {
                    Label(L("ask.models.speech"), systemImage: "waveform").frame(width: 140, alignment: .leading)
                    Spacer()
                    Text(speechProviderName).foregroundStyle(StudioTheme.textSecondary)
                }
                Divider()
                HStack {
                    Label(L("ask.models.rewrite"), systemImage: "text.badge.checkmark").frame(width: 140, alignment: .leading)
                    Spacer()
                    Picker("", selection: $library.rewriteReference) {
                        Text(L("ask.models.existingRewrite")).tag("")
                        Text("Typeflux Cloud").tag("cloud:default")
                        ForEach(library.profiles) { Text($0.name).tag($0.reference) }
                        if !library.rewriteReference.isEmpty && library.rewriteReference != "cloud:default" && !library.profiles.contains(where: { $0.reference == library.rewriteReference }) {
                            Text(L("ask.models.unavailable")).tag(library.rewriteReference)
                        }
                    }.labelsHidden().frame(width: 220)
                }
                Divider()
                HStack {
                    Label(L("ask.models.ask"), systemImage: "sparkles").frame(width: 140, alignment: .leading)
                    Spacer()
                    AskModelMenu(library: library, reference: $library.defaultReference)
                }
                Text(L("ask.models.defaultsHint")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }.font(.system(size: 12))
        }
        .sheet(isPresented: $managing) { AskModelLibraryView(library: library) }
    }
}

struct AskModelLibraryView: View {
    @ObservedObject var library: AskModelLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var deleting: AskModelProfile?
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("ask.models.manage")).font(.system(size: 20, weight: .semibold))
                    Text(L("ask.models.libraryHint")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button(L("ask.models.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("TYPEFLUX CLOUD").font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                    ForEach(library.cloud) { item in
                        modelRow(name: item.name, subtitle: L("ask.models.cloudHint"), reference: item.reference, icon: "cloud")
                    }
                    if let error = library.catalogError {
                        HStack { Text(error).font(.caption); Spacer(); Button(L("ask.models.reload")) { Task { await library.refresh(token: AuthState.shared.accessToken) } } }
                    }
                    Divider()
                    HStack {
                        Text(L("ask.models.custom")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if library.configuredProfile != nil {
                            Button(L("ask.models.import")) {
                                do { try library.importConfiguredProfile(); importError = nil } catch { importError = error.localizedDescription }
                            }
                        }
                        Button { adding = true } label: { Label(L("ask.models.add"), systemImage: "plus") }
                    }
                    if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
                    if library.profiles.isEmpty {
                        Text(L("ask.models.empty")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).padding(.vertical, 12)
                    }
                    ForEach(library.profiles) { profile in
                        HStack {
                            modelRow(name: profile.name, subtitle: profile.model, reference: profile.reference, icon: "server.rack")
                            Button { deleting = profile } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("ask.models.delete"))
                        }
                    }
                }
            }
            Text(L("ask.models.privacy")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
        }
        .padding(24).frame(width: 590, height: 460).background(StudioTheme.background)
        .task { if library.automaticallyLoadsCatalog { await library.refresh(token: AuthState.shared.accessToken) } }
        .sheet(isPresented: $adding) { AskModelEditor(library: library) }
        .alert(L("ask.models.delete"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("ask.models.cancel"), role: .cancel) { deleting = nil }
            Button(L("ask.models.delete"), role: .destructive) { if let deleting { library.remove(deleting) }; deleting = nil }
        } message: { Text(L("ask.models.deleteHint")) }
    }

    private func modelRow(name: String, subtitle: String, reference: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(StudioTheme.textSecondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }
            Spacer()
            if library.defaultReference == reference {
                Text(L("ask.models.askDefault")).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
            } else {
                Button(L("ask.models.makeDefault")) { library.defaultReference = reference }.buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(12).background(AskTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct AskModelEditor: View {
    @ObservedObject var library: AskModelLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var profile = AskModelProfile(name: "", baseURL: "https://", model: "")
    @State private var key = ""
    @State private var testing = false
    @State private var notice: String?
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("ask.models.add")).font(.system(size: 20, weight: .semibold))
            Text(L("ask.models.compatible")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            Form {
                TextField(L("ask.models.name"), text: $profile.name)
                TextField(L("ask.models.url"), text: $profile.baseURL)
                SecureField("API Key", text: $key)
                TextField(L("ask.models.modelID"), text: $profile.model)
            }.textFieldStyle(.roundedBorder)
            if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L("ask.models.test")) {
                    testing = true; notice = nil
                    let testedProfile = profile; let testedKey = key
                    testTask = Task {
                        defer { testing = false }
                        do {
                            try await AskCustomInference().test(profile: testedProfile, key: testedKey)
                            notice = L("ask.models.testOK")
                        } catch is CancellationError {} catch { notice = error.localizedDescription }
                    }
                }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("ask.models.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("ask.models.save")) {
                    do { try library.save(profile, key: key); dismiss() } catch { notice = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(testing)
            }
        }.padding(24).frame(width: 490)
        .onDisappear { testTask?.cancel() }
    }
}
