import Foundation

extension AskConversationModel {
    var selectedRecoveryEntries: [AskExecutionEntry] {
        selectedId.flatMap { recoveryEntries[$0] } ?? []
    }

    func recoveryBlocksResume(_ value: AskConversation) -> Bool {
        value.run?.needsRecoveryInspection == true || (recoveryEntries[value.id] ?? []).contains {
            ($0.audit?.identity.runId == value.run?.id || $0.audit == nil) && $0.needsInspection(run: value.run)
        }
    }

    var recoveryPresentation: AskRecoveryPresentation {
        .init(run: selected?.run, entries: selectedRecoveryEntries, deviceId: deviceId,
              local: selected.map { isLocal($0.id) } ?? false)
    }

    /// The single state every run indicator reads; see `AskRunPhase`.
    var runPhase: AskRunPhase? {
        guard let value = selected else { return nil }
        return AskRunPhase.resolve(run: value.run, busy: busyIds.contains(value.id),
                                   pendingApproval: pendingApprovals[value.id] != nil,
                                   recovery: recoveryPresentation)
    }

    var hasRecoveryNotice: Bool {
        selected != nil && recoveryPresentation.isVisible
    }

    /// Quote only a message explicitly attached to this run, never a newer question.
    var recoveryRequestText: String? {
        guard let value = selected, let run = value.run,
              run.needsRecoveryInspection || selectedRecoveryEntries.contains(where: {
                  $0.audit?.identity.runId == run.id && $0.unknown
              }),
              let message = value.messages.first(where: {
                  $0.role == "user" && $0.runId == run.id && $0.steered != true
              }) else { return nil }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var canRetransmitReceipts: Bool {
        guard !recoveryWorking, let run = selected?.run else { return false }
        return selectedRecoveryEntries.contains {
            !$0.acknowledged && !$0.deleted && $0.receipt != nil && $0.audit?.identity.deviceId == deviceId
                && $0.audit?.identity.owner == session()?.owner && $0.audit?.identity.runId == run.id
        }
    }

    func refreshRecovery(_ value: AskConversation, route: AskRoute) async {
        let generation = recoveryGeneration
        do {
            var entries = try await cache.executions(conversationId: value.id, owner: route.owner)
            if let run = value.run {
                let keys = run.pending.map { run.id + "/" + $0.id }
                    + (run.inference.map { ["inference/" + run.id + "/" + $0.id] } ?? [])
                for key in keys where !entries.contains(where: { $0.id == key }) {
                    if let entry = try await cache.execution(id: key, owner: route.owner) {
                        entries.append(entry)
                    }
                }
            }
            guard generation == recoveryGeneration, owner == route.account,
                  session()?.owner == route.account else { return }
            recoveryEntries[value.id] = entries.map { entry in
                guard let identity = entry.audit?.identity else { return entry }
                // Local history is shared on this Mac, execution authority is not.
                guard identity.owner == route.account, identity.conversationId == value.id else {
                    return .init(id: entry.id, audit: nil, receipt: nil)
                }
                return entry
            }
        } catch {
            guard generation == recoveryGeneration, owner == route.account else { return }
            // A failed read is not an empty journal and cannot authorize dispatch.
            recoveryEntries[value.id] = [.init(id: "unavailable", audit: nil, receipt: nil)]
            self.error = L("ask.cache.failed")
        }
    }

    /// User-requested delivery only. Does not call drive, retry, tools or a model.
    func retransmitSavedReceipts() async {
        guard !recoveryWorking, let value = selected, !busyIds.contains(value.id),
              let current = credentials(for: value.id) else { return }
        let generation = recoveryGeneration
        recoveryWorking = true
        defer {
            if generation == recoveryGeneration {
                recoveryWorking = false
            }
        }
        do {
            let latest = try await api.conversation(id: value.id, token: current.token)
            try await accept(latest, route: current)
            await refreshRecovery(latest, route: current)
            for entry in recoveryEntries[value.id] ?? [] where !entry.acknowledged {
                try Task.checkCancellation()
                guard generation == recoveryGeneration, session()?.owner == current.account,
                      selectedId == value.id else { throw CancellationError() }
                guard let response = try await transmit(
                    entry,
                    latest: latest,
                    current: current,
                    generation: generation
                ) else { continue }
                try await cache.recordExecution(id: entry.id, event: .acknowledged, owner: current.owner)
                try await accept(response, route: current)
                logRecovery(entry, event: .acknowledged)
            }
            await refreshRecovery(latest, route: current)
        } catch is CancellationError {} catch {
            await reportOperationError(error, id: value.id, owner: current.account)
        }
    }

    private func transmit(
        _ entry: AskExecutionEntry,
        latest: AskConversation,
        current: AskRoute,
        generation: UUID
    ) async throws -> AskConversation? {
        guard let identity = entry.audit?.identity, identity.owner == current.account,
              identity.conversationId == latest.id, identity.deviceId == deviceId,
              entry.permits(identity), let receipt = entry.receipt else { return nil }
        try await cache.recordExecution(id: entry.id, event: .retransmitting, owner: current.owner)
        guard generation == recoveryGeneration, session()?.owner == current.account else { throw CancellationError() }
        switch receipt {
        case let .tool(request):
            guard latest.run?.id == identity.runId, latest.run?.deviceId == deviceId else { return nil }
            return try await api.result(conversationId: latest.id, request: request, token: current.token)
        case let .inference(request):
            // A known old inference may settle usage without restoring its content.
            return try await api.inferenceResult(conversationId: latest.id, request: request, token: current.token)
        }
    }

    /// Ends only the inspected run. This never asserts that an unknown effect succeeded.
    func endRecoveryRun() async {
        guard !recoveryWorking, let value = selected, let run = value.run, run.isActive,
              !busyIds.contains(value.id), let current = credentials(for: value.id) else { return }
        let generation = recoveryGeneration
        recoveryWorking = true
        defer {
            if generation == recoveryGeneration {
                recoveryWorking = false
            }
        }
        do {
            let response = try await api.cancel(conversationId: value.id, runId: run.id, token: current.token)
            try await accept(response, route: current)
            for entry in recoveryEntries[value.id] ?? [] where entry.audit?.identity.runId == run.id {
                try await cache.recordExecution(id: entry.id, event: .ended, owner: current.owner)
                logRecovery(entry, event: .ended)
            }
            await refreshRecovery(response, route: current)
        } catch { await reportOperationError(error, id: value.id, owner: current.account) }
    }

    /// "Check and continue": ends the uncertain run when it is still active, then
    /// starts a new one that first inspects what already happened. The uncertain
    /// step itself is never replayed; the new run decides from what it finds.
    func checkAndContinueRecovery() async {
        guard !recoveryWorking, let value = selected, !busyIds.contains(value.id),
              !recoveryPresentation.otherDevice else { return }
        if value.run?.isActive == true {
            await endRecoveryRun()
            guard selectedId == value.id, selected?.run?.isActive == false else { return }
        }
        inspectingRecovery = false
        sendFollowUp(L("ask.recovery.checkPrompt"))
    }

    /// Runs the action the user picked on the recovery card or in the inspector.
    func performRecovery(_ action: AskRecoveryAction) {
        switch action {
        case .checkAndContinue: Task { await checkAndContinueRecovery() }
        case .refresh: inspectingRecovery = false; Task { await retransmitSavedReceipts() }
        case .continueRun: inspectingRecovery = false; resume()
        case .selfCheck: dismissRecoveryInspector()
        case .stop: Task { await endRecoveryRun() }
        }
    }

    /// Returning to the conversation does not confirm an outcome or start any work.
    func dismissRecoveryInspector() {
        guard !recoveryWorking else { return }
        inspectingRecovery = false
    }

    func logRecovery(_ entry: AskExecutionEntry, event: AskExecutionAudit.Event) {
        guard let diagnostic = entry.diagnostic,
              let bytes = try? AskCoding.encoder().encode(diagnostic),
              let text = String(data: bytes, encoding: .utf8) else { return }
        NetworkDebugLogger.logMessage("[Ask Recovery] \(event.rawValue) \(text)")
    }
}
