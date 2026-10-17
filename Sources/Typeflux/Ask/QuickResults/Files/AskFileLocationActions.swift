import Foundation

extension AskFileHit {
    /// Even invalid or obsolete evidence needs an honest capability fallback.
    var hasPDFLocationEvidence: Bool { kind == .file && url.pathExtension.lowercased() == "pdf" && evidence != nil }

    var hasMediaLocationEvidence: Bool {
        kind == .file && evidence != nil && [.audio, .video].contains(SemanticMediaPriority.of(path))
    }

    var hasLocationEvidence: Bool { hasPDFLocationEvidence || hasMediaLocationEvidence }

    var locationMessagePrefix: String { hasPDFLocationEvidence ? "ask.quick.file.pdf." : "ask.quick.file.media." }

    func mediaPreviewTime(version: String?) -> Double? {
        guard hasMediaLocationEvidence, let evidence, let version, evidence.version == version,
              ["audio-window", "video-frame"].contains(evidence.segmentKind ?? ""),
              let time = evidence.time, time.isFinite, time >= 0, time < Double(Int32.max) else { return nil }
        return time
    }
}

extension AskConversationModel {
    /// Synchronous actions cannot outlive a selection. Recheck settings and permission before dispatch.
    func allowsFileEvidenceAction(_ hit: AskFileHit) -> Bool {
        guard quickFilesEnabled, modelLibrary.settings.semanticFileSearch.enabled else { return false }
        let scope = SemanticFilePolicy.scope(names: launcherSearchSettings,
                                             fullDiskAccess: AskFullDiskAccess.isGranted())
        return scope.includes(hit.path, isDirectory: hit.isFolder)
            && !AskFileScope.isProtected(hit.path, folders: fileIndex.status.blocked)
    }

    var selectedPluginFile: AskFileHit? {
        guard AskFileSearchPlugin.showsFileResults(for: plugins.plugin?.id), plugins.isPlanCurrent else { return nil }
        return plugins.currentOutput?.selected?.fileHit
    }

    /// The action's captured hit must still be owned by the current published selection.
    func performPluginFileAction(_ action: AskPluginAction) -> AskQuickActionOutcome? {
        guard case let .fileAction(operation, hit) = action.kind, selectedPluginFile == hit,
              plugins.currentOutput?.selected?.actions.contains(action) == true else { return nil }
        return performQuickFileAction(operation, hit)
    }

    func fileLocationNotice(_ hit: AskFileHit) {
        guard hit.hasLocationEvidence else { return }
        // NSWorkspace opens the original URL; no external page/time positioning contract is verified.
        // Say "opening", since the system's asynchronous handoff is not proof the reader displayed it.
        passiveNotice(L(hit.locationMessagePrefix + "open"))
    }
}
