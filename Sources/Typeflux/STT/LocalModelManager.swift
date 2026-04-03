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
        let storagePath = storagePath(for: configuration)

        onUpdate?(LocalSTTPreparationUpdate(
            message: "Cleaning legacy Python runtime...",
            progress: 0.15,
            storagePath: storagePath,
            source: nil
        ))
        try? cleanupLegacyPythonRuntime()

        onUpdate?(LocalSTTPreparationUpdate(
            message: "Preparing native local speech runtime...",
            progress: 0.55,
            storagePath: storagePath,
            source: configuration.downloadSource.displayName
        ))

        try fileManager.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
        let resourceURL = resourceDirectoryURL(for: configuration.model)
        try fileManager.createDirectory(at: resourceURL, withIntermediateDirectories: true)
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

    func preparedModelInfo(settingsStore: SettingsStore) -> LocalSTTPreparedModelInfo? {
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        guard
            let record = loadPreparedRecord(for: configuration.model),
            record.modelIdentifier == configuration.modelIdentifier,
            record.source == configuration.downloadSource.rawValue,
            fileManager.fileExists(atPath: record.storagePath)
        else {
            return nil
        }

        return LocalSTTPreparedModelInfo(
            storagePath: record.storagePath,
            sourceDisplayName: ModelDownloadSource(rawValue: record.source)?.displayName ?? configuration.downloadSource.displayName
        )
    }

    func isModelDownloaded(_ model: LocalSTTModel) -> Bool {
        fileManager.fileExists(atPath: resourceDirectoryURL(for: model).path)
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
}
