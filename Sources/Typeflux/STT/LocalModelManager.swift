import Foundation

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

private struct LocalModelPreparedRecord: Codable {
    let model: String
    let modelIdentifier: String
    let storagePath: String
    let source: String
    let preparedAt: Date
}

struct LocalSTTConfiguration: Equatable {
    let model: LocalSTTModel
    let modelIdentifier: String
    let downloadSource: ModelDownloadSource
    let autoSetup: Bool

    init(settingsStore: SettingsStore) {
        let identifier = settingsStore.localSTTModelIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = settingsStore.localSTTModel
        self.modelIdentifier = identifier.isEmpty ? settingsStore.localSTTModel.defaultModelIdentifier : identifier
        self.downloadSource = settingsStore.localSTTDownloadSource
        self.autoSetup = settingsStore.localSTTAutoSetup
    }
}

final class LocalModelManager {
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let _modelsRootURL: URL
    private let _legacyRuntimeURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        self._modelsRootURL = base.appendingPathComponent("Typeflux/LocalModels", isDirectory: true)
        self._legacyRuntimeURL = base.appendingPathComponent("Typeflux/STT/Runtime", isDirectory: true)
    }

    var modelsRootPath: String {
        modelsRootURL.path
    }

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil
    ) async throws {
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        let downloadBasePath = storagePath(for: configuration)
        var storagePath = downloadBasePath

        onUpdate?(LocalSTTPreparationUpdate(
            message: "Cleaning legacy Python runtime...",
            progress: 0.05,
            storagePath: storagePath,
            source: nil
        ))
        try? cleanupLegacyPythonRuntime()

        try fileManager.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
        let resourceURL = resourceDirectoryURL(for: configuration.model)
        try fileManager.createDirectory(at: resourceURL, withIntermediateDirectories: true)

        switch configuration.model {
        case .whisperLocal:
            storagePath = try await prepareWhisperKit(
                configuration: configuration,
                downloadBasePath: downloadBasePath,
                onUpdate: onUpdate
            )
        case .senseVoiceSmall, .qwen3ASR:
            // Native runtime not yet available; record as prepared so the UI
            // can show the "not yet available" error rather than looping on auto-setup.
            onUpdate?(LocalSTTPreparationUpdate(
                message: "Preparing native local speech runtime...",
                progress: 0.9,
                storagePath: storagePath,
                source: configuration.downloadSource.displayName
            ))
        }

        // Create the storagePath directory so preparedModelInfo's fileExists check passes.
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: storagePath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let record = LocalModelPreparedRecord(
            model: configuration.model.rawValue,
            modelIdentifier: configuration.modelIdentifier,
            storagePath: storagePath,
            source: configuration.downloadSource.rawValue,
            preparedAt: Date()
        )
        try savePreparedRecord(record, for: configuration.model)

        onUpdate?(LocalSTTPreparationUpdate(
            message: "\(configuration.model.displayName) is ready in the native runtime.",
            progress: 1,
            storagePath: storagePath,
            source: configuration.downloadSource.displayName
        ))
    }

    private func prepareWhisperKit(
        configuration: LocalSTTConfiguration,
        downloadBasePath: String,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws -> String {
        let identifier = configuration.modelIdentifier
        let modelName = identifier.hasPrefix("whisperkit-")
            ? String(identifier.dropFirst("whisperkit-".count))
            : identifier

        onUpdate?(LocalSTTPreparationUpdate(
            message: "Downloading WhisperKit model \(modelName)…",
            progress: 0.2,
            storagePath: downloadBasePath,
            source: configuration.downloadSource.displayName
        ))

        let transcriber = WhisperKitTranscriber(
            modelName: modelName,
            downloadBase: URL(fileURLWithPath: downloadBasePath, isDirectory: true)
        )
        try await transcriber.prepare { progress, message in
            let mapped = 0.2 + progress * 0.75
            onUpdate?(LocalSTTPreparationUpdate(
                message: message,
                progress: mapped,
                storagePath: transcriber.resolvedModelFolderPath ?? downloadBasePath,
                source: configuration.downloadSource.displayName
            ))
        }

        guard
            let resolvedPath = transcriber.resolvedModelFolderPath,
            isUsableWhisperKitModelFolder(resolvedPath)
        else {
            throw NSError(
                domain: "LocalModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "WhisperKit model download finished, but no usable CoreML model files were found."]
            )
        }

        return resolvedPath
    }

    func preparedModelInfo(settingsStore: SettingsStore) -> LocalSTTPreparedModelInfo? {
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        guard
            let record = loadPreparedRecord(for: configuration.model),
            record.modelIdentifier == configuration.modelIdentifier,
            record.source == configuration.downloadSource.rawValue,
            isPreparedStoragePathValid(record.storagePath, for: configuration.model)
        else {
            return nil
        }

        return LocalSTTPreparedModelInfo(
            storagePath: record.storagePath,
            sourceDisplayName: ModelDownloadSource(rawValue: record.source)?.displayName ?? configuration.downloadSource.displayName
        )
    }

    func isModelDownloaded(_ model: LocalSTTModel) -> Bool {
        guard let record = loadPreparedRecord(for: model) else {
            return false
        }
        return isPreparedStoragePathValid(record.storagePath, for: model)
    }

    func deleteModelFiles(_ model: LocalSTTModel) throws {
        let resourceURL = resourceDirectoryURL(for: model)
        if fileManager.fileExists(atPath: resourceURL.path) {
            try fileManager.removeItem(at: resourceURL)
        }

        let recordURL = preparedRecordURL(for: model)
        if fileManager.fileExists(atPath: recordURL.path) {
            try fileManager.removeItem(at: recordURL)
        }
    }

    func storagePath(for configuration: LocalSTTConfiguration) -> String {
        resourceDirectoryURL(for: configuration.model)
            .appendingPathComponent(configuration.modelIdentifier.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .path
    }

    private var modelsRootURL: URL { _modelsRootURL }

    private var legacyRuntimeURL: URL { _legacyRuntimeURL }

    private func resourceDirectoryURL(for model: LocalSTTModel) -> URL {
        modelsRootURL.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    private func preparedRecordURL(for model: LocalSTTModel) -> URL {
        resourceDirectoryURL(for: model).appendingPathComponent("prepared.json", isDirectory: false)
    }

    private func savePreparedRecord(_ record: LocalModelPreparedRecord, for model: LocalSTTModel) throws {
        let recordURL = preparedRecordURL(for: model)
        let data = try encoder.encode(record)
        try data.write(to: recordURL, options: .atomic)
    }

    private func loadPreparedRecord(for model: LocalSTTModel) -> LocalModelPreparedRecord? {
        let url = preparedRecordURL(for: model)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(LocalModelPreparedRecord.self, from: data)
    }

    private func cleanupLegacyPythonRuntime() throws {
        guard fileManager.fileExists(atPath: legacyRuntimeURL.path) else {
            return
        }
        try fileManager.removeItem(at: legacyRuntimeURL)
    }

    private func isPreparedStoragePathValid(_ storagePath: String, for model: LocalSTTModel) -> Bool {
        guard fileManager.fileExists(atPath: storagePath) else {
            return false
        }

        switch model {
        case .whisperLocal:
            return isUsableWhisperKitModelFolder(storagePath)
        case .senseVoiceSmall, .qwen3ASR:
            return true
        }
    }

    private func isUsableWhisperKitModelFolder(_ storagePath: String) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { modelName in
            ["mlmodelc", "mlpackage"].contains { ext in
                fileManager.fileExists(
                    atPath: URL(fileURLWithPath: storagePath, isDirectory: true)
                        .appendingPathComponent("\(modelName).\(ext)")
                        .path
                )
            }
        }
    }
}
