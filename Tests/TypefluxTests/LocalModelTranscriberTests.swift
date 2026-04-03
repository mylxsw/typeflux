@testable import Typeflux
import XCTest

final class LocalModelTranscriberTests: XCTestCase {
    func testSenseVoiceTranscriberUsesChineseLanguageHintAndParsesTranscript() async throws {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }

        let modelFolder = try makeSherpaModelFolder(for: .senseVoiceSmall)
        let runner = CapturingProcessRunner(stdout: "ignored log\n你好 Typeflux\n")
        let transcriber = SenseVoiceTranscriber(
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            modelFolder: modelFolder.path,
            processRunner: runner
        )
        let audioFile = try makeTestWAVFile()

        let text = try await transcriber.transcribe(audioFile: audioFile)

        XCTAssertEqual(text, "你好 Typeflux")
        XCTAssertEqual(runner.lastExecutablePath, modelFolder.appendingPathComponent("sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/bin/sherpa-onnx-offline").path)
        XCTAssertEqual(runner.lastEnvironment?["DYLD_LIBRARY_PATH"], modelFolder.appendingPathComponent("sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib").path)
        XCTAssertTrue(runner.lastArguments.contains("--sense-voice-language=zh"))
        XCTAssertTrue(runner.lastArguments.contains("--sense-voice-use-itn=true"))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--sense-voice-model=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--tokens=") }))
        XCTAssertEqual(runner.lastArguments.last, audioFile.fileURL.path)
    }

    func testSenseVoiceTranscriberUsesEnglishLanguageHint() async throws {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }

        let modelFolder = try makeSherpaModelFolder(for: .senseVoiceSmall)
        let runner = CapturingProcessRunner(stdout: "hello Typeflux\n")
        let transcriber = SenseVoiceTranscriber(
            modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
            modelFolder: modelFolder.path,
            processRunner: runner
        )

        _ = try await transcriber.transcribe(audioFile: makeTestWAVFile())

        XCTAssertTrue(runner.lastArguments.contains("--sense-voice-language=en"))
    }

    func testQwen3ASRTranscriberUsesQwen3ModelArguments() async throws {
        let modelFolder = try makeSherpaModelFolder(for: .qwen3ASR)
        let runner = CapturingProcessRunner(
            stdout: """
            log line
            {"lang": "", "emotion": "", "event": "", "text": "试一下前文三大模型的效果。", "timestamps": [], "durations": [], "tokens":["试", "一下", "前", "文", "三大", "模型", "的效果", "。"], "ys_log_probs": [], "words": []}

            """
        )
        let transcriber = Qwen3ASRTranscriber(
            modelIdentifier: LocalSTTModel.qwen3ASR.defaultModelIdentifier,
            modelFolder: modelFolder.path,
            processRunner: runner
        )
        let audioFile = try makeTestWAVFile()

        let text = try await transcriber.transcribe(audioFile: audioFile)

        XCTAssertEqual(text, "试一下前文三大模型的效果。")
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-conv-frontend=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-encoder=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-decoder=") }))
        XCTAssertTrue(runner.lastArguments.contains(where: { $0.hasPrefix("--qwen3-asr-tokenizer=") }))
        XCTAssertTrue(runner.lastArguments.contains("--qwen3-asr-max-total-len=512"))
        XCTAssertTrue(runner.lastArguments.contains("--qwen3-asr-max-new-tokens=128"))
        XCTAssertEqual(runner.lastArguments.last, audioFile.fileURL.path)
    }

    func testLocalModelManagerPersistsSenseVoicePreparedModelInfo() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .senseVoiceSmall
        settingsStore.localSTTModelIdentifier = LocalSTTModel.senseVoiceSmall.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let fakeInstaller = FakeSherpaOnnxInstaller()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: fakeInstaller
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
            manager.storagePath(for: LocalSTTConfiguration(settingsStore: settingsStore))
        )
        XCTAssertEqual(fakeInstaller.lastPreparedModel, .senseVoiceSmall)
        XCTAssertEqual(fakeInstaller.lastStorageURL?.path, prepared?.storagePath)
        XCTAssertTrue(updates.values().contains(where: { $0.message == "fake sherpa ready" }))
    }

    func testLocalModelManagerPersistsQwen3PreparedModelInfo() async throws {
        let suiteName = "LocalModelTranscriberTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.localSTTModel = .qwen3ASR
        settingsStore.localSTTModelIdentifier = LocalSTTModel.qwen3ASR.defaultModelIdentifier
        settingsStore.localSTTDownloadSource = .huggingFace
        settingsStore.localSTTAutoSetup = true

        let fakeInstaller = FakeSherpaOnnxInstaller()
        let manager = LocalModelManager(
            fileManager: .default,
            sherpaOnnxInstaller: fakeInstaller
        )

        try await manager.prepareModel(settingsStore: settingsStore)

        let prepared = manager.preparedModelInfo(settingsStore: settingsStore)
        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.storagePath, fakeInstaller.lastStorageURL?.path)
        XCTAssertEqual(fakeInstaller.lastPreparedModel, .qwen3ASR)
    }

    func testSherpaInstallerRetriesTransientArchiveDownloadFailures() async throws {
        let layout = try XCTUnwrap(SherpaOnnxModelLayout.layout(for: .senseVoiceSmall))
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
                "lib/libonnxruntime.dylib"
            ],
            outputDirectory: fixturesRoot
        )
        let modelArchiveURL = try await makeArchiveFixture(
            rootDirectoryName: layout.modelRootDirectory,
            requiredRelativePaths: [
                "model.int8.onnx",
                "tokens.txt"
            ],
            outputDirectory: fixturesRoot
        )

        let downloader = FlakyArchiveDownloader(
            archiveMap: [
                layout.runtimeArchiveURL: runtimeArchiveURL,
                layout.modelArchiveURL: modelArchiveURL
            ],
            failuresBeforeSuccess: 2
        )
        let installer = SherpaOnnxModelInstaller(
            fileManager: .default,
            processRunner: ProcessCommandRunner(),
            archiveDownloader: downloader
        )

        let preparedPath = try await installer.prepareModel(.senseVoiceSmall, at: installRoot)
        let downloadAttempts = await downloader.downloadAttemptCount()

        XCTAssertEqual(preparedPath, installRoot.path)
        XCTAssertGreaterThanOrEqual(downloadAttempts, 4)
        XCTAssertTrue(layout.isInstalled(storageURL: installRoot, fileManager: .default))
    }

    func testSherpaInstallerReinstallsZeroByteRuntimeExecutable() async throws {
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
                "lib/libonnxruntime.dylib"
            ],
            outputDirectory: fixturesRoot
        )
        let modelArchiveURL = try await makeArchiveFixture(
            rootDirectoryName: layout.modelRootDirectory,
            requiredRelativePaths: [
                "conv_frontend.onnx",
                "encoder.int8.onnx",
                "decoder.int8.onnx",
                "tokenizer/tokenizer.json"
            ],
            outputDirectory: fixturesRoot
        )

        let badExecutableURL = installRoot
            .appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
            .appendingPathComponent("bin/sherpa-onnx-offline", isDirectory: false)
        try FileManager.default.createDirectory(
            at: badExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: badExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: badExecutableURL.path
        )
        XCTAssertFalse(layout.isInstalled(storageURL: installRoot, fileManager: .default))

        let installer = SherpaOnnxModelInstaller(
            fileManager: .default,
            processRunner: ProcessCommandRunner(),
            archiveDownloader: StaticArchiveDownloader(archiveMap: [
                layout.runtimeArchiveURL: runtimeArchiveURL,
                layout.modelArchiveURL: modelArchiveURL
            ])
        )

        let preparedPath = try await installer.prepareModel(.qwen3ASR, at: installRoot)

        XCTAssertEqual(preparedPath, installRoot.path)
        XCTAssertTrue(layout.isInstalled(storageURL: installRoot, fileManager: .default))
        XCTAssertGreaterThan(
            ((try? FileManager.default.attributesOfItem(atPath: badExecutableURL.path)[.size] as? NSNumber)?.int64Value ?? 0),
            0
        )
    }

    private func makeSherpaModelFolder(for model: LocalSTTModel) throws -> URL {
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
        try Data("#!/bin/sh\necho test\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )
        try Data("fixture".utf8).write(to: runtimeLibURL.appendingPathComponent("libsherpa-onnx-c-api.dylib"))
        try Data("fixture".utf8).write(to: runtimeLibURL.appendingPathComponent("libonnxruntime.dylib"))

        let modelDirectory = root.appendingPathComponent(layout.modelRootDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        switch model {
        case .whisperLocal:
            break
        case .senseVoiceSmall:
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("model.int8.onnx"))
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("tokens.txt"))
        case .qwen3ASR:
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("conv_frontend.onnx"))
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("encoder.int8.onnx"))
            try Data("fixture".utf8).write(to: modelDirectory.appendingPathComponent("decoder.int8.onnx"))
            try FileManager.default.createDirectory(
                at: modelDirectory.appendingPathComponent("tokenizer", isDirectory: true),
                withIntermediateDirectories: true
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

    private func makeArchiveFixture(
        rootDirectoryName: String,
        requiredRelativePaths: [String],
        outputDirectory: URL
    ) async throws -> URL {
        let packageRoot = outputDirectory.appendingPathComponent(rootDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        for relativePath in requiredRelativePaths {
            let fileURL = packageRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: fileURL)
            if fileURL.lastPathComponent == "sherpa-onnx-offline" {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o755))],
                    ofItemAtPath: fileURL.path
                )
            }
        }

        let archiveURL = outputDirectory.appendingPathComponent("\(rootDirectoryName).tar.bz2")
        _ = try await ProcessCommandRunner().run(
            executablePath: "/usr/bin/tar",
            arguments: [
                "-cjf",
                archiveURL.path,
                rootDirectoryName
            ],
            environment: nil,
            currentDirectoryURL: outputDirectory
        )
        return archiveURL
    }
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
        currentDirectoryURL: URL?
    ) async throws -> ProcessCommandResult {
        _ = currentDirectoryURL
        lastExecutablePath = executablePath
        lastArguments = arguments
        lastEnvironment = environment
        return ProcessCommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }
}

private final class FakeSherpaOnnxInstaller: SherpaOnnxModelInstalling {
    var lastPreparedModel: LocalSTTModel?
    var lastStorageURL: URL?

    func prepareModel(
        _ model: LocalSTTModel,
        at storageURL: URL,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws -> String {
        lastPreparedModel = model
        lastStorageURL = storageURL

        onUpdate?(LocalSTTPreparationUpdate(
            message: "fake sherpa ready",
            progress: 0.9,
            storagePath: storageURL.path,
            source: nil
        ))

        guard let layout = SherpaOnnxModelLayout.layout(for: model) else {
            return storageURL.path
        }

        for relativePath in layout.requiredRelativePaths {
            let fileURL = storageURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if relativePath.hasSuffix("/tokenizer") {
                try FileManager.default.createDirectory(
                    at: fileURL,
                    withIntermediateDirectories: true
                )
            } else {
                try Data("fixture".utf8).write(to: fileURL)
                if fileURL.lastPathComponent == "sherpa-onnx-offline" {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: Int16(0o755))],
                        ofItemAtPath: fileURL.path
                    )
                }
            }
        }

        return storageURL.path
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
        self.remainingFailures = failuresBeforeSuccess
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
