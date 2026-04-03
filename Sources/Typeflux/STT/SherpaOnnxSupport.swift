import Foundation

struct SherpaOnnxModelLayout {
    let runtimeArchiveURL: URL
    let runtimeRootDirectory: String
    let modelArchiveURL: URL
    let modelRootDirectory: String
    let requiredRelativePaths: [String]

    static func layout(for model: LocalSTTModel) -> SherpaOnnxModelLayout? {
        switch model {
        case .whisperLocal:
            return nil
        case .senseVoiceSmall:
            return SherpaOnnxModelLayout(
                runtimeArchiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.35/sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts.tar.bz2")!,
                runtimeRootDirectory: "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts",
                modelArchiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2")!,
                modelRootDirectory: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
                requiredRelativePaths: [
                    "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/bin/sherpa-onnx-offline",
                    "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libsherpa-onnx-c-api.dylib",
                    "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libonnxruntime.dylib",
                    "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx",
                    "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt"
                ]
            )
        case .qwen3ASR:
            return SherpaOnnxModelLayout(
                runtimeArchiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.35/sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts.tar.bz2")!,
                runtimeRootDirectory: "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts",
                modelArchiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2")!,
                modelRootDirectory: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
                requiredRelativePaths: [
                    "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/bin/sherpa-onnx-offline",
                    "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libsherpa-onnx-c-api.dylib",
                    "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libonnxruntime.dylib",
                    "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/conv_frontend.onnx",
                    "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/encoder.int8.onnx",
                    "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/decoder.int8.onnx",
                    "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/tokenizer"
                ]
            )
        }
    }

    func runtimeExecutableURL(storageURL: URL) -> URL {
        storageURL
            .appendingPathComponent(runtimeRootDirectory, isDirectory: true)
            .appendingPathComponent("bin/sherpa-onnx-offline", isDirectory: false)
    }

    func runtimeLibraryURL(storageURL: URL) -> URL {
        storageURL
            .appendingPathComponent(runtimeRootDirectory, isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
    }

    func modelDirectoryURL(storageURL: URL) -> URL {
        storageURL.appendingPathComponent(modelRootDirectory, isDirectory: true)
    }

    func isInstalled(storageURL: URL, fileManager: FileManager = .default) -> Bool {
        requiredRelativePaths.allSatisfy { relativePath in
            fileManager.fileExists(
                atPath: storageURL.appendingPathComponent(relativePath, isDirectory: false).path
            )
        }
    }
}

protocol SherpaOnnxModelInstalling {
    func prepareModel(
        _ model: LocalSTTModel,
        at storageURL: URL,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws -> String
}

final class SherpaOnnxModelInstaller: SherpaOnnxModelInstalling {
    private let fileManager: FileManager
    private let processRunner: ProcessCommandRunning
    private let urlSession: URLSession

    init(
        fileManager: FileManager = .default,
        processRunner: ProcessCommandRunning = ProcessCommandRunner(),
        urlSession: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.urlSession = urlSession
    }

    func prepareModel(
        _ model: LocalSTTModel,
        at storageURL: URL,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil
    ) async throws -> String {
        guard let layout = SherpaOnnxModelLayout.layout(for: model) else {
            throw NSError(
                domain: "SherpaOnnxModelInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.runtimeUnavailable", model.displayName)]
            )
        }

        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        if layout.isInstalled(storageURL: storageURL, fileManager: fileManager) {
            return storageURL.path
        }

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.runtimeDownloading"),
            progress: 0.15,
            storagePath: storageURL.path,
            source: nil
        ))
        try await downloadAndExtract(
            archiveURL: layout.runtimeArchiveURL,
            destinationURL: storageURL,
            archiveFileName: "\(layout.runtimeRootDirectory).tar.bz2"
        )

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.modelDownloading", model.displayName),
            progress: 0.55,
            storagePath: storageURL.path,
            source: nil
        ))
        try await downloadAndExtract(
            archiveURL: layout.modelArchiveURL,
            destinationURL: storageURL,
            archiveFileName: "\(layout.modelRootDirectory).tar.bz2"
        )

        guard layout.isInstalled(storageURL: storageURL, fileManager: fileManager) else {
            throw NSError(
                domain: "SherpaOnnxModelInstaller",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.modelAssetsMissing", model.displayName)]
            )
        }

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.modelReady", model.displayName),
            progress: 0.95,
            storagePath: storageURL.path,
            source: nil
        ))

        return storageURL.path
    }

    private func downloadAndExtract(
        archiveURL: URL,
        destinationURL: URL,
        archiveFileName: String
    ) async throws {
        let temporaryDirectory = destinationURL.appendingPathComponent(".download", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let localArchiveURL = temporaryDirectory.appendingPathComponent(archiveFileName, isDirectory: false)
        if fileManager.fileExists(atPath: localArchiveURL.path) {
            try fileManager.removeItem(at: localArchiveURL)
        }

        let (downloadedURL, _) = try await urlSession.download(from: archiveURL)
        if fileManager.fileExists(atPath: localArchiveURL.path) {
            try fileManager.removeItem(at: localArchiveURL)
        }
        try fileManager.moveItem(at: downloadedURL, to: localArchiveURL)

        _ = try await processRunner.run(
            executablePath: "/usr/bin/tar",
            arguments: [
                "-xjf",
                localArchiveURL.path,
                "-C",
                destinationURL.path
            ],
            environment: nil,
            currentDirectoryURL: destinationURL
        )

        try? fileManager.removeItem(at: localArchiveURL)
        try? fileManager.removeItem(at: temporaryDirectory)
    }
}

final class SherpaOnnxCommandLineDecoder {
    private let model: LocalSTTModel
    private let modelIdentifier: String
    private let modelFolder: String
    private let processRunner: ProcessCommandRunning

    init(
        model: LocalSTTModel,
        modelIdentifier: String,
        modelFolder: String,
        processRunner: ProcessCommandRunning = ProcessCommandRunner()
    ) {
        self.model = model
        self.modelIdentifier = modelIdentifier
        self.modelFolder = modelFolder
        self.processRunner = processRunner
    }

    func decode(audioFile: AudioFile) async throws -> String {
        guard let layout = SherpaOnnxModelLayout.layout(for: model) else {
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.runtimeUnavailable", model.displayName)]
            )
        }

        let storageURL = URL(fileURLWithPath: modelFolder, isDirectory: true)
        let executableURL = layout.runtimeExecutableURL(storageURL: storageURL)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.sherpaRuntimeMissing", executableURL.path)]
            )
        }

        let wavURL = try AudioFileTranscoder.wavFileURL(for: audioFile)
        let arguments = try commandLineArguments(layout: layout, storageURL: storageURL, audioURL: wavURL)
        let result = try await processRunner.run(
            executablePath: executableURL.path,
            arguments: arguments,
            environment: [
                "DYLD_LIBRARY_PATH": layout.runtimeLibraryURL(storageURL: storageURL).path
            ],
            currentDirectoryURL: storageURL
        )

        return try parseTranscript(stdout: result.stdout)
    }

    private func commandLineArguments(
        layout: SherpaOnnxModelLayout,
        storageURL: URL,
        audioURL: URL
    ) throws -> [String] {
        let modelDirectory = layout.modelDirectoryURL(storageURL: storageURL)
        switch model {
        case .whisperLocal:
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.runtimeUnavailable", model.displayName)]
            )
        case .senseVoiceSmall:
            return [
                "--print-args=false",
                "--tokens=\(modelDirectory.appendingPathComponent("tokens.txt").path)",
                "--sense-voice-model=\(modelDirectory.appendingPathComponent("model.int8.onnx").path)",
                "--sense-voice-language=\(AppLocalization.shared.language.whisperKitLanguageCode)",
                "--sense-voice-use-itn=true",
                "--provider=cpu",
                audioURL.path
            ]
        case .qwen3ASR:
            _ = modelIdentifier
            return [
                "--print-args=false",
                "--qwen3-asr-conv-frontend=\(modelDirectory.appendingPathComponent("conv_frontend.onnx").path)",
                "--qwen3-asr-encoder=\(modelDirectory.appendingPathComponent("encoder.int8.onnx").path)",
                "--qwen3-asr-decoder=\(modelDirectory.appendingPathComponent("decoder.int8.onnx").path)",
                "--qwen3-asr-tokenizer=\(modelDirectory.appendingPathComponent("tokenizer").path)",
                "--qwen3-asr-max-total-len=512",
                "--qwen3-asr-max-new-tokens=128",
                "--qwen3-asr-temperature=1e-06",
                "--qwen3-asr-top-p=0.8",
                "--provider=cpu",
                audioURL.path
            ]
        }
    }

    private func parseTranscript(stdout: String) throws -> String {
        let candidates = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let transcript = candidates.last else {
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: L("workflow.transcription.noSpeech")]
            )
        }

        return transcript
    }
}
