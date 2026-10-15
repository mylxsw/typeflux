import AppKit
import SwiftUI

struct AskGenerationRecoveryAccess {
    var root: URL
    var owner: String
    var conversation: String
    var authorize: @MainActor () throws -> Void
}

extension AskLocalTools {
    var generationRecoveryRoot: URL? { AskImageGenerationRetention.root(for: artifactStore) }
}

extension AskConversationModel {
    var generationRecoveryAccess: AskGenerationRecoveryAccess? {
        guard let current = session(), let conversation = selectedId, let root = tools.generationRecoveryRoot,
              !isDeletedConversation(conversation) else { return nil }
        let generation = selectionGeneration
        return .init(root: root, owner: current.owner,
                     conversation: conversation, authorize: { [weak self] in
            guard let self, let live = self.session(), live.owner == current.owner, live.token == current.token,
                  self.selectedId == conversation, self.selectionGeneration == generation,
                  !self.isDeletedConversation(conversation) else {
                throw AskArtifactError.denied
            }
        })
    }
}

struct AskGenerationRecoveryView: View {
    let access: AskGenerationRecoveryAccess
    var close: () -> Void
    var destination: @MainActor (String) -> URL?
    @StateObject private var model = AskGenerationRecoveryModel()
    @State private var saving: Task<Void, Never>?

    @MainActor init(access: AskGenerationRecoveryAccess, close: @escaping () -> Void,
                    model: AskGenerationRecoveryModel? = nil,
                    destination: @escaping @MainActor (String) -> URL? = Self.chooseDestination) {
        self.access = access; self.close = close; self.destination = destination
        _model = StateObject(wrappedValue: model ?? AskGenerationRecoveryModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("imagegen.recovery.title")).font(.headline)
                Spacer()
                Button(L("ask.artifact.close"), action: close)
            }
            Text(L("imagegen.recovery.detail")).font(.callout).foregroundStyle(.secondary)
            if model.busy { ProgressView().controlSize(.small) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(record.callId.prefix(80))).font(.system(.caption, design: .monospaced))
                            ForEach(record.files, id: \.self) { name in
                                HStack {
                                    Text(name).font(.callout)
                                    Spacer()
                                    Button(L("ask.artifact.save")) { save(record, name: name) }
                                        .disabled(model.busy)
                                        .accessibilityIdentifier("generation.recovery.save." + name)
                                }
                            }
                        }
                    }
                    if model.records.isEmpty, !model.busy, model.message == nil {
                        Text(L("imagegen.recovery.empty")).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(22).frame(width: 560, height: 360)
        .task { await model.load(root: access.root, owner: access.owner, conversation: access.conversation, authorize: access.authorize) }
        .onDisappear { saving?.cancel(); saving = nil; model.cancel() }
    }

    private func save(_ record: AskGenerationRecoveryRecord, name: String) {
        do { try access.authorize() } catch { model.cancel(); return }
        guard let destination = destination(name) else { return }
        saving?.cancel()
        saving = Task {
            await model.save(record, name: name, destination: destination, root: access.root,
                             owner: access.owner, conversation: access.conversation, authorize: access.authorize)
        }
    }
    @MainActor private static func chooseDestination(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.hasPrefix("download-") ? name + ".bin" : name
        return panel.runModal() == .OK ? panel.url : nil
    }

}
