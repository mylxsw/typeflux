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
        model = settingsStore.localSTTModel
        modelIdentifier = identifier.isEmpty ? settingsStore.localSTTModel.defaultModelIdentifier : identifier
        downloadSource = settingsStore.localSTTDownloadSource
        autoSetup = settingsStore.localSTTAutoSetup
    }

    init(model: LocalSTTModel, modelIdentifier: String, downloadSource: ModelDownloadSource, autoSetup: Bool) {
        self.model = model
        self.modelIdentifier = modelIdentifier
        self.downloadSource = downloadSource
        self.autoSetup = autoSetup
    }
}

protocol LocalSTTModelManaging {
    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?,
    ) async throws

    func preparedModelInfo(settingsStore: SettingsStore) -> LocalSTTPreparedModelInfo?
    func isModelDownloaded(_ model: LocalSTTModel) -> Bool
    func deleteModelFiles(_ model: LocalSTTModel) throws
    func storagePath(for configuration: LocalSTTConfiguration) -> String
}

final class LocalModelManager: LocalSTTModelManaging {
    private let fileManager: FileManager
    private let sherpaOnnxInstaller: SherpaOnnxModelInstalling
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let _modelsRootURL: URL
    private let _legacyRuntimeURL: URL

    init(
        fileManager: FileManager = .default,
        sherpaOnnxInstaller: SherpaOnnxModelInstalling? = nil,
        applicationSupportURL: URL? = nil,
    ) {
        self.fileManager = fileManager
        self.sherpaOnnxInstaller = sherpaOnnxInstaller ?? SherpaOnnxModelInstaller(
            fileManager: fileManager,
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let base = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        _modelsRootURL = base.appendingPathComponent("Typeflux/LocalModels", isDirectory: true)
        _legacyRuntimeURL = base.appendingPathComponent("Typeflux/STT/Runtime", isDirectory: true)
    }

    var modelsRootPath: String {
        modelsRootURL.path
    }

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil,
    ) async throws {
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        let resultPath = try await downloadModelFilesOnly(configuration: configuration, onUpdate: onUpdate)
        let record = LocalModelPreparedRecord(
            model: configuration.model.rawValue,
            modelIdentifier: configuration.modelIdentifier,
            storagePath: resultPath,
            source: configuration.downloadSource.rawValue,
            preparedAt: Date(),
        )
        try savePreparedRecord(record, for: configuration.model)
    }

    /// Downloads model files for the given configuration without updating prepared.json.
    /// Returns the resolved storage path on success.
    @discardableResult
    func downloadModelFilesOnly(
        configuration: LocalSTTConfiguration,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil,
    ) async throws -> String {
        let downloadBasePath = storagePath(for: configuration)
        var resultPath = downloadBasePath

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.cleaningLegacyRuntime"),
            progress: 0.05,
            storagePath: resultPath,
            source: nil,
        ))
        try? cleanupLegacyPythonRuntime()

        try fileManager.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
        let resourceURL = resourceDirectoryURL(for: configuration.model)
        try fileManager.createDirectory(at: resourceURL, withIntermediateDirectories: true)

        switch configuration.model {
        case .whisperLocal, .whisperLocalLarge:
            resultPath = try await prepareWhisperKit(
                configuration: configuration,
                downloadBasePath: downloadBasePath,
                onUpdate: onUpdate,
            )
        case .senseVoiceSmall, .qwen3ASR:
            resultPath = try await sherpaOnnxInstaller.prepareModel(
                configuration.model,
                at: URL(fileURLWithPath: downloadBasePath, isDirectory: true),
                downloadSource: configuration.downloadSource,
            ) { update in
                onUpdate?(LocalSTTPreparationUpdate(
                    message: update.message,
                    progress: update.progress,
                    storagePath: update.storagePath,
                    source: configuration.downloadSource.displayName,
                ))
            }
        }

        // Create the storagePath directory so file-existence checks pass.
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: resultPath, isDirectory: true),
            withIntermediateDirectories: true,
        )

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.runtimeReady", configuration.model.displayName),
            progress: 1,
            storagePath: resultPath,
            source: configuration.downloadSource.displayName,
        ))

        return resultPath
    }

    /// Returns true when the model files at storagePath are complete and usable.
    func isStoragePathReady(_ storagePath: String, for model: LocalSTTModel) -> Bool {
        isPreparedStoragePathValid(storagePath, for: model)
    }

    private func prepareWhisperKit(
        configuration: LocalSTTConfiguration,
        downloadBasePath: String,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?,
    ) async throws -> String {
        let identifier = configuration.modelIdentifier
        let modelName = identifier.hasPrefix("whisperkit-")
            ? String(identifier.dropFirst("whisperkit-".count))
            : identifier

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.whisperDownloading", modelName),
            progress: 0.2,
            storagePath: downloadBasePath,
            source: configuration.downloadSource.displayName,
        ))

        let transcriber = WhisperKitTranscriber(
            modelName: modelName,
            downloadBase: URL(fileURLWithPath: downloadBasePath, isDirectory: true),
            modelRepo: LocalModelDownloadCatalog.whisperKitModelRepository(source: configuration.downloadSource),
            modelEndpoint: LocalModelDownloadCatalog.whisperKitModelEndpoint(source: configuration.downloadSource),
        )
        try await transcriber.prepare { progress, message in
            let mapped = 0.2 + progress * 0.75
            onUpdate?(LocalSTTPreparationUpdate(
                message: message,
                progress: mapped,
                storagePath: transcriber.resolvedModelFolderPath ?? downloadBasePath,
                source: configuration.downloadSource.displayName,
            ))
        }

        guard
            let resolvedPath = transcriber.resolvedModelFolderPath,
            isUsableWhisperKitModelFolder(resolvedPath)
        else {
            throw NSError(
                domain: "LocalModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.whisperModelMissing")],
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
            sourceDisplayName: ModelDownloadSource(rawValue: record.source)?.displayName ?? configuration.downloadSource.displayName,
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

    private var modelsRootURL: URL {
        _modelsRootURL
    }

    private var legacyRuntimeURL: URL {
        _legacyRuntimeURL
    }

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
        case .whisperLocal, .whisperLocalLarge:
            return isUsableWhisperKitModelFolder(storagePath)
        case .senseVoiceSmall, .qwen3ASR:
            guard let layout = SherpaOnnxModelLayout.layout(for: model) else {
                return false
            }
            return layout.isInstalled(
                storageURL: URL(fileURLWithPath: storagePath, isDirectory: true),
                fileManager: fileManager,
            )
        }
    }

    private func isUsableWhisperKitModelFolder(_ storagePath: String) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { modelName in
            ["mlmodelc", "mlpackage"].contains { ext in
                fileManager.fileExists(
                    atPath: URL(fileURLWithPath: storagePath, isDirectory: true)
                        .appendingPathComponent("\(modelName).\(ext)")
                        .path,
                )
            }
        }
    }
}
