import Foundation

/// Records agent execution steps into an AgentJobStore.
/// Conforms to AgentStepMonitor to receive live step callbacks from AgentLoop.
final class AgentJobRecorder: AgentStepMonitor, @unchecked Sendable {
    private let store: AgentJobStore
    private let jobID: UUID
    private var steps: [AgentJobStep] = []
    private let lock = NSLock()

    /// The job ID being recorded. Use this to link the workflow to the stored job.
    var recordedJobID: UUID { jobID }

    init(store: AgentJobStore, jobID: UUID) {
        self.store = store
        self.jobID = jobID
    }

    /// Create the initial job record when the agent starts.
    func beginJob(userPrompt: String, selectedText: String?) async {
        let job = AgentJob(
            id: jobID,
            createdAt: Date(),
            status: .running,
            userPrompt: userPrompt,
            selectedText: selectedText
        )
        try? await store.save(job)
    }

    func agentDidCompleteStep(_ step: AgentStep) async {
        let jobStep = AgentJobStep(
            stepIndex: step.stepIndex,
            toolCalls: step.toolResults.enumerated().map { index, result in
                let toolCall = index < step.assistantMessage.toolCalls.count
                    ? step.assistantMessage.toolCalls[index]
                    : nil
                return AgentJobToolCall(
                    id: toolCall?.id ?? result.toolCallId,
                    name: toolCall?.name ?? "unknown",
                    argumentsJSON: toolCall?.argumentsJSON ?? "{}",
                    resultContent: result.content,
                    isError: result.isError
                )
            },
            assistantText: step.assistantMessage.text,
            durationMs: step.durationMs,
            tokenUsage: step.tokenUsage
        )

        let currentSteps = appendStepAndSnapshot(jobStep)

        // Persist intermediate progress
        if var job = try? await store.job(id: jobID) {
            job.steps = currentSteps
            try? await store.save(job)
        }
    }

    func agentDidFinish(outcome: AgentOutcome, totalTokenUsage: LLMTokenUsage?) async {
        let finalSteps = snapshotSteps()

        guard var job = try? await store.job(id: jobID) else { return }

        job.steps = finalSteps
        job.completedAt = Date()
        job.totalTokenUsage = totalTokenUsage

        switch outcome {
        case .text(let text):
            job.status = .completed
            job.resultText = text
            job.outcomeType = "text"
        case .terminationTool(let name, let args):
            job.status = .completed
            job.outcomeType = name
            if name == "answer_text" {
                job.resultText = extractStringField("answer", from: args)
            } else if name == "edit_text" {
                job.resultText = extractStringField("replacement", from: args)
            }
        case .maxStepsReached:
            job.status = .failed
            job.errorMessage = "Maximum steps reached"
            job.outcomeType = "maxStepsReached"
        case .error(let error):
            job.status = .failed
            job.errorMessage = error.localizedDescription
            job.outcomeType = "error"
        }

        if let createdAt = (try? await store.job(id: jobID))?.createdAt {
            job.totalDurationMs = Int64(Date().timeIntervalSince(createdAt) * 1000)
        }

        try? await store.save(job)
    }

    /// Mark the job as failed with an error message.
    func markFailed(error: Error) async {
        guard var job = try? await store.job(id: jobID) else { return }
        job.status = .failed
        job.completedAt = Date()
        job.errorMessage = error.localizedDescription
        job.outcomeType = "error"
        if let createdAt = job.createdAt as Date? {
            job.totalDurationMs = Int64(Date().timeIntervalSince(createdAt) * 1000)
        }
        try? await store.save(job)
    }

    private func extractStringField(_ field: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict[field] as? String
    }

    private func appendStepAndSnapshot(_ step: AgentJobStep) -> [AgentJobStep] {
        lock.lock()
        defer { lock.unlock() }

        steps.append(step)
        return steps
    }

    private func snapshotSteps() -> [AgentJobStep] {
        lock.lock()
        defer { lock.unlock() }

        return steps
    }
}
