import AppKit
import Foundation

enum RecentInputMemoryExcerpt {
    static let leadingContextLimit = 100
    static let trailingContextLimit = 100
    static let anchorLength = 48

    static func extract(insertedText: String, from fieldText: String) -> (leading: String, body: String, trailing: String)? {
        guard let range = fieldText.range(of: insertedText, options: .backwards) else { return nil }
        return (
            String(fieldText[..<range.lowerBound].suffix(leadingContextLimit)),
            String(fieldText[range]),
            String(fieldText[range.upperBound...].prefix(trailingContextLimit))
        )
    }

    static func updatedBody(in fieldText: String, leading: String, trailing: String) -> String? {
        let leadingAnchor = String(leading.suffix(anchorLength))
        let trailingAnchor = String(trailing.prefix(anchorLength))
        let start: String.Index
        if leadingAnchor.isEmpty {
            start = fieldText.startIndex
        } else {
            guard let leadingRange = fieldText.range(of: leadingAnchor, options: .backwards) else { return nil }
            start = leadingRange.upperBound
        }
        let end: String.Index
        if trailingAnchor.isEmpty {
            end = fieldText.endIndex
        } else {
            guard let trailingRange = fieldText.range(of: trailingAnchor, range: start ..< fieldText.endIndex) else {
                return nil
            }
            end = trailingRange.lowerBound
        }
        guard start <= end else { return nil }
        return String(fieldText[start ..< end])
    }

    static func excerpt(body: String, leading: String, trailing: String) -> String? {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else { return nil }
        let contextBudget = leadingContextLimit + trailingContextLimit
        let bodyBudget = RecentInputMemoryStore.maximumExcerptLength - contextBudget
        let boundedBody = String(normalizedBody.prefix(bodyBudget))
        return [String(leading.suffix(leadingContextLimit)), boundedBody, String(trailing.prefix(trailingContextLimit))]
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension WorkflowController {
    /// Memory for an LLM prompt about `appIdentifier`: recent input from the
    /// matching scope when allowed, plus the global SOUL when enabled.
    func promptMemory(for appIdentifier: String?) async -> (recentInput: [String], globalSoul: String?) {
        let memoryScope = recentInputMemoryScope?.appIdentifier == appIdentifier
            ? recentInputMemoryScope
            : RecentInputMemoryScope.resolve(bundleIdentifier: appIdentifier)
        let recentInput: [String] = if let memoryScope,
                                       settingsStore.recentInputMemoryAllowed(for: memoryScope.appIdentifier) {
            RecentInputMemoryStore.shared.recent(scope: memoryScope.key)
        } else {
            []
        }
        let soulOwnerID = await MainActor.run { GlobalSoulOwner.currentID }
        let globalSoul = settingsStore.globalSoulMemoryEnabled
            ? GlobalSoulMemoryStore.shared.soul(ownerID: soulOwnerID)?.text
            : nil
        return (recentInput, globalSoul)
    }

    @MainActor
    func scheduleRecentInputMemoryObservation(for insertedText: String, deliveryConfirmed: Bool) {
        recentInputMemoryObservationTask?.cancel()
        recentInputMemoryObservationTask = nil
        let currentAppIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let scope: RecentInputMemoryScope?
        if recentInputMemoryScope?.appIdentifier == currentAppIdentifier {
            scope = recentInputMemoryScope
        } else if currentAppIdentifier == nil || currentAppIdentifier == Bundle.main.bundleIdentifier {
            scope = recentInputMemoryScope
        } else {
            scope = RecentInputMemoryScope.resolve(bundleIdentifier: currentAppIdentifier)
        }
        guard settingsStore.recentInputMemoryEnabled,
              let scope,
              settingsStore.recentInputMemoryAllowed(for: scope.appIdentifier)
        else {
            NetworkDebugLogger.logMessage("[Recent Input Memory] skipped: disabled or app scope unavailable")
            return
        }
        let store = RecentInputMemoryStore.shared
        let storeGeneration = store.currentGeneration()
        let memoryID = UUID()
        let deliveredAt = Date()
        let ownerID = GlobalSoulOwner.currentID
        // A confirmed write may be sent before an AX read completes. Save its short
        // delivered text now, then replace it if the user edits the live input.
        if deliveryConfirmed,
           let excerpt = RecentInputMemoryExcerpt.excerpt(body: insertedText, leading: "", trailing: "") {
            let saved = store.upsert(
                id: memoryID, appIdentifier: scope.appIdentifier, scope: scope.key,
                text: excerpt, expectedGeneration: storeGeneration
            )
            NetworkDebugLogger.logMessage("[Recent Input Memory] confirmed delivery saved=\(saved) app=\(scope.appIdentifier)")
        }

        recentInputMemoryObservationTask = Task { [weak self] in
            guard let self else { return }
            var captured: (leading: String, body: String, trailing: String)?
            var initial: CurrentInputTextSnapshot?
            // Some editors publish their AX value just after insertion. Retry briefly,
            // but do not make a confirmed delivery depend on that value being readable.
            for attempt in 0 ..< 4 {
                guard !Task.isCancelled,
                      settingsStore.recentInputMemoryAllowed(for: scope.appIdentifier)
                else { return }
                let snapshot = await textInjector.currentInputTextSnapshot()
                if snapshot.isEditable, snapshot.isFocusedTarget,
                   snapshot.role != "AXSecureTextField",
                   snapshot.bundleIdentifier == scope.appIdentifier,
                   RecentInputMemoryScope.resolve(bundleIdentifier: scope.appIdentifier) == scope,
                   let fieldText = snapshot.text,
                   let match = RecentInputMemoryExcerpt.extract(insertedText: insertedText, from: fieldText) {
                    initial = snapshot
                    captured = match
                    break
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard let captured, initial != nil,
                  let firstExcerpt = RecentInputMemoryExcerpt.excerpt(
                      body: captured.body, leading: captured.leading, trailing: captured.trailing
                  )
            else {
                NetworkDebugLogger.logMessage("[Recent Input Memory] AX observation unavailable; confirmed=\(deliveryConfirmed)")
                return
            }
            guard store.upsert(
                id: memoryID, appIdentifier: scope.appIdentifier, scope: scope.key,
                text: firstExcerpt, expectedGeneration: storeGeneration
            ) else { return }
            NetworkDebugLogger.logMessage("[Recent Input Memory] observed input saved app=\(scope.appIdentifier)")
            var latestBody = captured.body
            defer {
                if settingsStore.globalSoulMemoryEnabled,
                   settingsStore.recentInputMemoryAllowed(for: scope.appIdentifier),
                   store.currentGeneration() == storeGeneration,
                   GlobalSoulOwner.currentID == ownerID {
                    GlobalSoulMemoryStore.shared.recordFinalInput(
                        id: memoryID, ownerID: ownerID, appIdentifier: scope.appIdentifier,
                        text: latestBody, at: deliveredAt
                    )
                    GlobalSoulConsolidator.shared.schedule()
                }
            }
            var changedAt: Date?
            let deadline = Date().addingTimeInterval(30)

            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      settingsStore.recentInputMemoryAllowed(for: scope.appIdentifier)
                else { return }
                let snapshot = await textInjector.currentInputTextSnapshot()
                guard snapshot.bundleIdentifier == scope.appIdentifier,
                      snapshot.isFocusedTarget,
                      snapshot.role != "AXSecureTextField",
                      RecentInputMemoryScope.resolve(bundleIdentifier: scope.appIdentifier) == scope,
                      let currentText = snapshot.text else { break }
                guard let body = RecentInputMemoryExcerpt.updatedBody(
                    in: currentText, leading: captured.leading, trailing: captured.trailing
                ) else { break }
                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.delete(id: memoryID)
                    return
                }
                if body != latestBody {
                    latestBody = body
                    changedAt = Date()
                }
                if let changedAt, Date().timeIntervalSince(changedAt) >= 4 {
                    break
                }
            }

            guard !Task.isCancelled,
                  settingsStore.recentInputMemoryAllowed(for: scope.appIdentifier),
                  let finalExcerpt = RecentInputMemoryExcerpt.excerpt(
                      body: latestBody, leading: captured.leading, trailing: captured.trailing
                  )
            else { return }
            store.upsert(
                id: memoryID, appIdentifier: scope.appIdentifier, scope: scope.key,
                text: finalExcerpt, expectedGeneration: storeGeneration
            )
        }
    }
}
