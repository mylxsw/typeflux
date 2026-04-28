// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity line_length
import AVFoundation
import Foundation

public enum TypefluxBatchCommand {
    public static func run(arguments: [String]) async -> Int {
        do {
            if arguments.contains("--help") || arguments.contains("-h") {
                FileHandle.standardOutput.write(Data((BatchConfiguration.helpText + "\n").utf8))
                return 0
            }
            let config = try BatchConfiguration(arguments: arguments)
            try await WAVPersonaBenchmark(config: config).run()
            return 0
        } catch let error as BatchCommandError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data(("Error: \(error.localizedDescription)\n").utf8))
            return 1
        }
    }
}

private struct BatchCommandError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct BatchConfiguration {
    let inputDirectory: URL
    let outputURL: URL
    let stateURL: URL
    let resume: Bool
    let retryFailed: Bool
    let sttProviderOverride: STTProvider?
    let localSTTModelOverride: LocalSTTModel?
    let personaSelector: PersonaSelector?
    let noPersona: Bool

    init(arguments: [String]) throws {
        var parser = ArgumentParser(arguments: arguments)

        guard let input = parser.consumeValue("--input") else {
            throw BatchCommandError(message: "Missing required argument: --input\n\n\(Self.helpText)")
        }
        guard let output = parser.consumeValue("--output") else {
            throw BatchCommandError(message: "Missing required argument: --output\n\n\(Self.helpText)")
        }

        inputDirectory = Self.resolvedURL(input, isDirectory: true)
        outputURL = Self.resolvedURL(output, isDirectory: false)
        let explicitState = parser.consumeValue("--state")
        stateURL = explicitState.map { Self.resolvedURL($0, isDirectory: false) }
            ?? Self.defaultStateURL(for: outputURL)
        resume = parser.consumeFlag("--resume")
        retryFailed = parser.consumeFlag("--retry-failed")
        noPersona = parser.consumeFlag("--no-persona")

        if let raw = parser.consumeValue("--stt-provider") {
            guard let provider = STTProvider(rawValue: raw) else {
                throw BatchCommandError(message: "Unsupported --stt-provider value: \(raw)")
            }
            sttProviderOverride = provider
        } else {
            sttProviderOverride = nil
        }

        if let raw = parser.consumeValue("--local-stt-model") {
            guard let model = LocalSTTModel(rawValue: raw) else {
                throw BatchCommandError(message: "Unsupported --local-stt-model value: \(raw)")
            }
            localSTTModelOverride = model
        } else {
            localSTTModelOverride = nil
        }

        let personaID = parser.consumeValue("--persona-id")
        let personaName = parser.consumeValue("--persona-name")
        let personaPromptFile = parser.consumeValue("--persona-prompt-file")
        let selectors = [personaID, personaName, personaPromptFile].compactMap { $0 }
        guard selectors.count <= 1 else {
            throw BatchCommandError(message: "Use only one persona selector: --persona-id, --persona-name, or --persona-prompt-file.")
        }
        if let personaID {
            guard let uuid = UUID(uuidString: personaID) else {
                throw BatchCommandError(message: "Invalid --persona-id value: \(personaID)")
            }
            personaSelector = .id(uuid)
        } else if let personaName {
            personaSelector = .name(personaName)
        } else if let personaPromptFile {
            personaSelector = .promptFile(Self.resolvedURL(personaPromptFile, isDirectory: false))
        } else {
            personaSelector = nil
        }

        let remaining = parser.remaining
        guard remaining.isEmpty else {
            throw BatchCommandError(message: "Unexpected arguments: \(remaining.joined(separator: " "))")
        }
    }

    private static func resolvedURL(_ path: String, isDirectory: Bool) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: isDirectory)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: isDirectory)
    }

    private static func defaultStateURL(for outputURL: URL) -> URL {
        URL(fileURLWithPath: outputURL.path + ".state.json")
    }

    fileprivate static let helpText = """
    Usage:
      Typeflux batch-wav --input <wav-directory> --output <report.csv> [options]

    Options:
      --resume                         Continue from the default or explicit state file.
      --retry-failed                   Retry rows previously marked failed.
      --state <path>                   Override the default state path. Defaults to <output>.state.json.
      --stt-provider <rawValue>        Override the app STT provider for this run.
      --local-stt-model <rawValue>     Override the local STT model for this run.
      --persona-id <uuid>              Use a specific saved persona.
      --persona-name <name>            Use a specific saved persona by name.
      --persona-prompt-file <path>     Use a prompt file instead of a saved persona.
      --no-persona                     Only transcribe; write the transcript as the final result.
    """
}

private enum PersonaSelector {
    case id(UUID)
    case name(String)
    case promptFile(URL)
}

private struct ArgumentParser {
    private var arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    var remaining: [String] { arguments }

    mutating func consumeFlag(_ flag: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        arguments.remove(at: index)
        return true
    }

    mutating func consumeValue(_ option: String) -> String? {
        guard let index = arguments.firstIndex(of: option) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex]
        arguments.remove(at: valueIndex)
        arguments.remove(at: index)
        return value
    }
}

private final class WAVPersonaBenchmark {
    private let config: BatchConfiguration
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(config: BatchConfiguration) {
        self.config = config
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func run() async throws {
        guard directoryExists(config.inputDirectory) else {
            throw BatchCommandError(message: "Input directory does not exist: \(config.inputDirectory.path)")
        }

        try ensureParentDirectoryExists(for: config.outputURL)
        try ensureParentDirectoryExists(for: config.stateURL)

        let settingsStore = makeSettingsStore()
        let persona = try resolvePersona(settingsStore: settingsStore)
        let sttRouter = makeSTTRouter(settingsStore: settingsStore)
        let llmService = makeLLMService(settingsStore: settingsStore)
        let files = try discoverWAVFiles(in: config.inputDirectory)
        guard !files.isEmpty else {
            throw BatchCommandError(message: "No WAV files found in: \(config.inputDirectory.path)")
        }

        var state = try loadState()
        state.inputDirectory = config.inputDirectory.path
        state.outputPath = config.outputURL.path
        state.statePath = config.stateURL.path
        state.updatedAt = Date()
        state.records = state.records.filter { record in
            files.contains { $0.relativePath == record.relativePath }
        }

        try save(state)
        try writeReport(state: state, files: files)

        for file in files {
            if Task.isCancelled { throw CancellationError() }
            var record = state.records.first(where: { $0.relativePath == file.relativePath })
                ?? BenchmarkRecord(
                    relativePath: file.relativePath,
                    absolutePath: file.url.path,
                    status: .pending,
                )
            record.absolutePath = file.url.path
            record.fileSizeBytes = file.fileSizeBytes
            record.sttProvider = settingsStore.sttProvider.rawValue
            record.sttModel = sttModelDescription(settingsStore: settingsStore)
            record.llmProvider = llmProviderDescription(settingsStore: settingsStore)
            record.llmModel = llmModelDescription(settingsStore: settingsStore)
            record.persona = persona.name

            if shouldSkip(record) {
                upsert(record, into: &state)
                try save(state)
                try writeReport(state: state, files: files)
                continue
            }

            record.error = nil

            do {
                let audioFile = try makeAudioFile(file.url)
                record.audioDurationSeconds = audioFile.duration

                if record.transcript?.isEmpty != false {
                    record.status = .transcribing
                    record.startedAt = record.startedAt ?? Date()
                    upsert(record, into: &state)
                    try save(state)
                    print("Transcribing \(file.relativePath)")

                    let startedAt = Date()
                    let transcript = try await sttRouter.transcribeStream(audioFile: audioFile, scenario: .voiceInput) { _ in }
                    record.sttMilliseconds = milliseconds(since: startedAt)
                    record.transcript = transcript
                    record.status = .transcribed
                    record.updatedAt = Date()
                    upsert(record, into: &state)
                    try save(state)
                    try writeReport(state: state, files: files)
                } else {
                    record.status = .transcribed
                }

                let transcript = record.transcript ?? ""
                if persona.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.personaResult = transcript
                    record.llmMilliseconds = 0
                } else {
                    guard settingsStore.isLLMConfigured else {
                        throw BatchCommandError(message: "LLM is not configured for persona rewriting.")
                    }

                    record.status = .rewriting
                    record.updatedAt = Date()
                    upsert(record, into: &state)
                    try save(state)
                    print("Rewriting \(file.relativePath)")

                    let startedAt = Date()
                    record.personaResult = try await rewrite(
                        transcript: transcript,
                        personaPrompt: persona.prompt,
                        llmService: llmService,
                    )
                    record.llmMilliseconds = milliseconds(since: startedAt)
                }

                record.totalMilliseconds = (record.sttMilliseconds ?? 0) + (record.llmMilliseconds ?? 0)
                record.status = .completed
                record.completedAt = Date()
                record.updatedAt = Date()
                upsert(record, into: &state)
                try save(state)
                try writeReport(state: state, files: files)
            } catch {
                record.status = .failed
                record.error = error.localizedDescription
                record.updatedAt = Date()
                upsert(record, into: &state)
                try save(state)
                try writeReport(state: state, files: files)
                print("Failed \(file.relativePath): \(error.localizedDescription)")
            }
        }

        print("Report written: \(config.outputURL.path)")
        print("State written: \(config.stateURL.path)")
    }

    private func makeSettingsStore() -> SettingsStore {
        let sourceSuite = ProcessInfo.processInfo.environment["TYPEFLUX_USER_DEFAULTS_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceDefaults = sourceSuite.flatMap(UserDefaults.init(suiteName:))
            ?? UserDefaults(suiteName: "ai.gulu.app.typeflux")
            ?? .standard
        let batchSuite = "ai.gulu.app.typeflux.batch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: batchSuite) ?? .standard
        sourceDefaults.dictionaryRepresentation().forEach { key, value in
            defaults.set(value, forKey: key)
        }
        if let sttProviderOverride = config.sttProviderOverride {
            defaults.set(sttProviderOverride.rawValue, forKey: "stt.provider")
        }
        if let localSTTModelOverride = config.localSTTModelOverride {
            defaults.set(localSTTModelOverride.rawValue, forKey: "stt.local.model")
            defaults.set(localSTTModelOverride.defaultModelIdentifier, forKey: "stt.local.modelIdentifier")
        }
        return SettingsStore(defaults: defaults)
    }

    private func makeSTTRouter(settingsStore: SettingsStore) -> STTRouter {
        let localModelManager = LocalModelManager()
        return STTRouter(
            settingsStore: settingsStore,
            whisper: WhisperAPITranscriber(settingsStore: settingsStore),
            freeSTT: FreeSTTTranscriber(settingsStore: settingsStore),
            appleSpeech: AppleSpeechTranscriber(),
            localModel: LocalModelTranscriber(settingsStore: settingsStore, modelManager: localModelManager),
            multimodal: MultimodalLLMTranscriber(settingsStore: settingsStore),
            aliCloud: AliCloudRealtimeTranscriber(settingsStore: settingsStore),
            doubaoRealtime: DoubaoRealtimeTranscriber(settingsStore: settingsStore),
            googleCloud: GoogleCloudSpeechTranscriber(settingsStore: settingsStore),
            groq: WhisperAPITranscriber(
                settingsStore: settingsStore,
                baseURLOverride: "https://api.groq.com/openai/v1",
                apiKeyOverride: { [settingsStore] in settingsStore.groqSTTAPIKey },
                modelOverride: { [settingsStore] in settingsStore.groqSTTModel },
            ),
            typefluxOfficial: TypefluxOfficialTranscriber(),
        )
    }

    private func makeLLMService(settingsStore: SettingsStore) -> LLMService {
        LLMRouter(
            settingsStore: settingsStore,
            openAICompatible: OpenAICompatibleLLMService(settingsStore: settingsStore),
            ollama: OllamaLLMService(settingsStore: settingsStore, modelManager: OllamaLocalModelManager()),
        )
    }

    private func resolvePersona(settingsStore: SettingsStore) throws -> (name: String, prompt: String) {
        if config.noPersona {
            return ("none", "")
        }

        switch config.personaSelector {
        case .id(let id):
            guard let persona = settingsStore.personas.first(where: { $0.id == id }) else {
                throw BatchCommandError(message: "No saved persona found for id: \(id.uuidString)")
            }
            return (persona.name, settingsStore.resolvedPersonaPrompt(for: persona))
        case .name(let name):
            guard let persona = settingsStore.personas.first(where: { $0.name == name }) else {
                throw BatchCommandError(message: "No saved persona found named: \(name)")
            }
            return (persona.name, settingsStore.resolvedPersonaPrompt(for: persona))
        case .promptFile(let url):
            let prompt = try String(contentsOf: url, encoding: .utf8)
            return (url.lastPathComponent, prompt)
        case .none:
            guard let persona = settingsStore.activePersona else {
                return ("none", "")
            }
            return (persona.name, settingsStore.resolvedPersonaPrompt(for: persona))
        }
    }

    private func discoverWAVFiles(in directory: URL) throws -> [InputWAVFile] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        ) else {
            return []
        }

        var files: [InputWAVFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "wav" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            files.append(InputWAVFile(
                url: url,
                relativePath: relativePath(for: url, base: directory),
                fileSizeBytes: Int64(values.fileSize ?? 0),
            ))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func makeAudioFile(_ url: URL) throws -> AudioFile {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        return AudioFile(fileURL: url, duration: duration)
    }

    private func rewrite(transcript: String, personaPrompt: String, llmService: LLMService) async throws -> String {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: transcript,
            spokenInstruction: nil,
            personaPrompt: personaPrompt,
            vocabularyTerms: VocabularyStore.activeTerms(),
        )

        var output = ""
        let stream = llmService.streamRewrite(request: request)
        for try await chunk in stream {
            output += chunk
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldSkip(_ record: BenchmarkRecord) -> Bool {
        switch record.status {
        case .completed:
            return config.resume
        case .failed:
            return config.resume && !config.retryFailed
        case .pending, .transcribing, .transcribed, .rewriting:
            return false
        }
    }

    private func loadState() throws -> BenchmarkState {
        guard config.resume, fileManager.fileExists(atPath: config.stateURL.path) else {
            return BenchmarkState()
        }
        let data = try Data(contentsOf: config.stateURL)
        return try decoder.decode(BenchmarkState.self, from: data)
    }

    private func save(_ state: BenchmarkState) throws {
        var state = state
        state.updatedAt = Date()
        let data = try encoder.encode(state)
        try data.write(to: config.stateURL, options: .atomic)
    }

    private func writeReport(state: BenchmarkState, files: [InputWAVFile]) throws {
        let recordsByPath = Dictionary(uniqueKeysWithValues: state.records.map { ($0.relativePath, $0) })
        var lines: [String] = [
            [
                "file",
                "status",
                "audio_duration_s",
                "file_size_bytes",
                "stt_provider",
                "stt_model",
                "llm_provider",
                "llm_model",
                "persona",
                "stt_ms",
                "llm_ms",
                "total_ms",
                "stt_realtime_factor",
                "transcript",
                "persona_result",
                "error",
            ].map(csvEscape).joined(separator: ","),
        ]

        for file in files {
            let record = recordsByPath[file.relativePath] ?? BenchmarkRecord(
                relativePath: file.relativePath,
                absolutePath: file.url.path,
                status: .pending,
            )
            let realtimeFactor: String
            if let sttMs = record.sttMilliseconds,
               let duration = record.audioDurationSeconds,
               duration > 0 {
                realtimeFactor = String(format: "%.3f", Double(sttMs) / 1000 / duration)
            } else {
                realtimeFactor = ""
            }
            let row: [String] = [
                record.relativePath,
                record.status.rawValue,
                record.audioDurationSeconds.map { String(format: "%.3f", $0) } ?? "",
                record.fileSizeBytes.map(String.init) ?? "",
                record.sttProvider ?? "",
                record.sttModel ?? "",
                record.llmProvider ?? "",
                record.llmModel ?? "",
                record.persona ?? "",
                record.sttMilliseconds.map(String.init) ?? "",
                record.llmMilliseconds.map(String.init) ?? "",
                record.totalMilliseconds.map(String.init) ?? "",
                realtimeFactor,
                record.transcript ?? "",
                record.personaResult ?? "",
                record.error ?? "",
            ]
            lines.append(row.map(csvEscape).joined(separator: ","))
        }

        try (lines.joined(separator: "\n") + "\n").write(to: config.outputURL, atomically: true, encoding: .utf8)
    }

    private func upsert(_ record: BenchmarkRecord, into state: inout BenchmarkState) {
        if let index = state.records.firstIndex(where: { $0.relativePath == record.relativePath }) {
            state.records[index] = record
        } else {
            state.records.append(record)
        }
        state.records.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func ensureParentDirectoryExists(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func relativePath(for url: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return url.lastPathComponent }
        let start = path.index(path.startIndex, offsetBy: basePath.count)
        return String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func milliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func sttModelDescription(settingsStore: SettingsStore) -> String {
        switch settingsStore.sttProvider {
        case .freeModel:
            settingsStore.freeSTTModel
        case .whisperAPI:
            OpenAIAudioModelCatalog.resolvedWhisperModel(
                settingsStore.whisperModel,
                endpoint: OpenAIAudioModelCatalog.resolvedWhisperEndpoint(settingsStore.whisperBaseURL),
            )
        case .appleSpeech:
            "appleSpeech"
        case .localModel:
            settingsStore.localSTTModelIdentifier
        case .multimodalLLM:
            settingsStore.multimodalLLMModel
        case .aliCloud:
            settingsStore.aliCloudModel
        case .doubaoRealtime:
            settingsStore.doubaoResourceID
        case .googleCloud:
            settingsStore.googleCloudModel
        case .groq:
            settingsStore.groqSTTModel
        case .typefluxOfficial:
            "default"
        }
    }

    private func llmProviderDescription(settingsStore: SettingsStore) -> String {
        switch settingsStore.llmProvider {
        case .openAICompatible:
            settingsStore.llmRemoteProvider.rawValue
        case .ollama:
            "ollama"
        }
    }

    private func llmModelDescription(settingsStore: SettingsStore) -> String {
        switch settingsStore.llmProvider {
        case .openAICompatible:
            settingsStore.llmModel
        case .ollama:
            settingsStore.ollamaModel
        }
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

private struct InputWAVFile {
    let url: URL
    let relativePath: String
    let fileSizeBytes: Int64
}

private struct BenchmarkState: Codable {
    var version = 1
    var inputDirectory: String?
    var outputPath: String?
    var statePath: String?
    var updatedAt = Date()
    var records: [BenchmarkRecord] = []
}

private struct BenchmarkRecord: Codable {
    var relativePath: String
    var absolutePath: String
    var status: BenchmarkStatus
    var audioDurationSeconds: Double?
    var fileSizeBytes: Int64?
    var sttProvider: String?
    var sttModel: String?
    var llmProvider: String?
    var llmModel: String?
    var persona: String?
    var transcript: String?
    var personaResult: String?
    var error: String?
    var sttMilliseconds: Int?
    var llmMilliseconds: Int?
    var totalMilliseconds: Int?
    var startedAt: Date?
    var updatedAt: Date?
    var completedAt: Date?
}

private enum BenchmarkStatus: String, Codable {
    case pending
    case transcribing
    case transcribed
    case rewriting
    case completed
    case failed
}
