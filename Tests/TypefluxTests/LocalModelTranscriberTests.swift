@testable import Typeflux
import XCTest

final class LocalModelTranscriberTests: XCTestCase {
    func testSenseVoiceTranscriberUsesAutomaticLanguageDetectionAndParsesTranscript() async throws {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }

        let modelFolder = try makeSherpaModelFolder(for: .senseVoiceSmall)
        let runner = CapturingProcessRunner(stdout: "ignored log\n你好 Typeflux\n")
        let transcriber = SenseVoiceTranscriber(
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            modelFolder: modelFolder.path,
            processRunner: runner,
        )
        let audioFile = try makeTestWAVFile()

        let text = try await transcriber.transcribe(audioFile: audioFile)

        XCTAssertEqual(text, "你好 Typeflux")
        XCTAssertEqual(runner.lastExecutablePath, modelFolder.appendingPathComponent("sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/bin/sherpa-onnx-offline").path)
        XCTAssertEqual(runner.lastEnvironment?["DYLD_LIBRARY_PATH"], modelFolder.appendingPathComponent("sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib").path)
        XCTAssertTrue(runner.lastArguments.contains("--sense-voice-language=auto"))
        XCTAssertTrue(runner.lastArguments.contains("--sense-voice-use-itn=true"))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--sense-voice-model=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--tokens=") }))
        XCTAssertEqual(runner.lastArguments.last, audioFile.fileURL.path)
    }

    func testSenseVoiceTranscriberUsesAutomaticLanguageDetectionForEnglishUI() async throws {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }

        let modelFolder = try makeSherpaModelFolder(for: .senseVoiceSmall)
        let runner = CapturingProcessRunner(stdout: "hello Typeflux\n")
        let transcriber = SenseVoiceTranscriber(
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            modelFolder: modelFolder.path,
            processRunner: runner,
        )

        _ = try await transcriber.transcribe(audioFile: makeTestWAVFile())

        XCTAssertTrue(runner.lastArguments.contains("--sense-voice-language=auto"))
    }

    func testQwen3ASRTranscriberUsesQwen3ModelArguments() async throws {
        let modelFolder = try makeSherpaModelFolder(for: .qwen3ASR)
        let runner = CapturingProcessRunner(
            stdout: """
            log line
            {"lang": "", "emotion": "", "event": "", "text": "试一下前文三大模型的效果。", "timestamps": [], "durations": [], "tokens":["试", "一下", "前", "文", "三大", "模型", "的效果", "。"], "ys_log_probs": [], "words": []}

            """,
        )
        let transcriber = Qwen3ASRTranscriber(
            modelIdentifier: LocalSTTModel.qwen3ASR.defaultModelIdentifier,
            modelFolder: modelFolder.path,
            processRunner: runner,
        )
        let audioFile = try makeTestWAVFile()

        let text = try await transcriber.transcribe(audioFile: audioFile)

        XCTAssertEqual(text, "试一下前文三大模型的效果。")
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-conv-frontend=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-encoder=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-decoder=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-tokenizer=") }))
        XCTAssertTrue(runner.lastArguments.contains("--qwen3-asr-max-total-len=1500"))
        XCTAssertTrue(runner.lastArguments.contains("--qwen3-asr-max-new-tokens=512"))
        XCTAssertTrue(runner.lastArguments.contains("--qwen3-asr-temperature=0"))
        XCTAssertFalse(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-top-p=") }))
        XCTAssertEqual(runner.lastArguments.last, audioFile.fileURL.path)
    }

    func testLocalModelManagerPersistsSenseVoicePreparedModelInfo() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let appSupportURL = makeTemporaryApplicationSupportURL()
        let fakeInstaller = FakeSherpaOnnxInstaller()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: fakeInstaller,
            applicationSupportURL: appSupportURL,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
        )

        let updates = PreparationUpdateRecorder()
        try await manager.prepareModel(settingsStore: settingsStore) { update in
            updates.append(update)
        }

        let prepared = manager.preparedModelInfo(settingsStore: settingsStore)
        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.sourceDisplayName, ModelDownloadSource.huggingFace.displayName)
        XCTAssertEqual(
            prepared?.storagePath,
            manager.storagePath(for: LocalSTTConfiguration(settingsStore: settingsStore)),
        )
        XCTAssertEqual(fakeInstaller.lastPreparedModel, .senseVoiceSmall)
        XCTAssertEqual(fakeInstaller.lastStorageURL?.path, prepared?.storagePath)
        XCTAssertTrue((prepared?.storagePath ?? "").hasPrefix(appSupportURL.path))
        XCTAssertTrue(updates.values().contains(where: { $0.message == "fake sherpa ready" }))
    }

    func testLocalModelManagerPrefersBundledSenseVoicePreparedModelInfo() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let appSupportURL = makeTemporaryApplicationSupportURL()
        let firstManager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: FakeSherpaOnnxInstaller(),
            applicationSupportURL: appSupportURL,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
        )
        try await firstManager.prepareModel(settingsStore: settingsStore)

        let bundledModelsRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-bundled-models-\(UUID().uuidString)", isDirectory: true)
        let bundledStorageURL = bundledModelsRootURL
            .appendingPathComponent("senseVoiceSmall", isDirectory: true)
            .appendingPathComponent(LocalSTTModel.senseVoiceSmall.defaultModelIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: bundledStorageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: makeSherpaModelFolder(for: .senseVoiceSmall),
            to: bundledStorageURL,
        )

        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: FakeSherpaOnnxInstaller(),
            applicationSupportURL: appSupportURL,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
            bundledModelsRootURL: bundledModelsRootURL,
        )

        let prepared = try XCTUnwrap(manager.preparedModelInfo(settingsStore: settingsStore))

        XCTAssertEqual(prepared.storagePath, bundledStorageURL.path)
        XCTAssertEqual(prepared.sourceDisplayName, L("common.bundled"))
        XCTAssertFalse(prepared.storagePath.hasPrefix(appSupportURL.path))
    }

    func testPrepareModelSymlinksBundledSenseVoiceAndSkipsDownload() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let (manager, bundledStorageURL, fakeInstaller, appSupportURL) = try makeBundledSenseVoiceManager()

        let updates = PreparationUpdateRecorder()
        try await manager.prepareModel(settingsStore: settingsStore) { update in
            updates.append(update)
        }

        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        let expectedTargetPath = manager.storagePath(for: configuration)
        XCTAssertTrue(expectedTargetPath.hasPrefix(appSupportURL.path))

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: expectedTargetPath)
        XCTAssertEqual(destination, bundledStorageURL.path)
        XCTAssertEqual(fakeInstaller.preparedSources, [])

        let prepared = try XCTUnwrap(manager.preparedModelInfo(settingsStore: settingsStore))
        XCTAssertEqual(prepared.storagePath, bundledStorageURL.path)
        XCTAssertEqual(prepared.sourceDisplayName, L("common.bundled"))

        XCTAssertTrue(updates.values().contains(where: { $0.progress == 1 && $0.source == L("common.bundled") }))
    }

    func testPrepareModelIsIdempotentForBundledSenseVoice() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let (manager, bundledStorageURL, fakeInstaller, _) = try makeBundledSenseVoiceManager()

        try await manager.prepareModel(settingsStore: settingsStore)
        try await manager.prepareModel(settingsStore: settingsStore)

        let targetPath = manager.storagePath(for: LocalSTTConfiguration(settingsStore: settingsStore))
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: targetPath)
        XCTAssertEqual(destination, bundledStorageURL.path)
        XCTAssertEqual(fakeInstaller.preparedSources, [])
    }

    func testPrepareModelReplacesExistingDirectoryWithBundledSymlink() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let (manager, bundledStorageURL, fakeInstaller, _) = try makeBundledSenseVoiceManager()
        let configuration = LocalSTTConfiguration(settingsStore: settingsStore)
        let targetPath = manager.storagePath(for: configuration)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: targetPath, isDirectory: true),
            withIntermediateDirectories: true,
        )
        try Data("stale".utf8).write(
            to: URL(fileURLWithPath: targetPath, isDirectory: true)
                .appendingPathComponent("stale.txt"),
        )

        try await manager.prepareModel(settingsStore: settingsStore)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: targetPath)
        XCTAssertEqual(destination, bundledStorageURL.path)
        XCTAssertEqual(fakeInstaller.preparedSources, [])
    }

    func testPrepareModelFallsBackToDownloadWhenBundledPayloadIsIncomplete() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let bundledModelsRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-partial-bundle-\(UUID().uuidString)", isDirectory: true)
        let incompleteBundleURL = bundledModelsRootURL
            .appendingPathComponent("senseVoiceSmall", isDirectory: true)
            .appendingPathComponent(LocalSTTModel.senseVoiceSmall.defaultModelIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: incompleteBundleURL, withIntermediateDirectories: true)

        let appSupportURL = makeTemporaryApplicationSupportURL()
        let fakeInstaller = FakeSherpaOnnxInstaller()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: fakeInstaller,
            applicationSupportURL: appSupportURL,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
            bundledModelsRootURL: bundledModelsRootURL,
        )

        try await manager.prepareModel(settingsStore: settingsStore)

        XCTAssertEqual(fakeInstaller.preparedSources, [.huggingFace])
        let targetPath = manager.storagePath(for: LocalSTTConfiguration(settingsStore: settingsStore))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: targetPath))
        let prepared = try XCTUnwrap(manager.preparedModelInfo(settingsStore: settingsStore))
        XCTAssertEqual(prepared.sourceDisplayName, ModelDownloadSource.huggingFace.displayName)
    }

    func testAutoModelDownloadServiceUsesBundledSenseVoiceWithoutDownloading() throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localOptimizationEnabled = true

        let bundledModelsRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-auto-bundled-\(UUID().uuidString)", isDirectory: true)
        let bundledStorageURL = bundledModelsRootURL
            .appendingPathComponent("senseVoiceSmall", isDirectory: true)
            .appendingPathComponent(LocalSTTModel.senseVoiceSmall.defaultModelIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: bundledStorageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: makeSherpaModelFolder(for: .senseVoiceSmall),
            to: bundledStorageURL,
        )

        let fakeInstaller = FakeSherpaOnnxInstaller()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: fakeInstaller,
            applicationSupportURL: makeTemporaryApplicationSupportURL(),
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
            bundledModelsRootURL: bundledModelsRootURL,
        )
        let service = AutoModelDownloadService(
            modelManager: manager,
            settingsStore: settingsStore,
        )

        service.triggerIfNeeded()

        XCTAssertTrue(service.isModelReady)
        XCTAssertEqual(service.status, .completed)
        XCTAssertEqual(fakeInstaller.preparedSources, [])
        XCTAssertNotNil(service.makeTranscriberIfReady())
    }

    func testLocalModelManagerPersistsQwen3PreparedModelInfo() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .qwen3ASR
        settingsStore.localSTTModelIdentifier = LocalSTTModel.qwen3ASR.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let appSupportURL = makeTemporaryApplicationSupportURL()
        let fakeInstaller = FakeSherpaOnnxInstaller()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: fakeInstaller,
            applicationSupportURL: appSupportURL,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
        )

        try await manager.prepareModel(settingsStore: settingsStore)

        let prepared = manager.preparedModelInfo(settingsStore: settingsStore)
        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.storagePath, fakeInstaller.lastStorageURL?.path)
        XCTAssertEqual(fakeInstaller.lastPreparedModel, .qwen3ASR)
        XCTAssertTrue((prepared?.storagePath ?? "").hasPrefix(appSupportURL.path))
    }

    func testLocalModelManagerFallsBackToNextDownloadSource() async throws {
        let appSupportURL = makeTemporaryApplicationSupportURL()
        let fakeInstaller = FakeSherpaOnnxInstaller(failingSources: [.modelScope])
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: fakeInstaller,
            applicationSupportURL: appSupportURL,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.modelScope, .huggingFace]),
        )

        let resolvedPath = try await manager.downloadModelFilesOnly(
            configuration: LocalSTTConfiguration(
                model: .senseVoiceSmall,
                modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
                downloadSource: .modelScope,
                autoSetup: true,
            ),
        )

        XCTAssertEqual(resolvedPath, fakeInstaller.lastStorageURL?.path)
        XCTAssertEqual(fakeInstaller.preparedSources, [.modelScope, .huggingFace])
        XCTAssertTrue(
            SherpaOnnxModelLayout.layout(for: .senseVoiceSmall)!
                .isInstalled(storageURL: URL(fileURLWithPath: resolvedPath, isDirectory: true))
        )
    }

    func testNetworkDownloadSourceResolverRanksReachableSourcesByLatency() async throws {
        let resolver = NetworkLocalModelDownloadSourceResolver { url in
            let latency: TimeInterval
            let reachable: Bool
            if url.host == "sourceforge.net" || url.host == "hf-mirror.com" {
                latency = 0.05
                reachable = true
            } else {
                latency = 0.25
                reachable = true
            }
            return LocalModelDownloadSourceCandidate(
                source: .huggingFace,
                latency: latency,
                isReachable: reachable,
            )
        }

        let sources = await resolver.rankedSources(for: LocalSTTConfiguration(
            model: .senseVoiceSmall,
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            downloadSource: .huggingFace,
            autoSetup: true,
        ))

        XCTAssertEqual(sources.first, .modelScope)
        XCTAssertEqual(sources, [.modelScope, .huggingFace])
    }

    func testNetworkDownloadSourceResolverKeepsFallbackSourcesWhenProbeFails() async throws {
        let resolver = NetworkLocalModelDownloadSourceResolver { _ in
            LocalModelDownloadSourceCandidate(source: .huggingFace, latency: nil, isReachable: false)
        }

        let sources = await resolver.rankedSources(for: LocalSTTConfiguration(
            model: .whisperLocal,
            modelIdentifier: LocalSTTModel.whisperLocal.defaultModelIdentifier,
            downloadSource: .huggingFace,
            autoSetup: true,
        ))

        XCTAssertEqual(sources, [.huggingFace, .modelScope])
    }

    func testLocalModelManagerPrefetchesWhisperTokenizerForDomesticSource() async throws {
        let appSupportURL = makeTemporaryApplicationSupportURL()
        let downloadBasePath = appSupportURL
            .appendingPathComponent("Typeflux/LocalModels/whisperLocal/whisperkit-medium", isDirectory: true)
            .path
        let remoteLoader = CapturingRemoteFileLoader()
        let repositoryLoader = CapturingWhisperRepositoryFileListLoader(fileNames: [
            "openai_whisper-medium/MelSpectrogram.mlmodelc/weights/weight.bin",
            "openai_whisper-medium/AudioEncoder.mlmodelc/weights/weight.bin",
            "openai_whisper-medium/TextDecoder.mlmodelc/weights/weight.bin",
        ])
        let fileDownloader = CapturingWhisperFileDownloader()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: FakeSherpaOnnxInstaller(),
            applicationSupportURL: appSupportURL,
            localWhisperKitPreparerFactory: { _, modelFolder, _ in
                FakeWhisperKitPreparer(resolvedModelFolderPath: modelFolder)
            },
            remoteFileLoader: { url in
                try await remoteLoader.load(from: url)
            },
            remoteRepositoryFileListLoader: { url in
                try await repositoryLoader.load(from: url)
            },
            remoteFileDownloader: { sourceURL, destinationURL in
                try await fileDownloader.download(from: sourceURL, to: destinationURL)
            },
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.modelScope]),
        )

        let resolvedPath = try await manager.downloadModelFilesOnly(
            configuration: LocalSTTConfiguration(
                model: .whisperLocal,
                modelIdentifier: LocalSTTModel.whisperLocal.defaultModelIdentifier,
                downloadSource: .modelScope,
                autoSetup: true,
            ),
        )

        XCTAssertEqual(
            resolvedPath,
            URL(fileURLWithPath: downloadBasePath, isDirectory: true)
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-medium", isDirectory: true)
                .path
        )
        let requestedURLs = await remoteLoader.requestedURLs()
        XCTAssertEqual(requestedURLs.map(\.absoluteString), [
            "https://hf-mirror.com/openai/whisper-medium/resolve/main/tokenizer.json",
            "https://hf-mirror.com/openai/whisper-medium/resolve/main/tokenizer_config.json",
        ])
        let requestedFileListURLs = await repositoryLoader.requestedURLs()
        XCTAssertEqual(requestedFileListURLs.map(\.absoluteString), [
            "https://hf-mirror.com/api/models/argmaxinc/whisperkit-coreml/revision/main",
        ])
        let downloadedFiles = await fileDownloader.downloads()
        XCTAssertEqual(downloadedFiles.map(\.source.absoluteString), [
            "https://hf-mirror.com/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-medium/AudioEncoder.mlmodelc/weights/weight.bin",
            "https://hf-mirror.com/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-medium/MelSpectrogram.mlmodelc/weights/weight.bin",
            "https://hf-mirror.com/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-medium/TextDecoder.mlmodelc/weights/weight.bin",
        ])
        let tokenizerRoot = URL(fileURLWithPath: downloadBasePath, isDirectory: true)
            .appendingPathComponent("models/openai/whisper-medium", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenizerRoot.appendingPathComponent("tokenizer.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenizerRoot.appendingPathComponent("tokenizer_config.json").path))
    }

    func testLocalModelManagerRetriesWhisperTokenizerFileDownloads() async throws {
        let appSupportURL = makeTemporaryApplicationSupportURL()
        let remoteLoader = FlakyRemoteFileLoader(failuresBeforeSuccessPerURL: 3)
        let repositoryLoader = CapturingWhisperRepositoryFileListLoader(fileNames: [
            "openai_whisper-medium/MelSpectrogram.mlmodelc/weights/weight.bin",
            "openai_whisper-medium/AudioEncoder.mlmodelc/weights/weight.bin",
            "openai_whisper-medium/TextDecoder.mlmodelc/weights/weight.bin",
        ])
        let fileDownloader = CapturingWhisperFileDownloader()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: FakeSherpaOnnxInstaller(),
            applicationSupportURL: appSupportURL,
            localWhisperKitPreparerFactory: { _, modelFolder, _ in
                FakeWhisperKitPreparer(resolvedModelFolderPath: modelFolder)
            },
            remoteFileLoader: { url in
                try await remoteLoader.load(from: url)
            },
            remoteRepositoryFileListLoader: { url in
                try await repositoryLoader.load(from: url)
            },
            remoteFileDownloader: { sourceURL, destinationURL in
                try await fileDownloader.download(from: sourceURL, to: destinationURL)
            },
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.modelScope]),
        )

        _ = try await manager.downloadModelFilesOnly(
            configuration: LocalSTTConfiguration(
                model: .whisperLocal,
                modelIdentifier: LocalSTTModel.whisperLocal.defaultModelIdentifier,
                downloadSource: .modelScope,
                autoSetup: true,
            ),
        )

        let attemptCounts = await remoteLoader.attemptCountsByURL()
        XCTAssertEqual(attemptCounts["https://hf-mirror.com/openai/whisper-medium/resolve/main/tokenizer.json"], 4)
        XCTAssertEqual(attemptCounts["https://hf-mirror.com/openai/whisper-medium/resolve/main/tokenizer_config.json"], 4)
    }

    func testLocalModelManagerSkipsWhisperTokenizerPrefetchForHuggingFaceSource() async throws {
        let appSupportURL = makeTemporaryApplicationSupportURL()
        let downloadBasePath = appSupportURL
            .appendingPathComponent("Typeflux/LocalModels/whisperLocalLarge/whisperkit-large-v3", isDirectory: true)
            .path
        let preparedFolder = try makeWhisperKitPreparedFolder(
            at: URL(fileURLWithPath: downloadBasePath, isDirectory: true)
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3", isDirectory: true)
        )
        let remoteLoader = CapturingRemoteFileLoader()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: FakeSherpaOnnxInstaller(),
            applicationSupportURL: appSupportURL,
            whisperKitPreparerFactory: { _, _, _, _ in
                FakeWhisperKitPreparer(resolvedModelFolderPath: preparedFolder.path)
            },
            remoteFileLoader: { url in
                try await remoteLoader.load(from: url)
            },
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
        )

        let resolvedPath = try await manager.downloadModelFilesOnly(
            configuration: LocalSTTConfiguration(
                model: .whisperLocalLarge,
                modelIdentifier: LocalSTTModel.whisperLocalLarge.defaultModelIdentifier,
                downloadSource: .huggingFace,
                autoSetup: true,
            ),
        )

        XCTAssertEqual(resolvedPath, preparedFolder.path)
        let requestedURLs = await remoteLoader.requestedURLs()
        XCTAssertEqual(requestedURLs, [])
    }

    func testLocalModelTranscriberAutoPreparesQwen3BeforeTranscribing() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.sttProvider = .localModel
        settingsStore.localSTTModel = .qwen3ASR
        settingsStore.localSTTModelIdentifier = LocalSTTModel.qwen3ASR.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: FakeSherpaOnnxInstaller(),
            applicationSupportURL: makeTemporaryApplicationSupportURL(),
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
        )
        let transcriber = LocalModelTranscriber(
            settingsStore: settingsStore,
            modelManager: manager,
        )

        let text = try await transcriber.transcribe(audioFile: makeTestWAVFile())

        XCTAssertEqual(text, "test")
        XCTAssertNotNil(manager.preparedModelInfo(settingsStore: settingsStore))
    }

    func testWhisperKitTranscriberCacheExpiresAfterIdleKeepAliveWindow() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.sttProvider = .localModel
        settingsStore.localSTTModel = .whisperLocal
        settingsStore.localSTTModelIdentifier = "whisperkit-base"
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = false
        settingsStore.localSTTMemoryOptimizationEnabled = true

        let manager = FakeLocalSTTModelManager(preparedInfo: LocalSTTPreparedModelInfo(
            storagePath: "/tmp/typeflux-whisperkit-test",
            sourceDisplayName: ModelDownloadSource.huggingFace.displayName,
        ))
        let factory = FakeWhisperKitTranscriberFactory()
        let transcriber = LocalModelTranscriber(
            settingsStore: settingsStore,
            modelManager: manager,
            whisperKitKeepAliveDuration: 0.05,
            whisperKitTranscriberFactory: factory.makeTranscriber(modelName:modelFolder:),
        )
        let audioFile = try makeTestWAVFile()

        _ = try await transcriber.transcribe(audioFile: audioFile)
        _ = try await transcriber.transcribe(audioFile: audioFile)
        XCTAssertEqual(factory.createdTranscribers.count, 1)

        try await Task.sleep(nanoseconds: 120_000_000)
        _ = try await transcriber.transcribe(audioFile: audioFile)

        XCTAssertEqual(factory.createdTranscribers.count, 2)
        XCTAssertEqual(factory.createdTranscribers.map(\.modelName), ["base", "base"])
    }

    func testWhisperKitTranscriberCacheDoesNotExpireWhenMemoryOptimizationDisabled() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.sttProvider = .localModel
        settingsStore.localSTTModel = .whisperLocal
        settingsStore.localSTTModelIdentifier = "whisperkit-base"
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = false
        settingsStore.localSTTMemoryOptimizationEnabled = false

        let manager = FakeLocalSTTModelManager(preparedInfo: LocalSTTPreparedModelInfo(
            storagePath: "/tmp/typeflux-whisperkit-test",
            sourceDisplayName: ModelDownloadSource.huggingFace.displayName,
        ))
        let factory = FakeWhisperKitTranscriberFactory()
        let transcriber = LocalModelTranscriber(
            settingsStore: settingsStore,
            modelManager: manager,
            whisperKitKeepAliveDuration: 0.05,
            whisperKitTranscriberFactory: factory.makeTranscriber(modelName:modelFolder:),
        )
        let audioFile = try makeTestWAVFile()

        _ = try await transcriber.transcribe(audioFile: audioFile)
        try await Task.sleep(nanoseconds: 120_000_000)
        _ = try await transcriber.transcribe(audioFile: audioFile)

        XCTAssertEqual(factory.createdTranscribers.count, 1)
        XCTAssertEqual(factory.createdTranscribers.map(\.modelName), ["base"])
    }

    func testSherpaLayoutRejectsASCIIExecutableFixture() throws {
        let modelFolder = try makeSherpaModelFolder(for: .qwen3ASR, useMachORuntime: false)
        let layout = try XCTUnwrap(SherpaOnnxModelLayout.layout(for: .qwen3ASR))

        XCTAssertFalse(layout.isInstalled(storageURL: modelFolder, fileManager: .default))
        XCTAssertFalse(layout.hasUsableRuntimeExecutable(storageURL: modelFolder, fileManager: .default))
    }

    func testSenseVoiceLayoutRejectsMirrorErrorPayloads() throws {
        let modelFolder = try makeSherpaModelFolder(for: .senseVoiceSmall)
        let layout = try XCTUnwrap(SherpaOnnxModelLayout.layout(for: .senseVoiceSmall))
        let modelDirectory = modelFolder.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)

        try Data("Invalid rev id: master".utf8).write(to: modelDirectory.appendingPathComponent("tokens.txt"))
        try Data("Invalid rev id: master".utf8).write(to: modelDirectory.appendingPathComponent("model.int8.onnx"))

        XCTAssertFalse(layout.isInstalled(storageURL: modelFolder, fileManager: .default))
    }

    func testSherpaInstallerRetriesTransientArchiveDownloadFailures() async throws {
        let layout = try XCTUnwrap(SherpaOnnxModelLayout.layout(for: .senseVoiceSmall))
        let modelArtifact = try XCTUnwrap(LocalModelDownloadCatalog.sherpaOnnxModelArtifact(
            for: .senseVoiceSmall,
            source: .huggingFace,
        ))
        let fixturesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-sherpa-fixtures-\(UUID().uuidString)", isDirectory: true)
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-sherpa-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixturesRoot, withIntermediateDirectories: true)

        let runtimeArchiveURL = try await makeArchiveFixture(
            rootDirectoryName: layout.runtimeRootDirectory,
            requiredRelativePaths: [
                "bin/sherpa-onnx-offline",
                "lib/libsherpa-onnx-c-api.dylib",
                "lib/libonnxruntime.dylib",
            ],
            outputDirectory: fixturesRoot,
        )

        let modelDownloadCount: Int
        var downloadMap: [URL: URL] = [
            layout.runtimeArchiveURL: runtimeArchiveURL,
        ]
        switch modelArtifact {
        case let .archive(url, _):
            modelDownloadCount = 1
            downloadMap[url] = try await makeArchiveFixture(
                rootDirectoryName: layout.modelRootDirectory,
                requiredRelativePaths: [
                    "model.int8.onnx",
                    "tokens.txt",
                ],
                outputDirectory: fixturesRoot,
            )
        case let .files(files):
            modelDownloadCount = files.count
            downloadMap.merge(
                try makeDownloadedFileFixtures(for: files, outputDirectory: fixturesRoot),
                uniquingKeysWith: { _, new in new },
            )
        }

        let downloader = FlakyArchiveDownloader(
            archiveMap: downloadMap,
            failuresBeforeSuccess: 2,
        )
        let installer = SherpaOnnxModelInstaller(
            fileManager: .default,
            processRunner: ProcessCommandRunner(),
            archiveDownloader: downloader,
        )

        let preparedPath = try await installer.prepareModel(.senseVoiceSmall, at: installRoot)
        let downloadAttempts = await downloader.downloadAttemptCount()

        XCTAssertEqual(preparedPath, installRoot.path)
        XCTAssertGreaterThanOrEqual(downloadAttempts, modelDownloadCount + 3)
        XCTAssertTrue(layout.isInstalled(storageURL: installRoot, fileManager: .default))
    }

    func testSherpaInstallerReinstallsInvalidRuntimeExecutable() async throws {
        let layout = try XCTUnwrap(SherpaOnnxModelLayout.layout(for: .qwen3ASR))
        let fixturesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-sherpa-fixtures-\(UUID().uuidString)", isDirectory: true)
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-sherpa-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixturesRoot, withIntermediateDirectories: true)

        let runtimeArchiveURL = try await makeArchiveFixture(
            rootDirectoryName: layout.runtimeRootDirectory,
            requiredRelativePaths: [
                "bin/sherpa-onnx-offline",
                "lib/libsherpa-onnx-c-api.dylib",
                "lib/libonnxruntime.dylib",
            ],
            outputDirectory: fixturesRoot,
        )
        let modelArchiveURL = try await makeArchiveFixture(
            rootDirectoryName: layout.modelRootDirectory,
            requiredRelativePaths: [
                "conv_frontend.onnx",
                "encoder.int8.onnx",
                "decoder.int8.onnx",
                "tokenizer/tokenizer.json",
            ],
            outputDirectory: fixturesRoot,
        )

        let badExecutableURL = installRoot
            .appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
            .appendingPathComponent("bin/sherpa-onnx-offline", isDirectory: false)
        try FileManager.default.createDirectory(
            at: badExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("fixture".utf8).write(to: badExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: badExecutableURL.path,
        )
        XCTAssertFalse(layout.isInstalled(storageURL: installRoot, fileManager: .default))

        let installer = SherpaOnnxModelInstaller(
            fileManager: .default,
            processRunner: ProcessCommandRunner(),
            archiveDownloader: StaticArchiveDownloader(archiveMap: [
                layout.runtimeArchiveURL: runtimeArchiveURL,
                try XCTUnwrap(layout.modelArchiveURL): modelArchiveURL,
            ]),
        )

        let preparedPath = try await installer.prepareModel(.qwen3ASR, at: installRoot)

        XCTAssertEqual(preparedPath, installRoot.path)
        XCTAssertTrue(layout.isInstalled(storageURL: installRoot, fileManager: .default))
        XCTAssertGreaterThan(
            ((try? FileManager.default.attributesOfItem(atPath: badExecutableURL.path)[.size] as? NSNumber)?.int64Value ?? 0),
            0,
        )
    }

    func testSherpaInstallerPrunesRuntimeToMinimalOfflineSet() async throws {
        let layout = try XCTUnwrap(SherpaOnnxModelLayout.layout(for: .senseVoiceSmall))
        let fixturesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-sherpa-fixtures-\(UUID().uuidString)", isDirectory: true)
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-sherpa-install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: fixturesRoot)
            try? FileManager.default.removeItem(at: installRoot)
        }
        try FileManager.default.createDirectory(at: fixturesRoot, withIntermediateDirectories: true)

        let runtimeArchiveURL = try await makeArchiveFixture(
            rootDirectoryName: layout.runtimeRootDirectory,
            requiredRelativePaths: [
                "bin/sherpa-onnx-offline",
                "bin/sherpa-onnx",
                "include/sherpa-onnx/c-api/c-api.h",
                "lib/libonnxruntime.dylib",
                "lib/libsherpa-onnx-c-api.dylib",
                "lib/libsherpa-onnx-cxx-api.dylib",
            ],
            outputDirectory: fixturesRoot,
        )

        let modelDirectoryURL = fixturesRoot.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)

        guard case let .files(files) = try XCTUnwrap(LocalModelDownloadCatalog.sherpaOnnxModelArtifact(
            for: .senseVoiceSmall,
            source: .huggingFace,
        )) else {
            return XCTFail("Expected file-based SenseVoice artifact for Hugging Face")
        }

        var archiveMap: [URL: URL] = [
            layout.runtimeArchiveURL: runtimeArchiveURL,
        ]
        archiveMap.merge(
            try makeDownloadedFileFixtures(for: files, outputDirectory: fixturesRoot),
            uniquingKeysWith: { _, new in new },
        )

        let installer = SherpaOnnxModelInstaller(
            fileManager: .default,
            processRunner: ProcessCommandRunner(),
            archiveDownloader: StaticArchiveDownloader(archiveMap: archiveMap),
        )

        let preparedPath = try await installer.prepareModel(.senseVoiceSmall, at: installRoot, downloadSource: .huggingFace)

        XCTAssertEqual(preparedPath, installRoot.path)
        let runtimeRoot = installRoot.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeRoot.appendingPathComponent("bin/sherpa-onnx-offline").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot.appendingPathComponent("bin/sherpa-onnx").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot.appendingPathComponent("include").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot.appendingPathComponent("lib/libsherpa-onnx-cxx-api.dylib").path))

        let compatibilityLibraryPath = runtimeRoot.appendingPathComponent("lib/libonnxruntime.dylib").path
        let versionedLibraryPath = runtimeRoot
            .appendingPathComponent("lib/\(LocalModelDownloadCatalog.sherpaOnnxRuntimeVersionedLibraryName)")
            .path
        XCTAssertTrue(FileManager.default.fileExists(atPath: compatibilityLibraryPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionedLibraryPath))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: compatibilityLibraryPath),
            LocalModelDownloadCatalog.sherpaOnnxRuntimeVersionedLibraryName,
        )
    }

    private func makeSherpaModelFolder(for model: LocalSTTModel) throws -> URL {
        try makeSherpaModelFolder(for: model, useMachORuntime: true)
    }

    /// Constructs a LocalModelManager whose BundledModels root contains a complete SenseVoice
    /// payload so that `prepareModel` takes the bundled (symlink) path.
    private func makeBundledSenseVoiceManager() throws -> (
        manager: LocalModelManager,
        bundledStorageURL: URL,
        installer: FakeSherpaOnnxInstaller,
        applicationSupportURL: URL
    ) {
        let bundledModelsRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-bundled-models-\(UUID().uuidString)", isDirectory: true)
        let bundledStorageURL = bundledModelsRootURL
            .appendingPathComponent("senseVoiceSmall", isDirectory: true)
            .appendingPathComponent(LocalSTTModel.senseVoiceSmall.defaultModelIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundledStorageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try FileManager.default.copyItem(
            at: makeSherpaModelFolder(for: .senseVoiceSmall),
            to: bundledStorageURL,
        )

        let appSupportURL = makeTemporaryApplicationSupportURL()
        let installer = FakeSherpaOnnxInstaller()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: installer,
            applicationSupportURL: appSupportURL,
            downloadSourceResolver: FixedLocalModelDownloadSourceResolver(sources: [.huggingFace]),
            bundledModelsRootURL: bundledModelsRootURL,
        )
        return (manager, bundledStorageURL, installer, appSupportURL)
    }

    private func makeSherpaModelFolder(
        for model: LocalSTTModel,
        useMachORuntime: Bool,
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        guard let layout = SherpaOnnxModelLayout.layout(for: model) else {
            return root
        }

        let runtimeBinURL = root
            .appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let runtimeLibURL = root
            .appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeLibURL, withIntermediateDirectories: true)

        let executableURL = runtimeBinURL.appendingPathComponent("sherpa-onnx-offline", isDirectory: false)
        try sherpaRuntimeFixtureData(useMachO: useMachORuntime).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path,
        )
        try sherpaRuntimeFixtureData(useMachO: useMachORuntime)
            .write(to: runtimeLibURL.appendingPathComponent("libsherpa-onnx-c-api.dylib"))
        try sherpaRuntimeFixtureData(useMachO: useMachORuntime)
            .write(to: runtimeLibURL.appendingPathComponent("libonnxruntime.dylib"))

        let modelDirectory = root.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        switch model {
        case .whisperLocal, .whisperLocalLarge:
            break
        case .senseVoiceSmall:
            try senseVoiceModelFixtureData().write(to: modelDirectory.appendingPathComponent("model.int8.onnx"))
            try senseVoiceTokensFixtureData().write(to: modelDirectory.appendingPathComponent("tokens.txt"))
        case .qwen3ASR:
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("conv_frontend.onnx"))
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("encoder.int8.onnx"))
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("decoder.int8.onnx"))
            try FileManager.default.createDirectory(
                at: modelDirectory.appendingPathComponent("tokenizer", isDirectory: true),
                withIntermediateDirectories: true,
            )
        }

        return root
    }

    private func makeTestWAVFile() throws -> AudioFile {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-tests-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
        try Data().write(to: fileURL)
        return AudioFile(fileURL: fileURL, duration: 1)
    }

    private func makeDownloadedFileFixtures(
        for files: [SherpaOnnxModelFile],
        outputDirectory: URL,
    ) throws -> [URL: URL] {
        var downloadMap: [URL: URL] = [:]

        for file in files {
            let sourceFileURL = outputDirectory
                .appendingPathComponent("downloaded-files", isDirectory: true)
                .appendingPathComponent(file.relativePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: sourceFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try fixtureData(for: file.relativePath).write(to: sourceFileURL)
            downloadMap[file.url] = sourceFileURL
        }

        return downloadMap
    }

    private func makeArchiveFixture(
        rootDirectoryName: String,
        requiredRelativePaths: [String],
        outputDirectory: URL,
    ) async throws -> URL {
        let packageRoot = outputDirectory.appendingPathComponent(rootDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        for relativePath in requiredRelativePaths {
            let fileURL = packageRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            if fileURL.lastPathComponent == "sherpa-onnx-offline" {
                try sherpaRuntimeFixtureData(useMachO: true).write(to: fileURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o755))],
                    ofItemAtPath: fileURL.path,
                )
            } else if fileURL.pathExtension == "dylib" {
                try sherpaRuntimeFixtureData(useMachO: true).write(to: fileURL)
            } else if fileURL.lastPathComponent == "model.int8.onnx" {
                try senseVoiceModelFixtureData().write(to: fileURL)
            } else if fileURL.lastPathComponent == "tokens.txt" {
                try senseVoiceTokensFixtureData().write(to: fileURL)
            } else {
                try Data("fixture".utf8).write(to: fileURL)
            }
        }

        let archiveURL = outputDirectory.appendingPathComponent("\(rootDirectoryName).tar.bz2")
        _ = try await ProcessCommandRunner().run(
            executablePath: "/usr/bin/tar",
            arguments: [
                "-cjf",
                archiveURL.path,
                rootDirectoryName,
            ],
            environment: nil,
            currentDirectoryURL: outputDirectory,
        )
        return archiveURL
    }

    private func sherpaRuntimeFixtureData(useMachO: Bool) -> Data {
        useMachO
            ? Data([0xCF, 0xFA, 0xED, 0xFE, 0x46, 0x49, 0x58, 0x54, 0x55, 0x52, 0x45])
            : Data("fixture".utf8)
    }

    private func fixtureData(for relativePath: String) -> Data {
        let lastPathComponent = URL(fileURLWithPath: relativePath).lastPathComponent
        switch lastPathComponent {
        case "model.int8.onnx":
            return senseVoiceModelFixtureData()
        case "tokens.txt":
            return senseVoiceTokensFixtureData()
        default:
            return Data("fixture".utf8)
        }
    }

    private func senseVoiceModelFixtureData() -> Data {
        Data(repeating: 0x5A, count: 1_048_576)
    }

    private func senseVoiceTokensFixtureData() -> Data {
        Data(
            """
            <unk> 0
            <s> 1
            </s> 2
            ▁the 3
            """.utf8,
        )
    }

    private func makeWhisperKitPreparedFolder(at folderURL: URL) throws -> URL {
        for component in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            let componentURL = folderURL.appendingPathComponent(component, isDirectory: true)
            let weightsURL = componentURL
                .appendingPathComponent("weights", isDirectory: true)
                .appendingPathComponent("weight.bin", isDirectory: false)
            try FileManager.default.createDirectory(
                at: weightsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Data("fixture".utf8).write(to: weightsURL)
        }
        return folderURL
    }
}

private func makeTemporaryApplicationSupportURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("typeflux-app-support-\(UUID().uuidString)", isDirectory: true)
}

private final class CapturingProcessRunner: ProcessCommandRunning {
    let stdout: String
    var lastExecutablePath: String?
    var lastArguments: [String] = []
    var lastEnvironment: [String: String]?

    init(stdout: String) {
        self.stdout = stdout
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectoryURL: URL?,
    ) async throws -> ProcessCommandResult {
        _ = currentDirectoryURL
        lastExecutablePath = executablePath
        lastArguments = arguments
        lastEnvironment = environment
        return ProcessCommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }
}

private final class FakeSherpaOnnxInstaller: SherpaOnnxModelInstalling {
    private let failingSources: Set<ModelDownloadSource>
    var lastPreparedModel: LocalSTTModel?
    var lastStorageURL: URL?
    private(set) var preparedSources: [ModelDownloadSource] = []

    init(failingSources: Set<ModelDownloadSource> = []) {
        self.failingSources = failingSources
    }

    func prepareModel(
        _ model: LocalSTTModel,
        at storageURL: URL,
        downloadSource: ModelDownloadSource,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?,
    ) async throws -> String {
        preparedSources.append(downloadSource)
        if failingSources.contains(downloadSource) {
            throw NSError(domain: "FakeSherpaOnnxInstaller", code: 1, userInfo: nil)
        }

        lastPreparedModel = model
        lastStorageURL = storageURL

        onUpdate?(LocalSTTPreparationUpdate(
            message: "fake sherpa ready",
            progress: 0.9,
            storagePath: storageURL.path,
            source: nil,
        ))

        guard let layout = SherpaOnnxModelLayout.layout(for: model) else {
            return storageURL.path
        }

        for relativePath in layout.requiredRelativePaths {
            let fileURL = storageURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            if relativePath.hasSuffix("/tokenizer") {
                try FileManager.default.createDirectory(
                    at: fileURL,
                    withIntermediateDirectories: true,
                )
            } else {
                if fileURL.lastPathComponent == "sherpa-onnx-offline" {
                    try Data("#!/bin/sh\necho test\n".utf8).write(to: fileURL)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o755))],
                        ofItemAtPath: fileURL.path,
                    )
                } else if fileURL.lastPathComponent == "model.int8.onnx" {
                    try Data(repeating: 0x5A, count: 1_048_576).write(to: fileURL)
                } else if fileURL.lastPathComponent == "tokens.txt" {
                    try Data(
                        """
                        <unk> 0
                        <s> 1
                        </s> 2
                        ▁the 3
                        """.utf8,
                    ).write(to: fileURL)
                } else {
                    let payload = fileURL.pathExtension == "dylib"
                        ? Data([0xCF, 0xFA, 0xED, 0xFE, 0x46, 0x49, 0x58, 0x54, 0x55, 0x52, 0x45])
                        : Data("fixture".utf8)
                    try payload.write(to: fileURL)
                }
            }
        }

        return storageURL.path
    }
}

private final class FakeLocalSTTModelManager: LocalSTTModelManaging {
    private let preparedInfo: LocalSTTPreparedModelInfo?

    init(preparedInfo: LocalSTTPreparedModelInfo?) {
        self.preparedInfo = preparedInfo
    }

    func prepareModel(
        settingsStore _: SettingsStore,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?,
    ) async throws {}

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        preparedInfo
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        preparedInfo != nil
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}

    func storagePath(for configuration: LocalSTTConfiguration) -> String {
        "/tmp/\(configuration.modelIdentifier)"
    }
}

private final class FakeWhisperKitTranscriberFactory {
    private(set) var createdTranscribers: [FakeWhisperKitTranscriber] = []

    func makeTranscriber(modelName: String, modelFolder: String) -> LocalWhisperKitTranscribing {
        let transcriber = FakeWhisperKitTranscriber(modelName: modelName, modelFolder: modelFolder)
        createdTranscribers.append(transcriber)
        return transcriber
    }
}

private final class FakeWhisperKitTranscriber: LocalWhisperKitTranscribing {
    let modelName: String
    let modelFolder: String

    init(modelName: String, modelFolder: String) {
        self.modelName = modelName
        self.modelFolder = modelFolder
    }

    func transcribeStream(
        audioFile _: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        await onUpdate(TranscriptionSnapshot(text: "cached transcript", isFinal: true))
        return "cached transcript"
    }

    func prepare(onProgress _: ((Double, String) -> Void)?) async throws {}
}

private struct FakeWhisperKitPreparer: WhisperKitPreparing {
    let resolvedModelFolderPath: String?

    func prepare(onProgress _: ((Double, String) -> Void)?) async throws {}
}

private actor CapturingRemoteFileLoader {
    private var urls: [URL] = []

    func load(from url: URL) async throws -> Data {
        urls.append(url)
        if url.lastPathComponent == "tokenizer.json" {
            return Data(
                """
                {
                  "version": "1.0",
                  "truncation": null,
                  "padding": null,
                  "added_tokens": [],
                  "normalizer": null,
                  "pre_tokenizer": null,
                  "post_processor": null,
                  "decoder": null,
                  "model": {
                    "type": "BPE",
                    "dropout": null,
                    "unk_token": "<|endoftext|>",
                    "continuing_subword_prefix": "",
                    "end_of_word_suffix": "",
                    "fuse_unk": false,
                    "byte_fallback": false,
                    "vocab": {
                      "<|endoftext|>": 0
                    },
                    "merges": []
                  }
                }
                """.utf8,
            )
        }

        return Data(
            """
            {
              "tokenizer_class": "GPT2Tokenizer",
              "unk_token": "<|endoftext|>",
              "bos_token": "<|endoftext|>",
              "eos_token": "<|endoftext|>",
              "clean_up_tokenization_spaces": false
            }
            """.utf8,
        )
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private actor FlakyRemoteFileLoader {
    private let failuresBeforeSuccessPerURL: Int
    private var attemptCounts: [URL: Int] = [:]
    private let payloadLoader = CapturingRemoteFileLoader()

    init(failuresBeforeSuccessPerURL: Int) {
        self.failuresBeforeSuccessPerURL = failuresBeforeSuccessPerURL
    }

    func load(from url: URL) async throws -> Data {
        let attempts = (attemptCounts[url] ?? 0) + 1
        attemptCounts[url] = attempts
        if attempts <= failuresBeforeSuccessPerURL {
            throw NSError(domain: "FlakyRemoteFileLoader", code: attempts, userInfo: nil)
        }
        return try await payloadLoader.load(from: url)
    }

    func attemptCountsByURL() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: attemptCounts.map { ($0.key.absoluteString, $0.value) })
    }
}

private actor CapturingWhisperRepositoryFileListLoader {
    private let fileNames: [String]
    private var urls: [URL] = []

    init(fileNames: [String]) {
        self.fileNames = fileNames
    }

    func load(from url: URL) async throws -> [String] {
        urls.append(url)
        return fileNames
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private actor CapturingWhisperFileDownloader {
    struct Download: Equatable {
        let source: URL
        let destination: URL
    }

    private var capturedDownloads: [Download] = []

    func download(from sourceURL: URL, to destinationURL: URL) async throws {
        capturedDownloads.append(Download(source: sourceURL, destination: destinationURL))
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("fixture".utf8).write(to: destinationURL)
    }

    func downloads() -> [Download] {
        capturedDownloads
    }
}

private final class StaticArchiveDownloader: SherpaOnnxArchiveDownloading {
    private let archiveMap: [URL: URL]

    init(archiveMap: [URL: URL]) {
        self.archiveMap = archiveMap
    }

    func downloadArchive(from url: URL) async throws -> URL {
        let sourceURL = try XCTUnwrap(archiveMap[url])
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-copy-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("tar.bz2")
        try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        return copyURL
    }
}

private actor FlakyArchiveDownloader: SherpaOnnxArchiveDownloading {
    private let archiveMap: [URL: URL]
    private var remainingFailures: Int
    private var attempts = 0

    init(archiveMap: [URL: URL], failuresBeforeSuccess: Int) {
        self.archiveMap = archiveMap
        remainingFailures = failuresBeforeSuccess
    }

    func downloadArchive(from url: URL) async throws -> URL {
        attempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw NSError(domain: "FlakyArchiveDownloader", code: 1, userInfo: nil)
        }

        let sourceURL = try XCTUnwrap(archiveMap[url])
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-copy-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("tar.bz2")
        try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        return copyURL
    }

    func downloadAttemptCount() -> Int {
        attempts
    }
}

private final class PreparationUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [LocalSTTPreparationUpdate] = []

    func append(_ update: LocalSTTPreparationUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func values() -> [LocalSTTPreparationUpdate] {
        lock.lock()
        let current = updates
        lock.unlock()
        return current
    }
}
