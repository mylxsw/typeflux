import Foundation

extension AskConversationModel {
    var selectedRecoveryEntries: [AskExecutionEntry] {
        selectedId.flatMap { recoveryEntries[$0] } ?? []
    }

    func recoveryBlocksResume(_ value: AskConversation) -> Bool {
        if value.run?.status == "completed" { return false }
        return value.run?.needsRecoveryInspection == true || (recoveryEntries[value.id] ?? []).contains {
            ($0.audit?.identity.runId == value.run?.id || $0.audit == nil) && $0.needsInspection(run: value.run)
        }
    }

    var recoveryPresentation: AskRecoveryPresentation {
        if let cachedRecoveryPresentation { return cachedRecoveryPresentation }
        let value = AskRecoveryPresentation(run: selected?.run, entries: selectedRecoveryEntries, deviceId: deviceId,
                                            local: selected.map { isLocal($0.id) } ?? false)
        cachedRecoveryPresentation = value
        recordRecoveryPresentationBuild()
        return value
    }

    /// The single state every run indicator reads; see `AskRunPhase`.
    var runPhase: AskRunPhase? {
        guard let value = selected else { return nil }
        return AskRunPhase.resolve(run: value.run, busy: busyIds.contains(value.id),
                                   pendingApproval: pendingApprovals[value.id] != nil,
                                   recovery: recoveryPresentation,
                                   storageUnavailable: selectedRecoveryEntries.contains(where: \.readUnavailable))
    }

    var hasRecoveryNotice: Bool {
        selectedId.map { !busyIds.contains($0) } == true && recoveryPresentation.isVisible
    }

    var hasRecoveryDetails: Bool {
        hasRecoveryNotice && recoveryDetails.hasUsefulDetails
    }

    func inspectRecoveryDetails() {
        inspectingRecovery = hasRecoveryDetails
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

    /// Reconcile saved results, then inspect uncertain effects within the same task.
    /// No user message is manufactured and no uncertain effect is replayed.
    func recoverWithoutUser() async {
        guard automaticRecoveryEnabled, let value = selected, !externallyDrivenConversations.contains(value.id),
              let run = value.run, !isLoadingSelection,
              !busyIds.contains(value.id), !recoveryWorking,
              !selectedRecoveryEntries.contains(where: \.readUnavailable),
              !recoveryPresentation.otherDevice else { return }
        let key = value.id + "/" + run.id
        if canRetransmitReceipts {
            let receiptIDs = selectedRecoveryEntries.filter { !$0.acknowledged && $0.receipt != nil }
                .map(\.id).sorted().joined(separator: ",")
            guard automaticRecoveryAttempts.insert(key + "/receipt/" + receiptIDs).inserted else { return }
            await retransmitSavedReceipts()
            guard !canRetransmitReceipts else { return }
        }
        guard selectedId == value.id, selected?.run?.id == run.id else { return }
        if recoveryPresentation.unknown {
            guard automaticRecoveryAttempts.count(where: { $0.hasPrefix(key + "/inspect/") }) < 2 else { return }
            let checkpoint = selected?.run?.inference?.id ?? String(selected?.revision ?? 0)
            guard automaticRecoveryAttempts.insert(key + "/inspect/" + checkpoint).inserted else { return }
            startInternalRecovery()
        } else if selected?.run?.internalRecovery?.phase == .inspecting, selected?.run?.isActive == true {
            guard automaticRecoveryAttempts.insert(key + "/continue-inspection/" + String(selected?.revision ?? 0))
                .inserted else { return }
            resume()
        }
    }

    /// Observation may publish the settled run before its receipt is acknowledged.
    /// Refresh the journal here even if the next snapshot has the same revision
    /// and accept() therefore skips it.
    func acknowledgeExecution(_ identity: AskExecutionIdentity, response: AskConversation,
                              current: AskRoute) async throws {
        try await cache.recordExecution(id: identity.key, event: .acknowledged, owner: current.owner)
        await refreshRecovery(response, route: current)
    }

    /// User-requested delivery only. Does not call drive, retry, tools or a model.
    func retransmitSavedReceipts() async {
        guard !recoveryWorking, let value = selected, !busyIds.contains(value.id),
              let current = credentials(for: value.id) else { return }
        let generation = recoveryGeneration
        let operation = operationGenerations[value.id]
        recoveryWorking = true
        defer {
            if generation == recoveryGeneration {
                recoveryWorking = false
            }
        }
        do {
            let latest = try await api.conversation(id: value.id, token: current.token)
            guard generation == recoveryGeneration, operationGenerations[value.id] == operation,
                  session()?.owner == current.account else { throw CancellationError() }
            _ = try AskAgentBinding.resolve(latest.run?.agentBinding)
            try await accept(latest, route: current)
            guard generation == recoveryGeneration, operationGenerations[value.id] == operation,
                  session()?.owner == current.account else { throw CancellationError() }
            await refreshRecovery(latest, route: current)
            for entry in recoveryEntries[value.id] ?? [] where !entry.acknowledged {
                try Task.checkCancellation()
                guard generation == recoveryGeneration, operationGenerations[value.id] == operation,
                      session()?.owner == current.account,
                      selectedId == value.id else { throw CancellationError() }
                guard let response = try await transmit(
                    entry,
                    latest: latest,
                    current: current,
                    generation: generation,
                    operation: operation
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
        generation: UUID,
        operation: UUID?
    ) async throws -> AskConversation? {
        guard let identity = entry.audit?.identity, identity.owner == current.account,
              identity.conversationId == latest.id, identity.deviceId == deviceId,
              entry.permits(identity), let receipt = entry.receipt else { return nil }
        try await cache.recordExecution(id: entry.id, event: .retransmitting, owner: current.owner)
        guard generation == recoveryGeneration, operationGenerations[latest.id] == operation,
              session()?.owner == current.account else { throw CancellationError() }
        switch receipt {
        case let .tool(request):
            guard request.approveExecution == true ||
                (latest.run?.id == identity.runId && latest.run?.deviceId == deviceId) else { return nil }
            return try await sendToolResult(request, identity: identity, current: current, operationId: operation)
        case let .inference(request):
            // A known old inference may settle usage without restoring its content.
            return try await api.inferenceResult(conversationId: latest.id, request: request, token: current.token)
        }
    }

    /// Ends only the inspected run. This never asserts that an unknown effect succeeded.
    func endRecoveryRun() async {
        guard !recoveryWorking, let value = selected, let run = value.run, run.isActive,
              !busyIds.contains(value.id), let current = credentials(for: value.id) else { return }
        guard admitAgentCommand(value) else { return }
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

    /// Manual retry uses the same internal continuation as automatic recovery.
    func checkAndContinueRecovery() async {
        inspectingRecovery = false
        startInternalRecovery()
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
