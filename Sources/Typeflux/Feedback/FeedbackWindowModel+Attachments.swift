import AppKit

/// Adding, processing, retrying and removing attachments of the feedback window.
extension FeedbackWindowModel {
    // MARK: - Adding files

    func addFiles(_ urls: [URL]) {
        notice = nil
        for url in urls {
            addFile(at: url)
        }
    }

    func addImageData(_ data: Data, filename: String) {
        notice = nil
        guard canAddAttachments else {
            notice = FeedbackAttachmentRejection.tooMany(limit: FeedbackAttachmentPolicy.maxAttachmentCount).message
            return
        }
        let id = beginAttachment(filename: filename, kind: .image, originalSize: Int64(data.count))
        process(id: id, source: .data(data))
    }

    func addFile(at url: URL) {
        let filename = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let rejection = FeedbackAttachmentPolicy.validate(
            filename: filename, sizeBytes: size, currentCount: attachments.count
        ) {
            notice = rejection.message
            return
        }
        guard let kind = FeedbackAttachmentPolicy.kind(forFilename: filename) else { return }
        let id = beginAttachment(filename: filename, kind: kind, originalSize: size)
        previewURLs[id] = url
        process(id: id, source: .file(url))
    }

    enum Source {
        case data(Data)
        case file(URL)
    }

    /// Compresses (images, videos) or reads (other files) the source, then checks and uploads it.
    func process(id: UUID, source: Source) {
        guard let attachment = attachment(id: id) else { return }
        let kind = attachment.kind
        let filename = attachment.filename
        let contentType = attachment.contentType
        run(id) { [self] in
            let prepared: PreparedFeedbackFile
            switch (kind, source) {
            case let (.image, .data(data)):
                prepared = try await services.prepareImage(data: data, filename: filename)
            case let (.image, .file(url)):
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                prepared = try await services.prepareImage(data: data, filename: filename)
            case let (.video, .file(url)):
                prepared = try await services.prepareVideo(url: url) { [weak self] progress in
                    Task { @MainActor in self?.setPreparing(id: id, progress: progress) }
                }
            case let (.file, .file(url)):
                prepared = try PreparedFeedbackFile(
                    data: Data(contentsOf: url), filename: filename, contentType: contentType, kind: .file
                )
            case (.video, .data), (.file, .data):
                throw FeedbackMediaError.videoUnreadable
            }
            try await finish(id: id, prepared: prepared)
        }
    }

    func beginAttachment(filename: String, kind: FeedbackAttachmentKind, originalSize: Int64) -> UUID {
        let attachment = FeedbackAttachment(
            filename: filename,
            kind: kind,
            contentType: FeedbackAttachmentPolicy.contentType(forFilename: filename) ?? "application/octet-stream",
            originalSizeBytes: originalSize,
            state: .preparing(progress: kind == .video ? 0 : nil)
        )
        attachments.append(attachment)
        editor.insert(FeedbackTextAttachment(attachmentID: attachment.id))
        return attachment.id
    }

    func run(_ id: UUID, _ work: @escaping @MainActor () async throws -> Void) {
        tasks[id] = Task { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
                // Removed or reset; the attachment is already gone.
            } catch {
                self?.fail(id: id, error: error)
            }
            self?.tasks.removeValue(forKey: id)
        }
    }

    /// Checks the prepared file against its limit, uploads it and records the result.
    func finish(id: UUID, prepared: PreparedFeedbackFile) async throws {
        try Task.checkCancellation()
        let size = Int64(prepared.data.count)
        if let rejection = FeedbackAttachmentPolicy.validateUploadSize(filename: prepared.filename, sizeBytes: size) {
            update(id: id) {
                $0.sizeBytes = size
                $0.thumbnail = prepared.thumbnail
                $0.state = .rejected(rejection.message)
            }
            return
        }
        update(id: id) {
            $0.filename = prepared.filename
            $0.contentType = prepared.contentType
            $0.sizeBytes = size
            $0.durationSeconds = prepared.durationSeconds
            $0.thumbnail = prepared.thumbnail
            $0.state = .uploading
        }
        let credential = await services.credential()
        let url = try await services.upload(prepared, credential: credential)
        try Task.checkCancellation()
        update(id: id) {
            $0.state = .uploaded(url)
            $0.uploadOwner = FeedbackUploadOwner(credential)
        }
    }

    func fail(id: UUID, error: Error) {
        if let media = error as? FeedbackMediaError, case let .videoStillTooLarge(bytes) = media {
            update(id: id) {
                $0.sizeBytes = bytes
                $0.state = .rejected(media.localizedDescription)
            }
            return
        }
        update(id: id) { $0.state = .failed(error.localizedDescription) }
    }

    func setPreparing(id: UUID, progress: Double) {
        update(id: id) {
            if case .preparing = $0.state {
                $0.state = .preparing(progress: progress)
            }
        }
    }

    func update(id: UUID, _ mutate: (inout FeedbackAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        mutate(&attachments[index])
        editor.refreshAttachment(id: id)
    }

    // MARK: - Removing and retrying

    /// Removes the attachment from the body and the model.
    func remove(id: UUID) {
        editor.removeAttachmentBlock(id: id)
        discard(id: id)
    }

    func discard(id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        previewURLs.removeValue(forKey: id)
        attachments.removeAll { $0.id == id }
    }

    /// Retries a failed attachment: files picked from disk are read again.
    func retry(id: UUID) {
        guard let attachment = attachment(id: id), case .failed = attachment.state,
              let url = previewURLs[id] else { return }
        update(id: id) { $0.state = .preparing(progress: attachment.kind == .video ? 0 : nil) }
        process(id: id, source: .file(url))
    }

    /// The local file to open when a block is double-clicked.
    func previewURL(id: UUID) -> URL? {
        previewURLs[id]
    }
}
