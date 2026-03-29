import Foundation

private enum LocalSTTServiceManagerError: LocalizedError {
    case missingServerScript

    var errorDescription: String? {
        switch self {
        case .missingServerScript:
            return "Missing bundled local STT server script: local_stt_server.py."
        }
    }
}

struct LocalSTTPreparationUpdate {
    let message: String
    let progress: Double
    let storagePath: String
    let source: String?
}

struct LocalSTTPreparedModelInfo {
    let storagePath: String
    let sourceDisplayName: String
}

private struct LocalSTTPreparedRecord: Codable {
    let model: String
    let modelIdentifier: String
    let storagePath: String
    let source: String
}

struct LocalSTTConfiguration: Equatable {
    let model: LocalSTTModel
    let modelIdentifier: String
    let downloadSource: ModelDownloadSource
    let autoSetup: Bool

    init(model: LocalSTTModel, modelIdentifier: String, downloadSource: ModelDownloadSource, autoSetup: Bool) {
        self.model = model
        self.modelIdentifier = modelIdentifier
        self.downloadSource = downloadSource
        self.autoSetup = autoSetup
    }

    init(settingsStore: SettingsStore) {
        self.model = settingsStore.localSTTModel
        self.modelIdentifier = settingsStore.localSTTModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.downloadSource = settingsStore.localSTTDownloadSource
        self.autoSetup = settingsStore.localSTTAutoSetup
    }
}

final class LocalSTTServiceManager {
    private let commandRunner: ProcessCommandRunner
    private let session: URLSession
    private var serverProcess: Process?
    private var runningConfiguration: LocalSTTConfiguration?
    private let serverHost = "127.0.0.1"
    private let serverPort = 55123

    init(
        commandRunner: ProcessCommandRunner = ProcessCommandRunner(),
        session: URLSession = .shared
    ) {
        self.commandRunner = commandRunner
        self.session = session
    }

    var serverBaseURL: URL {
        URL(string: "http://\(serverHost):\(serverPort)/v1")!
    }

    var modelsRootPath: String {
        modelsRootURL.path
    }

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil
    ) async throws {
        let configuration = normalizedConfiguration(from: settingsStore)
        let initialPath = expectedStoragePath(for: configuration)
        onUpdate?(LocalSTTPreparationUpdate(
            message: "Preparing local runtime...",
            progress: 0.08,
            storagePath: initialPath,
            source: nil
        ))
        try await ensurePythonEnvironment()
        onUpdate?(LocalSTTPreparationUpdate(
            message: "Installing local speech dependencies...",
            progress: 0.3,
            storagePath: initialPath,
            source: nil
        ))
        try await ensurePackages(for: configuration)
        if let existing = existingPreparedModelInfo(for: configuration) {
            try savePreparedRecord(
                LocalSTTPreparedRecord(
                    model: configuration.model.rawValue,
                    modelIdentifier: configuration.modelIdentifier,
                    storagePath: existing.storagePath,
                    source: existing.source.rawValue
                )
            )
            onUpdate?(LocalSTTPreparationUpdate(
                message: "\(configuration.model.displayName) is ready.",
                progress: 1,
                storagePath: existing.storagePath,
                source: existing.source.displayName
            ))
            return
        }
        onUpdate?(LocalSTTPreparationUpdate(
            message: "Downloading and preparing \(configuration.model.displayName)...",
            progress: 0.68,
            storagePath: initialPath,
            source: nil
        ))
        let prepared = try await prepareRuntime(configuration: configuration)
        try savePreparedRecord(
            LocalSTTPreparedRecord(
                model: configuration.model.rawValue,
                modelIdentifier: configuration.modelIdentifier,
                storagePath: prepared.path,
                source: prepared.source
            )
        )
        onUpdate?(LocalSTTPreparationUpdate(
            message: "\(configuration.model.displayName) is ready.",
            progress: 1,
            storagePath: prepared.path,
            source: ModelDownloadSource(rawValue: prepared.source)?.displayName
        ))
    }

    func preparedModelInfo(settingsStore: SettingsStore) -> LocalSTTPreparedModelInfo? {
        let configuration = normalizedConfiguration(from: settingsStore)
        if
            let record = loadPreparedRecord(for: configuration),
            modelExists(at: record.storagePath, for: configuration.model)
        {
            return LocalSTTPreparedModelInfo(
                storagePath: record.storagePath,
                sourceDisplayName: ModelDownloadSource(rawValue: record.source)?.displayName ?? "Unknown"
            )
        }

        guard let existing = existingPreparedModelInfo(for: configuration) else {
            return nil
        }

        return LocalSTTPreparedModelInfo(
            storagePath: existing.storagePath,
            sourceDisplayName: existing.source.displayName
        )
    }

    func ensureServerReady(settingsStore: SettingsStore) async throws -> URL {
        let configuration = normalizedConfiguration(from: settingsStore)

        if await isHealthy(for: configuration) {
            return serverBaseURL
        }

        if preparedModelInfo(settingsStore: settingsStore) != nil {
            try await ensurePythonEnvironment()
            try await ensurePackages(for: configuration)
            try startServer(with: configuration)
            try await waitUntilHealthy(for: configuration)
            return serverBaseURL
        }

        guard configuration.autoSetup else {
            throw NSError(
                domain: "LocalSTTServiceManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Local STT model is not ready. Enable auto setup or prepare the model first."]
            )
        }

        try await prepareModel(settingsStore: settingsStore)
        try startServer(with: configuration)
        try await waitUntilHealthy(for: configuration)
        return serverBaseURL
    }

    private func normalizedConfiguration(from settingsStore: SettingsStore) -> LocalSTTConfiguration {
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        let identifier = configuration.modelIdentifier.isEmpty
            ? configuration.model.defaultModelIdentifier
            : configuration.modelIdentifier
        return LocalSTTConfiguration(
            model: configuration.model,
            modelIdentifier: identifier,
            downloadSource: configuration.downloadSource,
            autoSetup: configuration.autoSetup
        )
    }

    private func ensurePythonEnvironment() async throws {
        if FileManager.default.fileExists(atPath: pythonExecutableURL.path) {
            return
        }

        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        _ = try await commandRunner.run(
            executablePath: "/usr/bin/env",
            arguments: ["python3", "-m", "venv", pythonEnvironmentURL.path]
        )
        _ = try await commandRunner.run(
            executablePath: pythonExecutableURL.path,
            arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"]
        )
    }

    private func ensurePackages(for configuration: LocalSTTConfiguration) async throws {
        var requiredModules = ["fastapi", "uvicorn", "multipart", "huggingface_hub"]
        var packages = ["fastapi", "uvicorn", "python-multipart", "huggingface_hub"]

        switch configuration.model {
        case .whisperLocal:
            requiredModules.append(contentsOf: ["whisper", "torch", "imageio_ffmpeg"])
            packages.append(contentsOf: ["openai-whisper", "torch", "imageio-ffmpeg"])
        case .senseVoiceSmall:
            requiredModules.append(contentsOf: ["funasr", "modelscope", "torch", "torchaudio"])
            packages.append(contentsOf: ["funasr", "modelscope", "torch", "torchaudio"])
        case .qwen3ASR:
            requiredModules.append(contentsOf: ["qwen_asr", "modelscope", "torch"])
            packages.append(contentsOf: ["qwen-asr", "modelscope", "torch"])
        }

        let importCheck = requiredModules.map { "import \($0)" }.joined(separator: "; ")
        do {
            _ = try await commandRunner.run(
                executablePath: pythonExecutableURL.path,
                arguments: ["-c", importCheck]
            )
        } catch {
            _ = try await commandRunner.run(
                executablePath: pythonExecutableURL.path,
                arguments: ["-m", "pip", "install", "--upgrade"] + packages
            )
        }
    }

    private func startServer(with configuration: LocalSTTConfiguration) throws {
        stopServer()

        let process = Process()
        process.executableURL = pythonExecutableURL
        process.arguments = [try scriptURL().path, "serve"] + sharedArguments(for: configuration) + [
            "--host", serverHost,
            "--port", String(serverPort)
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] _ in
            self?.serverProcess = nil
            self?.runningConfiguration = nil
        }

        try process.run()
        serverProcess = process
        runningConfiguration = configuration
    }

    private func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        runningConfiguration = nil
    }

    private func waitUntilHealthy(for configuration: LocalSTTConfiguration) async throws {
        for _ in 0..<40 {
            if await isHealthy(for: configuration) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw NSError(
            domain: "LocalSTTServiceManager",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Local STT server failed to start in time."]
        )
    }

    private func isHealthy(for configuration: LocalSTTConfiguration) async -> Bool {
        guard runningConfiguration == configuration, serverProcess?.isRunning == true else {
            return false
        }

        var request = URLRequest(url: URL(string: "http://\(serverHost):\(serverPort)/health")!)
        request.timeoutInterval = 1.5

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ready = json["ready"] as? Bool
            else {
                return false
            }

            return ready
        } catch {
            return false
        }
    }

    private func runScript(arguments: [String]) async throws {
        _ = try await commandRunner.run(
            executablePath: pythonExecutableURL.path,
            arguments: [try scriptURL().path] + arguments
        )
    }

    private func prepareRuntime(configuration: LocalSTTConfiguration) async throws -> (path: String, source: String) {
        let result = try await commandRunner.run(
            executablePath: pythonExecutableURL.path,
            arguments: [try scriptURL().path, "prepare"] + sharedArguments(for: configuration)
        )

        guard
            let data = result.stdout.data(using: .utf8),
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (expectedStoragePath(for: configuration), "modelScope")
        }

        return (
            (payload["model_path"] as? String) ?? expectedStoragePath(for: configuration),
            (payload["source"] as? String) ?? "modelScope"
        )
    }

    private func sharedArguments(for configuration: LocalSTTConfiguration) -> [String] {
        [
            "--model", configuration.model.rawValue,
            "--model-id", configuration.modelIdentifier,
            "--source", "auto",
            "--cache-dir", modelsRootURL.path
        ]
    }

    private func expectedStoragePath(for configuration: LocalSTTConfiguration) -> String {
        switch configuration.model {
        case .whisperLocal:
            return modelsRootURL.appendingPathComponent("\(configuration.modelIdentifier).pt", isDirectory: false).path
        case .senseVoiceSmall, .qwen3ASR:
            return modelsRootURL.appendingPathComponent(configuration.modelIdentifier.replacingOccurrences(of: "/", with: "--"), isDirectory: true).path
        }
    }

    private func existingPreparedModelInfo(for configuration: LocalSTTConfiguration) -> (storagePath: String, source: ModelDownloadSource)? {
        let expectedPath = expectedStoragePath(for: configuration)
        guard modelExists(at: expectedPath, for: configuration.model) else {
            return nil
        }

        return (expectedPath, detectDownloadSource(forPath: expectedPath, model: configuration.model))
    }

    private func modelExists(at path: String, for model: LocalSTTModel) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }

        switch model {
        case .whisperLocal:
            return !isDirectory.boolValue
        case .senseVoiceSmall, .qwen3ASR:
            guard isDirectory.boolValue else {
                return false
            }

            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return !children.isEmpty
        }
    }

    private func detectDownloadSource(forPath path: String, model: LocalSTTModel) -> ModelDownloadSource {
        switch model {
        case .whisperLocal:
            return .huggingFace
        case .senseVoiceSmall, .qwen3ASR:
            let huggingFaceMarker = URL(fileURLWithPath: path)
                .appendingPathComponent(".cache/huggingface", isDirectory: true)
                .path
            return FileManager.default.fileExists(atPath: huggingFaceMarker) ? .huggingFace : .modelScope
        }
    }

    private func loadPreparedRecord(for configuration: LocalSTTConfiguration) -> LocalSTTPreparedRecord? {
        guard
            let data = try? Data(contentsOf: preparedManifestURL),
            let records = try? JSONDecoder().decode([LocalSTTPreparedRecord].self, from: data)
        else {
            return nil
        }

        return records.first {
            $0.model == configuration.model.rawValue && $0.modelIdentifier == configuration.modelIdentifier
        }
    }

    private func savePreparedRecord(_ record: LocalSTTPreparedRecord) throws {
        var records: [LocalSTTPreparedRecord] = []
        if
            let data = try? Data(contentsOf: preparedManifestURL),
            let decoded = try? JSONDecoder().decode([LocalSTTPreparedRecord].self, from: data)
        {
            records = decoded.filter { !($0.model == record.model && $0.modelIdentifier == record.modelIdentifier) }
        }

        records.append(record)
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: preparedManifestURL, options: .atomic)
    }

    private var preparedManifestURL: URL {
        runtimeRootURL.appendingPathComponent("prepared-local-stt-models.json")
    }

    private var runtimeRootURL: URL {
        appSupportRootURL.appendingPathComponent("Runtime", isDirectory: true)
    }

    private var modelsRootURL: URL {
        appSupportRootURL.appendingPathComponent("Models", isDirectory: true)
    }

    private var pythonEnvironmentURL: URL {
        runtimeRootURL.appendingPathComponent("stt-python", isDirectory: true)
    }

    private var pythonExecutableURL: URL {
        pythonEnvironmentURL.appendingPathComponent("bin/python")
    }

    private var appSupportRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newRootURL = base.appendingPathComponent("Typeflux/STT", isDirectory: true)
        let legacyRootURL = base.appendingPathComponent("VoiceInput/STT", isDirectory: true)
        if !FileManager.default.fileExists(atPath: newRootURL.path),
           FileManager.default.fileExists(atPath: legacyRootURL.path) {
            let parentURL = newRootURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: legacyRootURL, to: newRootURL)
        }
        return newRootURL
    }

    private func scriptURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "local_stt_server", withExtension: "py", subdirectory: "Resources/Python") ??
            Bundle.module.url(forResource: "local_stt_server", withExtension: "py")
        else {
            throw LocalSTTServiceManagerError.missingServerScript
        }
        return url
    }
}
