import Foundation

struct HistoryPipelineTiming: Codable, Equatable {
    var recordingStoppedAt: Date?
    var audioFileReadyAt: Date?
    var transcriptionStartedAt: Date?
    var transcriptionCompletedAt: Date?
    var llmProcessingStartedAt: Date?
    var llmProcessingCompletedAt: Date?
    var applyStartedAt: Date?
    var applyCompletedAt: Date?

    var hasData: Bool {
        recordingStoppedAt != nil ||
            audioFileReadyAt != nil ||
            transcriptionStartedAt != nil ||
            transcriptionCompletedAt != nil ||
            llmProcessingStartedAt != nil ||
            llmProcessingCompletedAt != nil ||
            applyStartedAt != nil ||
            applyCompletedAt != nil
    }

    func millisecondsBetween(_ start: Date?, _ end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    func generatedStats() -> HistoryPipelineStats {
        HistoryPipelineStats(
            recordingStoppedAt: recordingStoppedAt,
            audioFileReadyAt: audioFileReadyAt,
            transcriptionStartedAt: transcriptionStartedAt,
            transcriptionCompletedAt: transcriptionCompletedAt,
            llmProcessingStartedAt: llmProcessingStartedAt,
            llmProcessingCompletedAt: llmProcessingCompletedAt,
            applyStartedAt: applyStartedAt,
            applyCompletedAt: applyCompletedAt,
            stopToAudioReadyMilliseconds: millisecondsBetween(recordingStoppedAt, audioFileReadyAt),
            transcriptionDurationMilliseconds: millisecondsBetween(transcriptionStartedAt, transcriptionCompletedAt),
            stopToTranscriptionCompletedMilliseconds: millisecondsBetween(recordingStoppedAt, transcriptionCompletedAt),
            transcriptToLLMStartMilliseconds: millisecondsBetween(transcriptionCompletedAt, llmProcessingStartedAt),
            llmDurationMilliseconds: millisecondsBetween(llmProcessingStartedAt, llmProcessingCompletedAt),
            applyDurationMilliseconds: millisecondsBetween(applyStartedAt, applyCompletedAt),
            endToEndMilliseconds: millisecondsBetween(
                recordingStoppedAt,
                applyCompletedAt ?? llmProcessingCompletedAt ?? transcriptionCompletedAt,
            ),
        )
    }
}

struct HistoryPipelineStats: Codable, Equatable {
    var recordingStoppedAt: Date?
    var audioFileReadyAt: Date?
    var transcriptionStartedAt: Date?
    var transcriptionCompletedAt: Date?
    var llmProcessingStartedAt: Date?
    var llmProcessingCompletedAt: Date?
    var applyStartedAt: Date?
    var applyCompletedAt: Date?
    var stopToAudioReadyMilliseconds: Int?
    var transcriptionDurationMilliseconds: Int?
    var stopToTranscriptionCompletedMilliseconds: Int?
    var transcriptToLLMStartMilliseconds: Int?
    var llmDurationMilliseconds: Int?
    var applyDurationMilliseconds: Int?
    var endToEndMilliseconds: Int?

    var hasData: Bool {
        recordingStoppedAt != nil ||
            audioFileReadyAt != nil ||
            transcriptionStartedAt != nil ||
            transcriptionCompletedAt != nil ||
            llmProcessingStartedAt != nil ||
            llmProcessingCompletedAt != nil ||
            applyStartedAt != nil ||
            applyCompletedAt != nil ||
            stopToAudioReadyMilliseconds != nil ||
            transcriptionDurationMilliseconds != nil ||
            stopToTranscriptionCompletedMilliseconds != nil ||
            transcriptToLLMStartMilliseconds != nil ||
            llmDurationMilliseconds != nil ||
            applyDurationMilliseconds != nil ||
            endToEndMilliseconds != nil
    }
}

struct HistoryRecord: Codable, Identifiable {
    enum Mode: String, Codable {
        case dictation
        case personaRewrite
        case editSelection
        case askAnswer
    }

    enum StepStatus: String, Codable {
        case pending
        case running
        case succeeded
        case failed
        case skipped
    }

    let id: UUID
    var date: Date
    var mode: Mode
    var audioFilePath: String?
    var transcriptText: String?
    var personaPrompt: String?
    var personaResultText: String?
    var selectionOriginalText: String?
    var selectionEditedText: String?
    var recordingDurationSeconds: TimeInterval?
    var pipelineTiming: HistoryPipelineTiming?
    var pipelineStats: HistoryPipelineStats?
    var errorMessage: String?
    var applyMessage: String?
    var recordingStatus: StepStatus
    var transcriptionStatus: StepStatus
    var processingStatus: StepStatus
    var applyStatus: StepStatus

    init(
        id: UUID = UUID(),
        date: Date,
        mode: Mode = .dictation,
        audioFilePath: String? = nil,
        transcriptText: String? = nil,
        personaPrompt: String? = nil,
        personaResultText: String? = nil,
        selectionOriginalText: String? = nil,
        selectionEditedText: String? = nil,
        recordingDurationSeconds: TimeInterval? = nil,
        pipelineTiming: HistoryPipelineTiming? = nil,
        pipelineStats: HistoryPipelineStats? = nil,
        errorMessage: String? = nil,
        applyMessage: String? = nil,
        recordingStatus: StepStatus = .pending,
        transcriptionStatus: StepStatus = .pending,
        processingStatus: StepStatus = .pending,
        applyStatus: StepStatus = .pending,
    ) {
        self.id = id
        self.date = date
        self.audioFilePath = audioFilePath
        self.mode = mode
        self.transcriptText = transcriptText
        self.personaPrompt = personaPrompt
        self.personaResultText = personaResultText
        self.selectionOriginalText = selectionOriginalText
        self.selectionEditedText = selectionEditedText
        self.recordingDurationSeconds = recordingDurationSeconds
        self.pipelineTiming = pipelineTiming
        self.pipelineStats = pipelineStats ?? pipelineTiming?.generatedStats()
        self.errorMessage = errorMessage
        self.applyMessage = applyMessage
        self.recordingStatus = recordingStatus
        self.transcriptionStatus = transcriptionStatus
        self.processingStatus = processingStatus
        self.applyStatus = applyStatus
    }

    var text: String {
        selectionEditedText ?? personaResultText ?? transcriptText ?? errorMessage ?? ""
    }

    var finalText: String? {
        selectionEditedText ?? personaResultText ?? transcriptText
    }

    var hasFailure: Bool {
        recordingStatus == .failed ||
            transcriptionStatus == .failed ||
            processingStatus == .failed ||
            applyStatus == .failed ||
            !(errorMessage?.isEmpty ?? true)
    }

    var hasProcessingDetails: Bool {
        !(transcriptText?.isEmpty ?? true) ||
            !(personaResultText?.isEmpty ?? true) ||
            !(selectionOriginalText?.isEmpty ?? true) ||
            !(selectionEditedText?.isEmpty ?? true) ||
            (pipelineTiming?.hasData ?? false) ||
            (pipelineStats?.hasData ?? false) ||
            !(errorMessage?.isEmpty ?? true) ||
            !(applyMessage?.isEmpty ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case mode
        case audioFilePath
        case transcriptText
        case personaPrompt
        case personaResultText
        case selectionOriginalText
        case selectionEditedText
        case recordingDurationSeconds
        case pipelineTiming
        case pipelineStats
        case errorMessage
        case applyMessage
        case recordingStatus
        case transcriptionStatus
        case processingStatus
        case applyStatus
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .dictation
        audioFilePath = try container.decodeIfPresent(String.self, forKey: .audioFilePath)

        let legacyText = try container.decodeIfPresent(String.self, forKey: .text)
        transcriptText = try container.decodeIfPresent(String.self, forKey: .transcriptText) ?? legacyText
        personaPrompt = try container.decodeIfPresent(String.self, forKey: .personaPrompt)
        personaResultText = try container.decodeIfPresent(String.self, forKey: .personaResultText)
        selectionOriginalText = try container.decodeIfPresent(String.self, forKey: .selectionOriginalText)
        selectionEditedText = try container.decodeIfPresent(String.self, forKey: .selectionEditedText)
        recordingDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .recordingDurationSeconds)
        pipelineTiming = try container.decodeIfPresent(HistoryPipelineTiming.self, forKey: .pipelineTiming)
        pipelineStats = try container.decodeIfPresent(HistoryPipelineStats.self, forKey: .pipelineStats)
            ?? pipelineTiming?.generatedStats()
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        applyMessage = try container.decodeIfPresent(String.self, forKey: .applyMessage)
        recordingStatus = try container.decodeIfPresent(StepStatus.self, forKey: .recordingStatus) ?? .succeeded
        transcriptionStatus = try container.decodeIfPresent(StepStatus.self, forKey: .transcriptionStatus) ?? (legacyText == nil ? .pending : .succeeded)
        processingStatus = try container.decodeIfPresent(StepStatus.self, forKey: .processingStatus) ?? .skipped
        applyStatus = try container.decodeIfPresent(StepStatus.self, forKey: .applyStatus) ?? (legacyText == nil ? .pending : .succeeded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(audioFilePath, forKey: .audioFilePath)
        try container.encodeIfPresent(transcriptText, forKey: .transcriptText)
        try container.encodeIfPresent(personaPrompt, forKey: .personaPrompt)
        try container.encodeIfPresent(personaResultText, forKey: .personaResultText)
        try container.encodeIfPresent(selectionOriginalText, forKey: .selectionOriginalText)
        try container.encodeIfPresent(selectionEditedText, forKey: .selectionEditedText)
        try container.encodeIfPresent(recordingDurationSeconds, forKey: .recordingDurationSeconds)
        try container.encodeIfPresent(pipelineTiming, forKey: .pipelineTiming)
        try container.encodeIfPresent(pipelineStats, forKey: .pipelineStats)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(applyMessage, forKey: .applyMessage)
        try container.encode(recordingStatus, forKey: .recordingStatus)
        try container.encode(transcriptionStatus, forKey: .transcriptionStatus)
        try container.encode(processingStatus, forKey: .processingStatus)
        try container.encode(applyStatus, forKey: .applyStatus)
    }
}

protocol HistoryStore {
    func save(record: HistoryRecord)
    func list() -> [HistoryRecord]
    func list(limit: Int, offset: Int, searchQuery: String?) -> [HistoryRecord]
    func record(id: UUID) -> HistoryRecord?
    func delete(id: UUID)
    func purge(olderThanDays days: Int)
    func clear()
    func exportMarkdown() throws -> URL
}

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("historyStoreDidChange")
}
