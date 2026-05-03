import Foundation

protocol WhisperKitPreparing {
    var resolvedModelFolderPath: String? { get }
    func prepare(onProgress: ((Double, String) -> Void)?) async throws
}

private struct HubRepositorySiblingsResponse: Decodable {
    struct Sibling: Decodable {
        let rfilename: String
    }

    let siblings: [Sibling]
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

private struct LocalModelDownloadResult {
    let storagePath: String
    let source: ModelDownloadSource
}

private struct LocalModelPreparedRecord: Codable {
    let model: String
    let modelIdentifier: String
    let storagePath: String
    let runtimePath: String?
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
    func isModelAvailable(_ model: LocalSTTModel) -> Bool
    func deleteModelFiles(_ model: LocalSTTModel) throws
    func storagePath(for configuration: LocalSTTConfiguration) -> String
}

final class LocalModelManager: LocalSTTModelManaging {
    /// Raw value stored in `prepared.json` when the active model was installed from the
    /// bundled copy shipped inside the .app bundle.
    static let bundledPreparedSource = "bundled"

    typealias WhisperKitPreparerFactory = @Sendable (String, URL, String, String) -> any WhisperKitPreparing
    typealias LocalWhisperKitPreparerFactory = @Sendable (String, String, URL?) -> any WhisperKitPreparing
    typealias RemoteFileLoader = @Sendable (URL) async throws -> Data
    typealias RemoteRepositoryFileListLoader = @Sendable (URL) async throws -> [String]
    typealias RemoteFileDownloader = @Sendable (URL, URL) async throws -> Void

    private let fileManager: FileManager
    private let sherpaOnnxInstaller: SherpaOnnxModelInstalling
    private let whisperKitPreparerFactory: WhisperKitPreparerFactory
    private let localWhisperKitPreparerFactory: LocalWhisperKitPreparerFactory
    private let remoteFileLoader: RemoteFileLoader
    private let remoteRepositoryFileListLoader: RemoteRepositoryFileListLoader
    private let remoteFileDownloader: RemoteFileDownloader
    private let downloadSourceResolver: LocalModelDownloadSourceResolving
    private let bundledModelLocator: BundledLocalModelLocator
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let _modelsRootURL: URL
    private let _runtimesRootURL: URL
    private let _legacyRuntimeURL: URL

    init(
        fileManager: FileManager = .default,
        sherpaOnnxInstaller: SherpaOnnxModelInstalling? = nil,
        applicationSupportURL: URL? = nil,
        whisperKitPreparerFactory: @escaping WhisperKitPreparerFactory = { modelName, downloadBase, modelRepo, modelEndpoint in
            WhisperKitTranscriber(
                modelName: modelName,
                downloadBase: downloadBase,
                modelRepo: modelRepo,
                modelEndpoint: modelEndpoint,
            )
        },
        localWhisperKitPreparerFactory: @escaping LocalWhisperKitPreparerFactory = { modelName, modelFolder, tokenizerFolder in
            WhisperKitTranscriber(
                modelName: modelName,
                modelFolder: modelFolder,
                tokenizerFolder: tokenizerFolder,
            )
        },
        remoteFileLoader: @escaping RemoteFileLoader = { url in
            try await LocalModelManager.defaultRemoteFileLoader(from: url)
        },
        remoteRepositoryFileListLoader: @escaping RemoteRepositoryFileListLoader = { url in
            try await LocalModelManager.defaultRemoteRepositoryFileListLoader(from: url)
        },
        remoteFileDownloader: @escaping RemoteFileDownloader = { sourceURL, destinationURL in
            try await LocalModelManager.defaultRemoteFileDownloader(from: sourceURL, to: destinationURL)
        },
        downloadSourceResolver: LocalModelDownloadSourceResolving = NetworkLocalModelDownloadSourceResolver(),
        bundledModelsRootURL: URL? = nil,
    ) {
        self.fileManager = fileManager
        self.whisperKitPreparerFactory = whisperKitPreparerFactory
        self.localWhisperKitPreparerFactory = localWhisperKitPreparerFactory
        self.remoteFileLoader = remoteFileLoader
        self.remoteRepositoryFileListLoader = remoteRepositoryFileListLoader
        self.remoteFileDownloader = remoteFileDownloader
        self.downloadSourceResolver = downloadSourceResolver
        bundledModelLocator = BundledLocalModelLocator(bundledModelsRootURL: bundledModelsRootURL)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let base = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        _modelsRootURL = base.appendingPathComponent("Typeflux/LocalModels", isDirectory: true)
        _runtimesRootURL = base.appendingPathComponent("Typeflux/LocalRuntimes", isDirectory: true)
        _legacyRuntimeURL = base.appendingPathComponent("Typeflux/STT/Runtime", isDirectory: true)
        self.sherpaOnnxInstaller = sherpaOnnxInstaller ?? SherpaOnnxModelInstaller(
            fileManager: fileManager,
            sharedRuntimeStorageURL: _runtimesRootURL,
        )
    }

    var modelsRootPath: String {
        modelsRootURL.path
    }

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil,
    ) async throws {
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)

        if let bundled = bundledModelInfo(for: configuration) {
            let installedPath = try installBundledModelIntoAppSupport(
                configuration: configuration,
                bundledPath: bundled.storagePath,
            )
            let record = LocalModelPreparedRecord(
                model: configuration.model.rawValue,
                modelIdentifier: configuration.modelIdentifier,
                storagePath: installedPath,
                runtimePath: runtimePath(for: configuration.model),
                source: Self.bundledPreparedSource,
                preparedAt: Date(),
            )
            try savePreparedRecord(record, for: configuration.model)
            onUpdate?(LocalSTTPreparationUpdate(
                message: L("localSTT.prepare.runtimeReady", configuration.model.displayName),
                progress: 1,
                storagePath: installedPath,
                source: L("common.bundled"),
            ))
            return
        }

        let result = try await downloadModelFiles(configuration: configuration, onUpdate: onUpdate)
        let record = LocalModelPreparedRecord(
            model: configuration.model.rawValue,
            modelIdentifier: configuration.modelIdentifier,
            storagePath: result.storagePath,
            runtimePath: runtimePath(for: configuration.model),
            source: result.source.rawValue,
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
        try await downloadModelFiles(configuration: configuration, onUpdate: onUpdate).storagePath
    }

    private func downloadModelFiles(
        configuration: LocalSTTConfiguration,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil,
    ) async throws -> LocalModelDownloadResult {
        let sources = await downloadSourceResolver.rankedSources(for: configuration)
        var lastError: Error?

        for source in sources {
            do {
                let sourceConfiguration = LocalSTTConfiguration(
                    model: configuration.model,
                    modelIdentifier: configuration.modelIdentifier,
                    downloadSource: source,
                    autoSetup: configuration.autoSetup,
                )
                let storagePath = try await downloadModelFilesOnly(
                    configuration: sourceConfiguration,
                    selectedSource: source,
                    onUpdate: onUpdate,
                )
                return LocalModelDownloadResult(storagePath: storagePath, source: source)
            } catch {
                lastError = error
                NetworkDebugLogger.logError(
                    context: "[Local Model Download] source failed: \(source.displayName)",
                    error: error,
                )
                let attemptedPath = storagePath(for: LocalSTTConfiguration(
                    model: configuration.model,
                    modelIdentifier: configuration.modelIdentifier,
                    downloadSource: source,
                    autoSetup: configuration.autoSetup,
                ))
                if !isPreparedStoragePathValid(attemptedPath, for: configuration.model) {
                    try? fileManager.removeItem(at: URL(fileURLWithPath: attemptedPath, isDirectory: true))
                }
            }
        }

        throw lastError ?? NSError(
            domain: "LocalModelManager",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "All local model download sources failed."],
        )
    }

    private func downloadModelFilesOnly(
        configuration: LocalSTTConfiguration,
        selectedSource: ModelDownloadSource,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?,
    ) async throws -> String {
        let downloadBasePath = storagePath(for: configuration)
        var resultPath = downloadBasePath

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.cleaningLegacyRuntime"),
            progress: 0.05,
            storagePath: resultPath,
            source: selectedSource.displayName,
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
        case .senseVoiceSmall, .qwen3ASR, .funASR:
            resultPath = try await sherpaOnnxInstaller.prepareModel(
                configuration.model,
                at: URL(fileURLWithPath: downloadBasePath, isDirectory: true),
                downloadSource: configuration.downloadSource,
            ) { update in
                onUpdate?(LocalSTTPreparationUpdate(
                    message: update.message,
                    progress: update.progress,
                    storagePath: update.storagePath,
                    source: selectedSource.displayName,
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
            source: selectedSource.displayName,
        ))

        return resultPath
    }

    /// Returns true when the model files at storagePath are complete and usable.
    func isStoragePathReady(_ storagePath: String, for model: LocalSTTModel) -> Bool {
        isPreparedStoragePathValid(storagePath, for: model)
    }

    /// Ensures the bundled SenseVoice copy shipped inside the .app bundle (if present)
    /// is copied into Application Support and recorded in prepared.json.
    ///
    /// This is intended to be called once at app start for the full installer variant
    /// so that the first hotkey press doesn't have to wait for a lazy prepare on the
    /// transcription hot path. No-op on the minimal variant (no bundle present).
    ///
    /// Uses a fixed SenseVoice configuration rather than reading from SettingsStore,
    /// so it works correctly even before onboarding runs and is not affected by any
    /// model the user may have manually picked afterwards.
    ///
    /// - Returns: `true` if a bundled model was found (and is now copied/recorded),
    ///            `false` if no bundled model ships with this build.
    @discardableResult
    func ensureBundledSenseVoiceLinked() throws -> Bool {
        let configuration = LocalSTTConfiguration(
            model: .senseVoiceSmall,
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            downloadSource: .huggingFace,
            autoSetup: true,
        )

        guard let bundled = bundledModelInfo(for: configuration) else {
            return false
        }

        let installedPath = try installBundledModelIntoAppSupport(
            configuration: configuration,
            bundledPath: bundled.storagePath,
        )
        let record = LocalModelPreparedRecord(
            model: configuration.model.rawValue,
            modelIdentifier: configuration.modelIdentifier,
            storagePath: installedPath,
            runtimePath: runtimePath(for: configuration.model),
            source: Self.bundledPreparedSource,
            preparedAt: Date(),
        )
        try savePreparedRecord(record, for: configuration.model)
        return true
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

        try await prepareWhisperTokenizerIfNeeded(
            modelName: modelName,
            downloadSource: configuration.downloadSource,
            downloadBasePath: downloadBasePath,
        )

        if let localModelFolderPath = try await prepareWhisperModelFilesIfNeeded(
            modelName: modelName,
            downloadSource: configuration.downloadSource,
            downloadBasePath: downloadBasePath,
            onUpdate: onUpdate,
        ) {
            let transcriber = localWhisperKitPreparerFactory(
                modelName,
                localModelFolderPath,
                URL(fileURLWithPath: downloadBasePath, isDirectory: true),
            )
            NetworkDebugLogger.logMessage(
                "[Local Model Download] model=\(configuration.model.displayName) source=\(configuration.downloadSource.displayName) kind=whisperkit-local modelFolder=\(localModelFolderPath)"
            )
            try await transcriber.prepare { progress, message in
                let mapped = 0.2 + progress * 0.75
                onUpdate?(LocalSTTPreparationUpdate(
                    message: message,
                    progress: mapped,
                    storagePath: transcriber.resolvedModelFolderPath ?? localModelFolderPath,
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

        let downloadBaseURL = URL(fileURLWithPath: downloadBasePath, isDirectory: true)
        let modelRepo = LocalModelDownloadCatalog.whisperKitModelRepository(source: configuration.downloadSource)
        let modelEndpoint = LocalModelDownloadCatalog.whisperKitModelEndpoint(source: configuration.downloadSource)
        let transcriber = whisperKitPreparerFactory(
            modelName,
            downloadBaseURL,
            modelRepo,
            modelEndpoint,
        )
        NetworkDebugLogger.logMessage(
            "[Local Model Download] model=\(configuration.model.displayName) source=\(configuration.downloadSource.displayName) kind=whisperkit endpoint=\(modelEndpoint) repository=\(LocalModelDownloadCatalog.whisperKitModelRepositoryURL(source: configuration.downloadSource).absoluteString)"
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
        preparedModelInfo(for: LocalSTTConfiguration(settingsStore: settingsStore))
    }

    func isModelAvailable(_ model: LocalSTTModel) -> Bool {
        let defaultConfiguration = LocalSTTConfiguration(
            model: model,
            modelIdentifier: model.defaultModelIdentifier,
            downloadSource: model.recommendedDownloadSource,
            autoSetup: true,
        )
        if bundledModelInfo(for: defaultConfiguration) != nil {
            return true
        }

        guard let record = loadPreparedRecord(for: model) else {
            return false
        }
        return isPreparedStoragePathValid(record.storagePath, for: model)
    }

    func preparedModelInfo(for configuration: LocalSTTConfiguration) -> LocalSTTPreparedModelInfo? {
        guard
            let record = loadPreparedRecord(for: configuration.model),
            record.modelIdentifier == configuration.modelIdentifier,
            isPreparedStoragePathValid(record.storagePath, for: configuration.model)
        else {
            return nil
        }

        return LocalSTTPreparedModelInfo(
            storagePath: record.storagePath,
            sourceDisplayName: preparedSourceDisplayName(
                rawValue: record.source,
                configuration: configuration,
            ),
        )
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

    private var runtimesRootURL: URL {
        _runtimesRootURL
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

    private func bundledModelInfo(for configuration: LocalSTTConfiguration) -> LocalSTTPreparedModelInfo? {
        for candidateURL in bundledModelLocator.storageURLs(for: configuration)
        where isPreparedStoragePathValid(candidateURL.path, for: configuration.model) {
            return LocalSTTPreparedModelInfo(
                storagePath: candidateURL.path,
                sourceDisplayName: L("common.bundled"),
            )
        }

        return nil
    }

    private func runtimePath(for model: LocalSTTModel) -> String? {
        guard let layout = SherpaOnnxModelLayout.layout(for: model) else {
            return nil
        }
        return runtimesRootURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true).path
    }

    /// Copies bundled Sherpa model assets into the per-user Application Support tree and
    /// links the shared runtime from `LocalRuntimes/` into the model folder. The app bundle
    /// is replaced during auto-update, so durable state must not point back into the bundle.
    private func installBundledModelIntoAppSupport(
        configuration: LocalSTTConfiguration,
        bundledPath: String,
    ) throws -> String {
        guard let layout = SherpaOnnxModelLayout.layout(for: configuration.model) else {
            throw NSError(
                domain: "LocalModelManager",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Bundled local model copy is only supported for Sherpa-ONNX models."],
            )
        }

        let targetURL = URL(fileURLWithPath: storagePath(for: configuration), isDirectory: true)
        let bundledURL = URL(fileURLWithPath: bundledPath, isDirectory: true)

        // Defense in depth: every removeItem/copy below must land strictly
        // inside modelsRootURL. storagePath() derives from modelsRootURL + sanitized
        // identifier today, but this guard makes the invariant explicit so future changes
        // to identifier handling cannot silently let us touch arbitrary filesystem paths.
        try ensurePath(targetURL, isInside: modelsRootURL)

        let runtimeRootURL = try installBundledRuntimeIntoAppSupport(layout: layout, bundledStorageURL: bundledURL)
        if bundledModelMatchesInstalledCopy(layout: layout, bundledStorageURL: bundledURL, targetURL: targetURL, runtimeRootURL: runtimeRootURL) {
            return targetURL.path
        }

        if fileManager.fileExists(atPath: targetURL.path) || (try? fileManager.destinationOfSymbolicLink(atPath: targetURL.path)) != nil {
            try fileManager.removeItem(at: targetURL)
        }

        let bundledModelRootURL = bundledURL.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)
        let targetModelRootURL = targetURL.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundledModelRootURL, to: targetModelRootURL)
        try linkRuntime(layout: layout, modelStorageURL: targetURL, runtimeRootURL: runtimeRootURL)

        guard layout.isInstalled(storageURL: targetURL, fileManager: fileManager) else {
            throw NSError(
                domain: "LocalModelManager",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Bundled local model copy failed validation at \(targetURL.path)"],
            )
        }
        return targetURL.path
    }

    private func installBundledRuntimeIntoAppSupport(
        layout: SherpaOnnxModelLayout,
        bundledStorageURL: URL,
    ) throws -> URL {
        let bundledRuntimeURL = try resolvedURLFollowingSymlink(
            bundledStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        )
        let targetRuntimeURL = runtimesRootURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        try ensurePath(targetRuntimeURL, isInside: runtimesRootURL)

        if layout.isRuntimeInstalled(storageURL: runtimesRootURL, fileManager: fileManager),
           directoryContentsMatch(sourceURL: bundledRuntimeURL, targetURL: targetRuntimeURL)
        {
            return targetRuntimeURL
        }

        if fileManager.fileExists(atPath: targetRuntimeURL.path) || (try? fileManager.destinationOfSymbolicLink(atPath: targetRuntimeURL.path)) != nil {
            try fileManager.removeItem(at: targetRuntimeURL)
        }
        try fileManager.createDirectory(at: targetRuntimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundledRuntimeURL, to: targetRuntimeURL)
        return targetRuntimeURL
    }

    private func bundledModelMatchesInstalledCopy(
        layout: SherpaOnnxModelLayout,
        bundledStorageURL: URL,
        targetURL: URL,
        runtimeRootURL: URL,
    ) -> Bool {
        let bundledModelRootURL = bundledStorageURL.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)
        let targetModelRootURL = targetURL.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)
        guard directoryContentsMatch(sourceURL: bundledModelRootURL, targetURL: targetModelRootURL),
              layout.isInstalled(storageURL: targetURL, fileManager: fileManager)
        else {
            return false
        }
        return (try? fileManager.destinationOfSymbolicLink(
            atPath: targetURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true).path
        )) == runtimeRootURL.path
    }

    private func linkRuntime(
        layout: SherpaOnnxModelLayout,
        modelStorageURL: URL,
        runtimeRootURL: URL,
    ) throws {
        let linkURL = modelStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        if let existingDestination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) {
            if existingDestination == runtimeRootURL.path {
                return
            }
            try fileManager.removeItem(at: linkURL)
        } else if fileManager.fileExists(atPath: linkURL.path) {
            try fileManager.removeItem(at: linkURL)
        }
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: runtimeRootURL)
    }

    private func resolvedURLFollowingSymlink(_ url: URL) throws -> URL {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination, isDirectory: true)
        }
        return url.deletingLastPathComponent().appendingPathComponent(destination, isDirectory: true)
    }

    private func ensurePath(_ url: URL, isInside rootURL: URL) throws {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw NSError(
                domain: "LocalModelManager",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Resolved local model asset path escapes storage root: \(path)"],
            )
        }
    }

    private func directoryContentsMatch(sourceURL: URL, targetURL: URL) -> Bool {
        DirectoryContentMatcher.contentsMatch(
            sourceURL: sourceURL,
            targetURL: targetURL,
            fileManager: fileManager,
        )
    }

    private func preparedSourceDisplayName(
        rawValue: String,
        configuration: LocalSTTConfiguration,
    ) -> String {
        if rawValue == Self.bundledPreparedSource {
            return L("common.bundled")
        }
        return ModelDownloadSource(rawValue: rawValue)?.displayName
            ?? configuration.downloadSource.displayName
    }

    private func prepareWhisperTokenizerIfNeeded(
        modelName: String,
        downloadSource: ModelDownloadSource,
        downloadBasePath: String,
    ) async throws {
        guard downloadSource != .huggingFace else {
            return
        }

        guard LocalModelDownloadCatalog.whisperTokenizerRepositoryID(for: modelName) != nil else {
            return
        }

        let tokenizerFolderURL = whisperTokenizerFolderURL(for: modelName, downloadBasePath: downloadBasePath)
        if isUsableWhisperTokenizerFolder(tokenizerFolderURL.path) {
            return
        }

        try fileManager.createDirectory(at: tokenizerFolderURL, withIntermediateDirectories: true)
        for fileName in ["tokenizer.json", "tokenizer_config.json"] {
            guard let sourceURL = LocalModelDownloadCatalog.whisperTokenizerFileURL(
                for: modelName,
                fileName: fileName,
                source: downloadSource,
            ) else {
                continue
            }

            NetworkDebugLogger.logMessage(
                "[Local Model Download] kind=whisper-tokenizer source=\(downloadSource.displayName) model=\(modelName) url=\(sourceURL.absoluteString)"
            )
            let data = try await loadRemoteFileWithRetry(sourceURL, operationName: "WhisperKit tokenizer file download")
            try data.write(
                to: tokenizerFolderURL.appendingPathComponent(fileName, isDirectory: false),
                options: .atomic,
            )
        }
    }

    private func prepareWhisperModelFilesIfNeeded(
        modelName: String,
        downloadSource: ModelDownloadSource,
        downloadBasePath: String,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?,
    ) async throws -> String? {
        guard downloadSource != .huggingFace else {
            return nil
        }

        let modelFolderURL = whisperModelFolderURL(for: modelName, downloadBasePath: downloadBasePath)
        if isUsableWhisperKitModelFolder(modelFolderURL.path) {
            return modelFolderURL.path
        }

        let repositoryFilesURL = whisperModelRepositoryFilesURL(source: downloadSource)
        let expectedPrefix = whisperModelDirectoryName(for: modelName) + "/"
        let remoteFiles = try await loadRemoteRepositoryFileListWithRetry(
            repositoryFilesURL,
            operationName: "WhisperKit repository file list download",
        )
            .filter { $0.hasPrefix(expectedPrefix) }
            .sorted()

        guard !remoteFiles.isEmpty else {
            throw NSError(
                domain: "LocalModelManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.whisperModelMissing")],
            )
        }

        try fileManager.createDirectory(at: modelFolderURL, withIntermediateDirectories: true)
        let resolveBaseURL = LocalModelDownloadCatalog.whisperKitModelRepositoryURL(source: downloadSource)
            .appendingPathComponent("resolve", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
        let localRepositoryRootURL = whisperModelRepositoryRootURL(downloadBasePath: downloadBasePath)

        for (index, relativePath) in remoteFiles.enumerated() {
            let sourceURL = relativePath
                .split(separator: "/")
                .reduce(resolveBaseURL) { partialURL, component in
                    partialURL.appendingPathComponent(String(component), isDirectory: false)
                }
            let destinationFileURL = relativePath
                .split(separator: "/")
                .reduce(localRepositoryRootURL) { partialURL, component in
                    partialURL.appendingPathComponent(String(component), isDirectory: false)
                }

            if isUsableDownloadedWhisperFile(at: destinationFileURL) {
                continue
            }

            try fileManager.createDirectory(
                at: destinationFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )

            let progressBase = Double(index) / Double(max(remoteFiles.count, 1))
            onUpdate?(LocalSTTPreparationUpdate(
                message: L("localSTT.prepare.whisperDownloading", modelName),
                progress: 0.2 + progressBase * 0.6,
                storagePath: modelFolderURL.path,
                source: downloadSource.displayName,
            ))
            NetworkDebugLogger.logMessage(
                "[Local Model Download] kind=whisper-model-file source=\(downloadSource.displayName) model=\(modelName) path=\(relativePath) url=\(sourceURL.absoluteString)"
            )
            try await downloadRemoteFileWithRetry(sourceURL, to: destinationFileURL, operationName: "WhisperKit model file download")
        }

        guard isUsableWhisperKitModelFolder(modelFolderURL.path) else {
            throw NSError(
                domain: "LocalModelManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.whisperModelMissing")],
            )
        }

        return modelFolderURL.path
    }

    private func isPreparedStoragePathValid(_ storagePath: String, for model: LocalSTTModel) -> Bool {
        guard fileManager.fileExists(atPath: storagePath) else {
            return false
        }

        switch model {
        case .whisperLocal, .whisperLocalLarge:
            return isUsableWhisperKitModelFolder(storagePath)
        case .senseVoiceSmall, .qwen3ASR, .funASR:
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
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { component in
            let baseURL = URL(fileURLWithPath: storagePath, isDirectory: true)
            let compiledURL = baseURL.appendingPathComponent("\(component).mlmodelc", isDirectory: true)
            let packageURL = baseURL.appendingPathComponent("\(component).mlpackage", isDirectory: true)

            if fileManager.fileExists(atPath: compiledURL.path) {
                let weightURL = compiledURL
                    .appendingPathComponent("weights", isDirectory: true)
                    .appendingPathComponent("weight.bin", isDirectory: false)
                let modelURL = compiledURL.appendingPathComponent("model.mlmodel", isDirectory: false)
                return isUsableDownloadedWhisperFile(at: weightURL)
                    || isUsableDownloadedWhisperFile(at: modelURL)
            }

            return fileManager.fileExists(atPath: packageURL.path)
        }
    }

    private func whisperModelDirectoryName(for modelName: String) -> String {
        "openai_whisper-\(modelName)"
    }

    private func whisperModelRepositoryRootURL(downloadBasePath: String) -> URL {
        let root = URL(fileURLWithPath: downloadBasePath, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        let repositoryID = LocalModelDownloadCatalog.whisperKitModelRepository(source: .huggingFace)
        return repositoryID.split(separator: "/").reduce(root) { partialURL, component in
            partialURL.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    private func whisperModelFolderURL(for modelName: String, downloadBasePath: String) -> URL {
        whisperModelRepositoryRootURL(downloadBasePath: downloadBasePath)
            .appendingPathComponent(whisperModelDirectoryName(for: modelName), isDirectory: true)
    }

    private func whisperModelRepositoryFilesURL(source: ModelDownloadSource) -> URL {
        let endpoint = LocalModelDownloadCatalog.whisperKitModelEndpoint(source: source)
        let repositoryID = LocalModelDownloadCatalog.whisperKitModelRepository(source: source)
        return URL(string: "\(endpoint)/api/models/\(repositoryID)/revision/main")!
    }

    private func whisperTokenizerFolderURL(for modelName: String, downloadBasePath: String) -> URL {
        let root = URL(fileURLWithPath: downloadBasePath, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        let repositoryID = LocalModelDownloadCatalog.whisperTokenizerRepositoryID(for: modelName) ?? modelName
        return repositoryID.split(separator: "/").reduce(root) { partialURL, component in
            partialURL.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    private func isUsableWhisperTokenizerFolder(_ storagePath: String) -> Bool {
        ["tokenizer.json", "tokenizer_config.json"].allSatisfy { fileName in
            fileManager.fileExists(
                atPath: URL(fileURLWithPath: storagePath, isDirectory: true)
                    .appendingPathComponent(fileName, isDirectory: false)
                    .path,
            )
        }
    }

    private func isUsableDownloadedWhisperFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }

        let fileSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return fileSize > 0
    }

    private func loadRemoteFileWithRetry(_ url: URL, operationName: String) async throws -> Data {
        try await RequestRetry.perform(operationName: "\(operationName) \(url.absoluteString)") { [self] in
            try await remoteFileLoader(url)
        }
    }

    private func loadRemoteRepositoryFileListWithRetry(_ url: URL, operationName: String) async throws -> [String] {
        try await RequestRetry.perform(operationName: "\(operationName) \(url.absoluteString)") { [self] in
            try await remoteRepositoryFileListLoader(url)
        }
    }

    private func downloadRemoteFileWithRetry(_ sourceURL: URL, to destinationURL: URL, operationName: String) async throws {
        try await RequestRetry.perform(operationName: "\(operationName) \(sourceURL.absoluteString)") { [self] in
            try await remoteFileDownloader(sourceURL, destinationURL)
        }
    }

    private static func defaultRemoteFileLoader(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "LocalModelManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Tokenizer download returned a non-HTTP response."],
            )
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw NSError(
                domain: "LocalModelManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Tokenizer download failed with status \(http.statusCode)."],
            )
        }
        return data
    }

    private static func defaultRemoteRepositoryFileListLoader(from url: URL) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw NSError(
                domain: "LocalModelManager",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "WhisperKit repository listing request failed."],
            )
        }

        let payload = try JSONDecoder().decode(HubRepositorySiblingsResponse.self, from: data)
        return payload.siblings.map(\.rfilename)
    }

    private static func defaultRemoteFileDownloader(from sourceURL: URL, to destinationURL: URL) async throws {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 300
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw NSError(
                domain: "LocalModelManager",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "WhisperKit model file download failed."],
            )
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
}
