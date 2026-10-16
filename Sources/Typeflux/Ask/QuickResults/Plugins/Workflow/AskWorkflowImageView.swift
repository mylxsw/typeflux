import SwiftUI

/// File content is revalidated; an ID, modification time or metadata is never decoder proof.
struct AskWorkflowImageView: View {
    let image: AskPluginImage
    let size: CGSize
    var worker: MediaWorker = .previews
    var body: some View {
        AskContextImage(source: image.url.absoluteString, model: AskContextImageModel(decode: { _ in
            try await AskWorkflowImage.render(image, worker: worker)
        })) { picture in
            if let picture { Image(nsImage: picture).resizable().interpolation(.high).frame(width: size.width, height: size.height) }
            else { Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(StudioTheme.textTertiary) }
        }
        .id(image)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The editor owns a local presentation scope; changing the last run cancels its preparation.
struct AskWorkflowImageEditorPreview: View {
    let name: String
    let folder: URL
    var worker: MediaWorker = .previews
    @State private var prepared: AskPluginImage?
    @State private var scope = AskImagePresentationScope()
    var body: some View {
        Group {
            if let prepared { AskWorkflowImageView(image: prepared, size: AskWorkflowLauncherPreview.previewSize(prepared), worker: worker) }
            else { Text(L("ask.image.previewUnavailable")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary) }
        }
        .frame(maxWidth: .infinity)
        .environment(\.askContextImageAccess, .init(scope: scope, epoch: scope.epoch, authorize: { true }))
        .task(id: folder.absoluteString + "|" + name) {
            prepared = nil; scope.setVisible(true); scope.invalidate()
            let result = await AskWorkflowImage.resolve(name, folder: folder,
                cache: FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-workflow-preview"), home: NSHomeDirectory(), worker: worker)
            guard !Task.isCancelled else { return }
            if case let .success(image) = result { prepared = image }
        }
        .onDisappear { scope.setVisible(false); prepared = nil }
    }
}
