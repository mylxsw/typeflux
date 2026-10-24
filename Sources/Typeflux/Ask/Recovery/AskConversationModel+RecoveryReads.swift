import Foundation

extension AskConversationModel {
    /// A failed journal read stays closed to execution. Only the read itself is
    /// retried: never send, resume, acknowledge or execute a tool from this task.
    func refreshRecovery(_ value: AskConversation, route: AskRoute) async {
        let token = UUID(), generation = recoveryGeneration
        recoveryReadRetries.removeValue(forKey: value.id)?.cancel()
        recoveryReadTokens[value.id] = token
        if await readRecovery(value, route: route, token: token, generation: generation) { return }
        guard selectedId == value.id,
              recoveryReadIsCurrent(value.id, route: route, token: token, generation: generation) else { return }
        retryRecoveryRead(value, route: route, token: token, generation: generation)
    }

    private func recoveryReadIsCurrent(_ id: String, route: AskRoute, token: UUID, generation: UUID) -> Bool {
        recoveryReadTokens[id] == token && recoveryGeneration == generation
            && owner == route.account && session()?.owner == route.account && !isDeletedConversation(id)
    }

    private func readRecovery(_ value: AskConversation, route: AskRoute, token: UUID, generation: UUID) async -> Bool {
        do {
            try Task.checkCancellation()
            var entries = try await cache.executions(conversationId: value.id, owner: route.owner)
            if let run = value.run {
                let keys = run.pending.map { run.id + "/" + $0.id }
                    + (run.inference.map { ["inference/" + run.id + "/" + $0.id] } ?? [])
                for key in keys where !entries.contains(where: { $0.id == key }) {
                    if let entry = try await cache.execution(id: key, owner: route.owner) { entries.append(entry) }
                }
            }
            try Task.checkCancellation()
            guard recoveryReadIsCurrent(value.id, route: route, token: token, generation: generation) else { return false }
            let wasUnavailable = (recoveryEntries[value.id] ?? []).contains(where: \.readUnavailable)
            recoveryEntries[value.id] = entries.map { entry in
                guard let identity = entry.audit?.identity else { return entry }
                guard identity.owner == route.account, identity.conversationId == value.id else {
                    return .init(id: entry.id, audit: nil, receipt: nil)
                }
                return entry
            }
            if wasUnavailable, selectedId == value.id, error == L("ask.cache.failed") { error = nil }
            return true
        } catch {
            AskFailureDiagnostics.shared.record(.recoveryRead, error: error)
            guard recoveryReadIsCurrent(value.id, route: route, token: token, generation: generation) else { return false }
            // Cancellation is normal during navigation, not proof of disk damage.
            // Keep the execution gate closed until an uncancelled read succeeds.
            recoveryEntries[value.id] = [.init(id: "unavailable", audit: nil, receipt: nil)]
            if selectedId == value.id, !(error is CancellationError), !Task.isCancelled {
                self.error = L("ask.cache.failed")
            }
            return false
        }
    }

    private func retryRecoveryRead(_ value: AskConversation, route: AskRoute, token: UUID, generation: UUID) {
        let delays = recoveryReadRetryDelays
        recoveryReadRetries[value.id] = Task { [weak self] in
            defer {
                if self?.recoveryReadTokens[value.id] == token { self?.recoveryReadRetries[value.id] = nil }
            }
            for delay in delays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, selectedId == value.id,
                      recoveryReadIsCurrent(value.id, route: route, token: token, generation: generation) else { return }
                let latest = snapshots[value.id] ?? value
                if await readRecovery(latest, route: route, token: token, generation: generation) {
                    AskFailureDiagnostics.shared.record(.recoveryReadRecovered, error: AskRecoveryError.storage)
                    return
                }
            }
            guard let self, selectedId == value.id,
                  recoveryReadIsCurrent(value.id, route: route, token: token, generation: generation) else { return }
            AskFailureDiagnostics.shared.record(.recoveryReadExhausted, error: AskRecoveryError.storage)
            error = L("ask.cache.failed")
        }
    }
}
