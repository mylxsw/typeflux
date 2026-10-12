import AppKit
import Foundation

enum PersonaAppPickerScope: String, CaseIterable, Sendable {
    case running
    case all

    var title: String {
        switch self {
        case .running:
            L("settings.personaAppBindings.picker.scope.running")
        case .all:
            L("settings.personaAppBindings.picker.scope.all")
        }
    }
}

struct PersonaAppCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let appURL: URL?
    let isRunning: Bool

    var preferredIdentifier: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return displayName
    }
}

enum PersonaAppDiscovery {
    static func discoverPersonaAppCandidates(scope: PersonaAppPickerScope) async -> [PersonaAppCandidate] {
        switch scope {
        case .running:
            return await MainActor.run {
                runningPersonaAppCandidates()
            }
        case .all:
            async let installed = loadInstalledPersonaAppCandidates()
            let running = await MainActor.run {
                runningPersonaAppCandidates()
            }
            return await mergePersonaAppCandidates(running, installed)
        }
    }

    nonisolated static func loadInstalledPersonaAppCandidates() async -> [PersonaAppCandidate] {
        let task = Task.detached(priority: .userInitiated) {
            installedPersonaAppCandidates()
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    @MainActor
    static func runningPersonaAppCandidates() -> [PersonaAppCandidate] {
        var seen = Set<String>()

        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy != .prohibited else { return nil }

            let displayName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleIdentifier = application.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            let appURL = application.bundleURL
            let preferredIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : (displayName ?? "")
            guard !preferredIdentifier.isEmpty else { return nil }

            let candidateID = (bundleIdentifier?.isEmpty == false ? bundleIdentifier : appURL?.path) ??
                preferredIdentifier
            guard seen.insert(candidateID.lowercased()).inserted else { return nil }

            return PersonaAppCandidate(
                id: candidateID,
                displayName: (displayName?.isEmpty == false ? displayName : appDisplayName(for: appURL)) ??
                    preferredIdentifier,
                bundleIdentifier: bundleIdentifier,
                appURL: appURL,
                isRunning: true
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    nonisolated static func installedPersonaAppCandidates(searchRoots: [URL]? = nil) -> [PersonaAppCandidate] {
        let fileManager = FileManager.default
        let searchRoots = searchRoots ?? Array(
            Set(
                fileManager.urls(for: .applicationDirectory, in: .localDomainMask)
                    + fileManager.urls(for: .applicationDirectory, in: .systemDomainMask)
                    + fileManager.urls(for: .applicationDirectory, in: .userDomainMask)
                    + [
                        URL(fileURLWithPath: "/Applications"),
                        URL(fileURLWithPath: "/System/Applications"),
                        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
                    ]
            )
        )

        var candidates: [PersonaAppCandidate] = []
        var seen = Set<String>()

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            while !Task.isCancelled, let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                enumerator.skipDescendants()

                let bundleIdentifier = Bundle(url: url)?.bundleIdentifier?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = appDisplayName(for: url) ?? url.deletingPathExtension().lastPathComponent
                let candidateID = bundleIdentifier ?? url.path
                guard seen.insert(candidateID.lowercased()).inserted else { continue }

                candidates.append(
                    PersonaAppCandidate(
                        id: candidateID,
                        displayName: displayName,
                        bundleIdentifier: bundleIdentifier,
                        appURL: url,
                        isRunning: false
                    )
                )
            }
        }

        return candidates.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    nonisolated static func mergePersonaAppCandidates(
        _ first: [PersonaAppCandidate],
        _ second: [PersonaAppCandidate]
    ) -> [PersonaAppCandidate] {
        var merged: [PersonaAppCandidate] = []
        var seen = Set<String>()

        for candidate in first + second {
            guard seen.insert(candidate.id.lowercased()).inserted else { continue }
            merged.append(candidate)
        }

        return merged.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    nonisolated static func appDisplayName(for url: URL?) -> String? {
        guard let url else { return nil }

        if let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !name.isEmpty {
                return name
            }

            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }

        return url.deletingPathExtension().lastPathComponent
    }
}
