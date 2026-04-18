import Foundation

struct SherpaOnnxModelFile: Equatable {
    let url: URL
    let relativePath: String
}

enum SherpaOnnxModelArtifact: Equatable {
    case archive(url: URL, fileName: String)
    case files([SherpaOnnxModelFile])

    var archiveURL: URL? {
        switch self {
        case let .archive(url, _):
            url
        case .files:
            nil
        }
    }
}

struct SherpaOnnxModelLayout {
    let runtimeArchiveURL: URL
    let runtimeRootDirectory: String
    let modelArtifact: SherpaOnnxModelArtifact
    let modelRootDirectory: String
    let requiredRelativePaths: [String]

    var modelArchiveURL: URL? {
        modelArtifact.archiveURL
    }

    static func layout(
        for model: LocalSTTModel,
        downloadSource: ModelDownloadSource = .huggingFace,
    ) -> SherpaOnnxModelLayout? {
        switch model {
        case .whisperLocal, .whisperLocalLarge:
            return nil
        case .senseVoiceSmall:
            guard let modelRootDirectory = LocalModelDownloadCatalog.sherpaOnnxModelDirectoryName(for: model),
                  let modelArtifact = LocalModelDownloadCatalog.sherpaOnnxModelArtifact(
                    for: model,
                    source: downloadSource,
                  )
            else {
                return nil
            }
            return SherpaOnnxModelLayout(
                runtimeArchiveURL: LocalModelDownloadCatalog.sherpaOnnxRuntimeArchiveURL(source: downloadSource),
                runtimeRootDirectory: LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName,
                modelArtifact: modelArtifact,
                modelRootDirectory: modelRootDirectory,
                requiredRelativePaths: [
                    "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/bin/sherpa-onnx-offline",
                    "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/lib/libsherpa-onnx-c-api.dylib",
                    "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/lib/libonnxruntime.dylib",
                    "\(modelRootDirectory)/model.int8.onnx",
                    "\(modelRootDirectory)/tokens.txt",
                ],
            )
        case .qwen3ASR:
            guard let modelRootDirectory = LocalModelDownloadCatalog.sherpaOnnxModelDirectoryName(for: model),
                  let modelArtifact = LocalModelDownloadCatalog.sherpaOnnxModelArtifact(
                    for: model,
                    source: downloadSource,
                  )
            else {
                return nil
            }
            return SherpaOnnxModelLayout(
                runtimeArchiveURL: LocalModelDownloadCatalog.sherpaOnnxRuntimeArchiveURL(source: downloadSource),
                runtimeRootDirectory: LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName,
                modelArtifact: modelArtifact,
                modelRootDirectory: modelRootDirectory,
                requiredRelativePaths: [
                    "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/bin/sherpa-onnx-offline",
                    "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/lib/libsherpa-onnx-c-api.dylib",
                    "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/lib/libonnxruntime.dylib",
                    "\(modelRootDirectory)/conv_frontend.onnx",
                    "\(modelRootDirectory)/encoder.int8.onnx",
                    "\(modelRootDirectory)/decoder.int8.onnx",
                    "\(modelRootDirectory)/tokenizer",
                ],
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
            hasUsableItem(
                at: storageURL.appendingPathComponent(relativePath, isDirectory: false),
                fileManager: fileManager,
            )
        }
    }

    func hasUsableRuntimeExecutable(storageURL: URL, fileManager: FileManager = .default) -> Bool {
        let executableURL = runtimeExecutableURL(storageURL: storageURL)
        return fileManager.isExecutableFile(atPath: executableURL.path)
            && hasUsableItem(at: executableURL, fileManager: fileManager)
    }

    private func hasUsableItem(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard !isDirectory.boolValue else {
            return true
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes?[.size] as? NSNumber
        guard (fileSize?.int64Value ?? 0) > 0 else {
            return false
        }

        guard url.lastPathComponent == "sherpa-onnx-offline" || url.pathExtension == "dylib" else {
            return true
        }

        return hasExecutableFileFormat(at: url)
    }

    private func hasExecutableFileFormat(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        let prefix = try? handle.read(upToCount: 4)
        guard let bytes = prefix, !bytes.isEmpty else {
            return false
        }

        if bytes.starts(with: [0x23, 0x21]) {
            return true
        }

        let machOMagics: Set<[UInt8]> = [
            [0xCA, 0xFE, 0xBA, 0xBE],
            [0xBE, 0xBA, 0xFE, 0xCA],
            [0xFE, 0xED, 0xFA, 0xCE],
            [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF],
            [0xCF, 0xFA, 0xED, 0xFE],
        ]
        return machOMagics.contains(Array(bytes.prefix(4)))
    }
}

protocol SherpaOnnxModelInstalling {
    func prepareModel(
        _ model: LocalSTTModel,
        at storageURL: URL,
        downloadSource: ModelDownloadSource,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?,
    ) async throws -> String
}

protocol SherpaOnnxArchiveDownloading {
    func downloadArchive(from url: URL) async throws -> URL
}

final class URLSessionSherpaOnnxArchiveDownloader: SherpaOnnxArchiveDownloading {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func downloadArchive(from url: URL) async throws -> URL {
        let (downloadedURL, _) = try await urlSession.download(from: url)
        return downloadedURL
    }
}

final class SherpaOnnxModelInstaller: SherpaOnnxModelInstalling {
    private let fileManager: FileManager
    private let processRunner: ProcessCommandRunning
    private let archiveDownloader: SherpaOnnxArchiveDownloading

    init(
        fileManager: FileManager = .default,
        processRunner: ProcessCommandRunning = ProcessCommandRunner(),
        archiveDownloader: SherpaOnnxArchiveDownloading = URLSessionSherpaOnnxArchiveDownloader(),
    ) {
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.archiveDownloader = archiveDownloader
    }

    func prepareModel(
        _ model: LocalSTTModel,
        at storageURL: URL,
        downloadSource: ModelDownloadSource = .huggingFace,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)? = nil,
    ) async throws -> String {
        guard let layout = SherpaOnnxModelLayout.layout(for: model, downloadSource: downloadSource) else {
            throw NSError(
                domain: "SherpaOnnxModelInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.runtimeUnavailable", model.displayName)],
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
            source: nil,
        ))
        try await downloadAndExtract(
            archiveURL: layout.runtimeArchiveURL,
            destinationURL: storageURL,
            extractedRootDirectoryName: layout.runtimeRootDirectory,
            archiveFileName: "\(layout.runtimeRootDirectory).tar.bz2",
        )

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.modelDownloading", model.displayName),
            progress: 0.55,
            storagePath: storageURL.path,
            source: nil,
        ))
        try await prepareModelArtifact(
            layout.modelArtifact,
            destinationURL: storageURL,
            extractedRootDirectoryName: layout.modelRootDirectory,
        )

        guard layout.isInstalled(storageURL: storageURL, fileManager: fileManager) else {
            throw NSError(
                domain: "SherpaOnnxModelInstaller",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.modelAssetsMissing", model.displayName)],
            )
        }

        onUpdate?(LocalSTTPreparationUpdate(
            message: L("localSTT.prepare.modelReady", model.displayName),
            progress: 0.95,
            storagePath: storageURL.path,
            source: nil,
        ))

        return storageURL.path
    }

    private func downloadAndExtract(
        archiveURL: URL,
        destinationURL: URL,
        extractedRootDirectoryName: String,
        archiveFileName: String,
    ) async throws {
        try await RequestRetry.perform(operationName: "Sherpa-ONNX archive download") { [self] in
            let extractedRootURL = destinationURL.appendingPathComponent(
                extractedRootDirectoryName,
                isDirectory: true,
            )
            if fileManager.fileExists(atPath: extractedRootURL.path) {
                try fileManager.removeItem(at: extractedRootURL)
            }

            let temporaryDirectory = destinationURL.appendingPathComponent(".download", isDirectory: true)
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let localArchiveURL = temporaryDirectory.appendingPathComponent(
                archiveFileName,
                isDirectory: false,
            )
            if fileManager.fileExists(atPath: localArchiveURL.path) {
                try fileManager.removeItem(at: localArchiveURL)
            }

            try await downloadArchive(from: archiveURL, to: localArchiveURL)

            _ = try await processRunner.run(
                executablePath: "/usr/bin/tar",
                arguments: [
                    "-xjf",
                    localArchiveURL.path,
                    "-C",
                    destinationURL.path,
                ],
                environment: nil,
                currentDirectoryURL: destinationURL,
            )

            try? fileManager.removeItem(at: localArchiveURL)
            try? fileManager.removeItem(at: temporaryDirectory)
        }
    }

    private func prepareModelArtifact(
        _ artifact: SherpaOnnxModelArtifact,
        destinationURL: URL,
        extractedRootDirectoryName: String,
    ) async throws {
        switch artifact {
        case let .archive(url, fileName):
            try await downloadAndExtract(
                archiveURL: url,
                destinationURL: destinationURL,
                extractedRootDirectoryName: extractedRootDirectoryName,
                archiveFileName: fileName,
            )
        case let .files(files):
            try await downloadExtractedFiles(
                files,
                destinationURL: destinationURL,
                extractedRootDirectoryName: extractedRootDirectoryName,
            )
        }
    }

    private func downloadExtractedFiles(
        _ files: [SherpaOnnxModelFile],
        destinationURL: URL,
        extractedRootDirectoryName: String,
    ) async throws {
        try await RequestRetry.perform(operationName: "Sherpa-ONNX model file download") { [self] in
            let extractedRootURL = destinationURL.appendingPathComponent(
                extractedRootDirectoryName,
                isDirectory: true,
            )
            if fileManager.fileExists(atPath: extractedRootURL.path) {
                try fileManager.removeItem(at: extractedRootURL)
            }

            try fileManager.createDirectory(at: extractedRootURL, withIntermediateDirectories: true)

            for file in files {
                let destinationFileURL = destinationURL.appendingPathComponent(file.relativePath, isDirectory: false)
                try fileManager.createDirectory(
                    at: destinationFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try await downloadArchive(from: file.url, to: destinationFileURL)
            }
        }
    }

    private func downloadArchive(from archiveURL: URL, to localArchiveURL: URL) async throws {
        let downloadedURL = try await archiveDownloader.downloadArchive(from: archiveURL)
        if fileManager.fileExists(atPath: localArchiveURL.path) {
            try fileManager.removeItem(at: localArchiveURL)
        }
        try fileManager.moveItem(at: downloadedURL, to: localArchiveURL)
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
        processRunner: ProcessCommandRunning = ProcessCommandRunner(),
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
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.runtimeUnavailable", model.displayName)],
            )
        }

        let storageURL = URL(fileURLWithPath: modelFolder, isDirectory: true)
        let executableURL = layout.runtimeExecutableURL(storageURL: storageURL)
        guard layout.hasUsableRuntimeExecutable(storageURL: storageURL) else {
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.sherpaRuntimeMissing", executableURL.path)],
            )
        }

        guard layout.isInstalled(storageURL: storageURL) else {
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.modelAssetsMissing", model.displayName)],
            )
        }

        let wavURL = try AudioFileTranscoder.wavFileURL(for: audioFile)
        let arguments = try commandLineArguments(layout: layout, storageURL: storageURL, audioURL: wavURL)
        let result = try await processRunner.run(
            executablePath: executableURL.path,
            arguments: arguments,
            environment: [
                "DYLD_LIBRARY_PATH": layout.runtimeLibraryURL(storageURL: storageURL).path,
            ],
            currentDirectoryURL: storageURL,
        )

        return try parseTranscript(stdout: result.stdout)
    }

    func commandLineArguments(
        layout: SherpaOnnxModelLayout,
        storageURL: URL,
        audioURL: URL,
    ) throws -> [String] {
        let modelDirectory = layout.modelDirectoryURL(storageURL: storageURL)
        switch model {
        case .whisperLocal, .whisperLocalLarge:
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: L("localSTT.error.runtimeUnavailable", model.displayName)],
            )
        case .senseVoiceSmall:
            return [
                "--print-args=false",
                "--tokens=\(modelDirectory.appendingPathComponent("tokens.txt").path)",
                "--sense-voice-model=\(modelDirectory.appendingPathComponent("model.int8.onnx").path)",
                "--sense-voice-language=\(AppLocalization.shared.language.whisperKitLanguageCode)",
                "--sense-voice-use-itn=true",
                "--provider=cpu",
                audioURL.path,
            ]
        case .qwen3ASR:
            _ = modelIdentifier
            return [
                "--print-args=false",
                "--qwen3-asr-conv-frontend=\(modelDirectory.appendingPathComponent("conv_frontend.onnx").path)",
                "--qwen3-asr-encoder=\(modelDirectory.appendingPathComponent("encoder.int8.onnx").path)",
                "--qwen3-asr-decoder=\(modelDirectory.appendingPathComponent("decoder.int8.onnx").path)",
                "--qwen3-asr-tokenizer=\(modelDirectory.appendingPathComponent("tokenizer").path)",
                "--qwen3-asr-max-total-len=1500",
                "--qwen3-asr-max-new-tokens=512",
                "--qwen3-asr-temperature=0",
                "--provider=cpu",
                audioURL.path,
            ]
        }
    }

    func parseTranscript(stdout: String) throws -> String {
        let candidates = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let transcript = candidates.last else {
            throw NSError(
                domain: "SherpaOnnxCommandLineDecoder",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: L("workflow.transcription.noSpeech")],
            )
        }

        if let jsonTranscript = parseJSONTranscript(stdoutLine: transcript) {
            return jsonTranscript
        }

        return transcript
    }

    func parseJSONTranscript(stdoutLine: String) -> String? {
        guard stdoutLine.first == "{",
              let jsonData = stdoutLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let text = payload["text"] as? String
        else {
            return nil
        }

        return text
    }
}
