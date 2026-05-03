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
    let model: LocalSTTModel
    let runtimeArchiveURL: URL
    let runtimeRootDirectory: String
    let modelArtifact: SherpaOnnxModelArtifact
    let modelRootDirectory: String
    let modelRequiredRelativePaths: [String]
    let requiredRelativePaths: [String]

    static var runtimeRequiredRelativePaths: [String] {
        [
            "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/bin/sherpa-onnx-offline",
            "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/lib/libsherpa-onnx-c-api.dylib",
            "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/lib/libonnxruntime.dylib",
            "\(LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName)/lib/\(LocalModelDownloadCatalog.sherpaOnnxRuntimeVersionedLibraryName)",
        ]
    }

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
                model: model,
                runtimeArchiveURL: LocalModelDownloadCatalog.sherpaOnnxRuntimeArchiveURL(source: downloadSource),
                runtimeRootDirectory: LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName,
                modelArtifact: modelArtifact,
                modelRootDirectory: modelRootDirectory,
                modelRequiredRelativePaths: [
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
                model: model,
                runtimeArchiveURL: LocalModelDownloadCatalog.sherpaOnnxRuntimeArchiveURL(source: downloadSource),
                runtimeRootDirectory: LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName,
                modelArtifact: modelArtifact,
                modelRootDirectory: modelRootDirectory,
                modelRequiredRelativePaths: [
                    "\(modelRootDirectory)/conv_frontend.onnx",
                    "\(modelRootDirectory)/encoder.int8.onnx",
                    "\(modelRootDirectory)/decoder.int8.onnx",
                    "\(modelRootDirectory)/tokenizer",
                ],
            )
        case .funASR:
            guard let modelRootDirectory = LocalModelDownloadCatalog.sherpaOnnxModelDirectoryName(for: model),
                  let modelArtifact = LocalModelDownloadCatalog.sherpaOnnxModelArtifact(
                    for: model,
                    source: downloadSource,
                  )
            else {
                return nil
            }
            return SherpaOnnxModelLayout(
                model: model,
                runtimeArchiveURL: LocalModelDownloadCatalog.sherpaOnnxRuntimeArchiveURL(source: downloadSource),
                runtimeRootDirectory: LocalModelDownloadCatalog.sherpaOnnxRuntimeDirectoryName,
                modelArtifact: modelArtifact,
                modelRootDirectory: modelRootDirectory,
                modelRequiredRelativePaths: [
                    "\(modelRootDirectory)/model.int8.onnx",
                    "\(modelRootDirectory)/tokens.txt",
                ],
            )
        }
    }

    init(
        model: LocalSTTModel,
        runtimeArchiveURL: URL,
        runtimeRootDirectory: String,
        modelArtifact: SherpaOnnxModelArtifact,
        modelRootDirectory: String,
        modelRequiredRelativePaths: [String],
    ) {
        self.model = model
        self.runtimeArchiveURL = runtimeArchiveURL
        self.runtimeRootDirectory = runtimeRootDirectory
        self.modelArtifact = modelArtifact
        self.modelRootDirectory = modelRootDirectory
        self.modelRequiredRelativePaths = modelRequiredRelativePaths
        requiredRelativePaths = Self.runtimeRequiredRelativePaths + modelRequiredRelativePaths
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

    func isInstalled(
        storageURL: URL,
        fileManager: FileManager = .default,
        runtimeCompatibilitySystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    ) -> Bool {
        missingOrUnusableRelativePaths(
            storageURL: storageURL,
            fileManager: fileManager,
            runtimeCompatibilitySystemVersion: runtimeCompatibilitySystemVersion,
        ).isEmpty
    }

    func isRuntimeInstalled(
        storageURL: URL,
        fileManager: FileManager = .default,
        runtimeCompatibilitySystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    ) -> Bool {
        missingOrUnusableRuntimeRelativePaths(
            storageURL: storageURL,
            fileManager: fileManager,
            runtimeCompatibilitySystemVersion: runtimeCompatibilitySystemVersion,
        ).isEmpty
    }

    func isModelInstalled(storageURL: URL, fileManager: FileManager = .default) -> Bool {
        missingOrUnusableModelRelativePaths(storageURL: storageURL, fileManager: fileManager).isEmpty
    }

    func missingOrUnusableRelativePaths(
        storageURL: URL,
        fileManager: FileManager = .default,
        runtimeCompatibilitySystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    ) -> [String] {
        requiredRelativePaths.filter { relativePath in
            !hasUsableItem(
                at: storageURL.appendingPathComponent(relativePath, isDirectory: false),
                relativePath: relativePath,
                fileManager: fileManager,
                runtimeCompatibilitySystemVersion: runtimeCompatibilitySystemVersion,
            )
        }
    }

    func missingOrUnusableRuntimeRelativePaths(
        storageURL: URL,
        fileManager: FileManager = .default,
        runtimeCompatibilitySystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    ) -> [String] {
        Self.runtimeRequiredRelativePaths.filter { relativePath in
            !hasUsableItem(
                at: storageURL.appendingPathComponent(relativePath, isDirectory: false),
                relativePath: relativePath,
                fileManager: fileManager,
                runtimeCompatibilitySystemVersion: runtimeCompatibilitySystemVersion,
            )
        }
    }

    func missingOrUnusableModelRelativePaths(
        storageURL: URL,
        fileManager: FileManager = .default,
    ) -> [String] {
        modelRequiredRelativePaths.filter { relativePath in
            !hasUsableItem(
                at: storageURL.appendingPathComponent(relativePath, isDirectory: false),
                relativePath: relativePath,
                fileManager: fileManager,
            )
        }
    }

    func hasUsableRuntimeExecutable(storageURL: URL, fileManager: FileManager = .default) -> Bool {
        let executableURL = runtimeExecutableURL(storageURL: storageURL)
        let relativePath = "\(runtimeRootDirectory)/bin/sherpa-onnx-offline"
        return fileManager.isExecutableFile(atPath: executableURL.path)
            && hasUsableItem(
                at: executableURL,
                relativePath: relativePath,
                fileManager: fileManager,
                runtimeCompatibilitySystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            )
    }

    private func hasUsableItem(
        at url: URL,
        relativePath: String,
        fileManager: FileManager,
        runtimeCompatibilitySystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    ) -> Bool {
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
            return hasValidModelAsset(at: url, relativePath: relativePath, fileManager: fileManager)
        }

        return hasExecutableFileFormat(at: url)
            && SherpaOnnxRuntimeCompatibility.isCompatible(
                at: url,
                with: runtimeCompatibilitySystemVersion,
            )
    }

    private func hasValidModelAsset(at url: URL, relativePath: String, fileManager: FileManager) -> Bool {
        switch relativePath {
        case let path where path.hasSuffix("/tokens.txt"):
            return hasValidTokensFile(at: url)
        case let path where path.hasSuffix("/model.int8.onnx"):
            return hasValidOnnxModelFile(at: url, fileManager: fileManager)
        default:
            return true
        }
    }

    private func hasValidTokensFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return false
        }

        let prefix = textPrefix(from: data)
        guard !isMirrorErrorResponse(prefix) else {
            return false
        }

        switch model {
        case .senseVoiceSmall:
            return prefix.contains("<unk> 0")
        case .funASR:
            return prefix.contains("<blank> 0")
        case .qwen3ASR, .whisperLocal, .whisperLocalLarge:
            return true
        }
    }

    private func hasValidOnnxModelFile(at url: URL, fileManager: FileManager) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize >= 1_000_000 else {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return false
            }

            let prefix = textPrefix(from: data)
            return !isMirrorErrorResponse(prefix)
        }

        return true
    }

    private func textPrefix(from data: Data, maxBytes: Int = 512) -> String {
        String(decoding: data.prefix(maxBytes), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isMirrorErrorResponse(_ text: String) -> Bool {
        text.contains("Invalid rev id:")
            || text.contains("Repository Not Found")
            || text.contains("Access to model")
            || text.hasPrefix("<!DOCTYPE html")
            || text.hasPrefix("<html")
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

private enum SherpaOnnxRuntimeCompatibility {
    static func isCompatible(at url: URL, with systemVersion: OperatingSystemVersion) -> Bool {
        guard let minimumVersion = MachOMinimumOSVersionReader.minimumOperatingSystemVersion(at: url) else {
            return true
        }

        return !isVersion(minimumVersion, greaterThan: systemVersion)
    }

    private static func isVersion(
        _ lhs: OperatingSystemVersion,
        greaterThan rhs: OperatingSystemVersion,
    ) -> Bool {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion > rhs.majorVersion
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion > rhs.minorVersion
        }
        return lhs.patchVersion > rhs.patchVersion
    }
}

private enum MachOByteOrder {
    case littleEndian
    case bigEndian
}

private enum MachOMinimumOSVersionReader {
    static func minimumOperatingSystemVersion(at url: URL) -> OperatingSystemVersion? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return minimumOperatingSystemVersion(in: data)
    }

    private static func minimumOperatingSystemVersion(in data: Data) -> OperatingSystemVersion? {
        guard data.count >= 4 else {
            return nil
        }

        if let fatVersion = parseFatHeader(in: data) {
            return fatVersion
        }

        return parseThinHeader(in: data, at: 0)
    }

    private static func parseFatHeader(in data: Data) -> OperatingSystemVersion? {
        guard let magic = data.uint32(at: 0, byteOrder: .bigEndian),
              magic == 0xCAFE_BABE || magic == 0xCAFE_BABF,
              let sliceCount = data.uint32(at: 4, byteOrder: .bigEndian),
              sliceCount > 0,
              sliceCount <= 32
        else {
            return nil
        }

        let isFat64 = magic == 0xCAFE_BABF
        let entrySize = isFat64 ? 32 : 20
        var versions: [OperatingSystemVersion] = []

        for index in 0..<Int(sliceCount) {
            let entryOffset = 8 + index * entrySize
            let sliceOffset: UInt64?
            if isFat64 {
                sliceOffset = data.uint64(at: entryOffset + 8, byteOrder: .bigEndian)
            } else {
                sliceOffset = data.uint32(at: entryOffset + 8, byteOrder: .bigEndian).map(UInt64.init)
            }

            guard let sliceOffset,
                  sliceOffset <= UInt64(Int.max),
                  let version = parseThinHeader(in: data, at: Int(sliceOffset))
            else {
                continue
            }
            versions.append(version)
        }

        return versions.max(by: isVersion(_:lessThan:))
    }

    private static func parseThinHeader(in data: Data, at offset: Int) -> OperatingSystemVersion? {
        guard offset >= 0,
              offset + 4 <= data.count
        else {
            return nil
        }

        let magicBytes = Array(data[offset..<(offset + 4)])
        let header: (byteOrder: MachOByteOrder, is64Bit: Bool)?
        switch magicBytes {
        case [0xCF, 0xFA, 0xED, 0xFE]:
            header = (.littleEndian, true)
        case [0xCE, 0xFA, 0xED, 0xFE]:
            header = (.littleEndian, false)
        case [0xFE, 0xED, 0xFA, 0xCF]:
            header = (.bigEndian, true)
        case [0xFE, 0xED, 0xFA, 0xCE]:
            header = (.bigEndian, false)
        default:
            return nil
        }

        guard let header,
              let commandCount = data.uint32(at: offset + 16, byteOrder: header.byteOrder),
              commandCount <= 512
        else {
            return nil
        }

        var commandOffset = offset + (header.is64Bit ? 32 : 28)
        var versions: [OperatingSystemVersion] = []

        for _ in 0..<Int(commandCount) {
            guard commandOffset + 8 <= data.count,
                  let command = data.uint32(at: commandOffset, byteOrder: header.byteOrder),
                  let commandSize = data.uint32(at: commandOffset + 4, byteOrder: header.byteOrder),
                  commandSize >= 8,
                  commandOffset + Int(commandSize) <= data.count
            else {
                return nil
            }

            switch command {
            case 0x32:
                if let encodedVersion = data.uint32(at: commandOffset + 12, byteOrder: header.byteOrder) {
                    versions.append(decodeMachOVersion(encodedVersion))
                }
            case 0x24:
                if let encodedVersion = data.uint32(at: commandOffset + 8, byteOrder: header.byteOrder) {
                    versions.append(decodeMachOVersion(encodedVersion))
                }
            default:
                break
            }

            commandOffset += Int(commandSize)
        }

        return versions.max(by: isVersion(_:lessThan:))
    }

    private static func decodeMachOVersion(_ rawVersion: UInt32) -> OperatingSystemVersion {
        OperatingSystemVersion(
            majorVersion: Int((rawVersion >> 16) & 0xFFFF),
            minorVersion: Int((rawVersion >> 8) & 0xFF),
            patchVersion: Int(rawVersion & 0xFF),
        )
    }

    private static func isVersion(
        _ lhs: OperatingSystemVersion,
        lessThan rhs: OperatingSystemVersion,
    ) -> Bool {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion < rhs.majorVersion
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion < rhs.minorVersion
        }
        return lhs.patchVersion < rhs.patchVersion
    }
}

private extension Data {
    func uint32(at offset: Int, byteOrder: MachOByteOrder) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }

        let bytes = Array(self[offset..<(offset + 4)])
        switch byteOrder {
        case .littleEndian:
            return UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
        case .bigEndian:
            return UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
        }
    }

    func uint64(at offset: Int, byteOrder: MachOByteOrder) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else {
            return nil
        }

        let bytes = Array(self[offset..<(offset + 8)])
        switch byteOrder {
        case .littleEndian:
            return UInt64(bytes[0])
                | UInt64(bytes[1]) << 8
                | UInt64(bytes[2]) << 16
                | UInt64(bytes[3]) << 24
                | UInt64(bytes[4]) << 32
                | UInt64(bytes[5]) << 40
                | UInt64(bytes[6]) << 48
                | UInt64(bytes[7]) << 56
        case .bigEndian:
            return UInt64(bytes[0]) << 56
                | UInt64(bytes[1]) << 48
                | UInt64(bytes[2]) << 40
                | UInt64(bytes[3]) << 32
                | UInt64(bytes[4]) << 24
                | UInt64(bytes[5]) << 16
                | UInt64(bytes[6]) << 8
                | UInt64(bytes[7])
        }
    }
}

protocol SherpaOnnxRuntimeLocating {
    func runtimeRootURL(for layout: SherpaOnnxModelLayout, fileManager: FileManager) -> URL?
}

struct BundledSherpaOnnxRuntimeLocator: SherpaOnnxRuntimeLocating {
    let explicitRuntimeRootURL: URL?

    init(explicitRuntimeRootURL: URL? = nil) {
        self.explicitRuntimeRootURL = explicitRuntimeRootURL
    }

    func runtimeRootURL(for layout: SherpaOnnxModelLayout, fileManager: FileManager = .default) -> URL? {
        for candidateURL in candidateRuntimeRootURLs(for: layout) {
            let storageURL = candidateURL.deletingLastPathComponent()
            if candidateURL.lastPathComponent == layout.runtimeRootDirectory,
               layout.isRuntimeInstalled(storageURL: storageURL, fileManager: fileManager)
            {
                return candidateURL
            }
        }
        return nil
    }

    private func candidateRuntimeRootURLs(for layout: SherpaOnnxModelLayout) -> [URL] {
        if let explicitRuntimeRootURL {
            return [explicitRuntimeRootURL]
        }

        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(
                resourceURL
                    .appendingPathComponent("LocalRuntimes", isDirectory: true)
                    .appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
            )
        }
        if let resourceURL = Bundle.appResources.resourceURL {
            urls.append(
                resourceURL
                    .appendingPathComponent("LocalRuntimes", isDirectory: true)
                    .appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
            )
        }
        urls.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .appendingPathComponent("LocalRuntimes", isDirectory: true)
                .appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        )

        var seenPaths = Set<String>()
        return urls.filter { seenPaths.insert($0.path).inserted }
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
        let (downloadedURL, response) = try await urlSession.download(from: url)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw NSError(
                domain: "URLSessionSherpaOnnxArchiveDownloader",
                code: (response as? HTTPURLResponse)?.statusCode ?? 1,
                userInfo: [NSLocalizedDescriptionKey: "Sherpa-ONNX archive download failed."],
            )
        }
        return downloadedURL
    }
}

final class SherpaOnnxModelInstaller: SherpaOnnxModelInstalling {
    private let fileManager: FileManager
    private let processRunner: ProcessCommandRunning
    private let archiveDownloader: SherpaOnnxArchiveDownloading
    private let runtimeLocator: SherpaOnnxRuntimeLocating
    private let sharedRuntimeStorageURL: URL?

    init(
        fileManager: FileManager = .default,
        processRunner: ProcessCommandRunning = ProcessCommandRunner(),
        archiveDownloader: SherpaOnnxArchiveDownloading = URLSessionSherpaOnnxArchiveDownloader(),
        runtimeLocator: SherpaOnnxRuntimeLocating = BundledSherpaOnnxRuntimeLocator(),
        sharedRuntimeStorageURL: URL? = nil,
    ) {
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.archiveDownloader = archiveDownloader
        self.runtimeLocator = runtimeLocator
        self.sharedRuntimeStorageURL = sharedRuntimeStorageURL
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

        let runtimeStorageURL = sharedRuntimeStorageURL ?? storageURL
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeStorageURL, withIntermediateDirectories: true)
        try installBundledRuntimeIfAvailable(layout: layout, runtimeStorageURL: runtimeStorageURL)
        try installLegacyRuntimeIfAvailable(layout: layout, modelStorageURL: storageURL, runtimeStorageURL: runtimeStorageURL)
        if !layout.isRuntimeInstalled(storageURL: runtimeStorageURL, fileManager: fileManager) {
            try? pruneRuntimePayload(in: runtimeStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true))
        }
        if layout.isModelInstalled(storageURL: storageURL, fileManager: fileManager),
           layout.isRuntimeInstalled(storageURL: runtimeStorageURL, fileManager: fileManager)
        {
            try linkSharedRuntimeIfNeeded(layout: layout, modelStorageURL: storageURL, runtimeStorageURL: runtimeStorageURL)
            return storageURL.path
        }

        if !layout.isRuntimeInstalled(storageURL: runtimeStorageURL, fileManager: fileManager) {
            onUpdate?(LocalSTTPreparationUpdate(
                message: L("localSTT.prepare.runtimeDownloading"),
                progress: 0.15,
                storagePath: storageURL.path,
                source: nil,
            ))
            NetworkDebugLogger.logMessage(
                "[Local Model Download] model=\(model.displayName) source=\(downloadSource.displayName) kind=sherpa-runtime url=\(layout.runtimeArchiveURL.absoluteString)"
            )
            try await downloadAndExtract(
                archiveURL: layout.runtimeArchiveURL,
                destinationURL: runtimeStorageURL,
                extractedRootDirectoryName: layout.runtimeRootDirectory,
                archiveFileName: "\(layout.runtimeRootDirectory).tar.bz2",
            )
            try pruneRuntimePayload(in: runtimeStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true))
        }

        try linkSharedRuntimeIfNeeded(layout: layout, modelStorageURL: storageURL, runtimeStorageURL: runtimeStorageURL)

        if !layout.isModelInstalled(storageURL: storageURL, fileManager: fileManager) {
            onUpdate?(LocalSTTPreparationUpdate(
                message: L("localSTT.prepare.modelDownloading", model.displayName),
                progress: 0.55,
                storagePath: storageURL.path,
                source: nil,
            ))
            logModelArtifactDownload(modelArtifact: layout.modelArtifact, model: model, source: downloadSource)
            try await prepareModelArtifact(
                layout.modelArtifact,
                destinationURL: storageURL,
                extractedRootDirectoryName: layout.modelRootDirectory,
            )
        }

        let missingOrUnusablePaths = layout.missingOrUnusableRelativePaths(
            storageURL: storageURL,
            fileManager: fileManager,
        )
        guard missingOrUnusablePaths.isEmpty else {
            NetworkDebugLogger.logMessage(
                "[Local Model Download] model=\(model.displayName) source=\(downloadSource.displayName) validation=failed missingOrUnusablePaths=\(missingOrUnusablePaths.joined(separator: ","))"
            )
            throw NSError(
                domain: "SherpaOnnxModelInstaller",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: L("localSTT.error.modelAssetsMissing", model.displayName),
                    "MissingOrUnusablePaths": missingOrUnusablePaths,
                ],
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

    private func installBundledRuntimeIfAvailable(layout: SherpaOnnxModelLayout, runtimeStorageURL: URL) throws {
        guard let runtimeRootURL = runtimeLocator.runtimeRootURL(for: layout, fileManager: fileManager) else {
            return
        }

        let targetURL = runtimeStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        if layout.isRuntimeInstalled(storageURL: runtimeStorageURL, fileManager: fileManager),
           directoryContentsMatch(sourceURL: runtimeRootURL, targetURL: targetURL)
        {
            return
        }

        if fileManager.fileExists(atPath: targetURL.path) || (try? fileManager.destinationOfSymbolicLink(atPath: targetURL.path)) != nil {
            try fileManager.removeItem(at: targetURL)
        }

        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: runtimeRootURL, to: targetURL)
        NetworkDebugLogger.logMessage(
            "[Local Model Download] kind=sherpa-runtime source=bundled sourcePath=\(runtimeRootURL.path) storagePath=\(targetURL.path)"
        )
    }

    private func installLegacyRuntimeIfAvailable(
        layout: SherpaOnnxModelLayout,
        modelStorageURL: URL,
        runtimeStorageURL: URL,
    ) throws {
        guard runtimeStorageURL.standardizedFileURL.path != modelStorageURL.standardizedFileURL.path,
              !layout.isRuntimeInstalled(storageURL: runtimeStorageURL, fileManager: fileManager),
              layout.isRuntimeInstalled(storageURL: modelStorageURL, fileManager: fileManager)
        else {
            return
        }

        let legacyRuntimeURL = try resolvedURLFollowingSymlink(
            modelStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        )
        let targetRuntimeURL = runtimeStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        if fileManager.fileExists(atPath: targetRuntimeURL.path) || (try? fileManager.destinationOfSymbolicLink(atPath: targetRuntimeURL.path)) != nil {
            try fileManager.removeItem(at: targetRuntimeURL)
        }
        try fileManager.createDirectory(at: targetRuntimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacyRuntimeURL, to: targetRuntimeURL)
        NetworkDebugLogger.logMessage(
            "[Local Model Download] kind=sherpa-runtime source=legacy modelPath=\(legacyRuntimeURL.path) storagePath=\(targetRuntimeURL.path)"
        )
    }

    private func linkSharedRuntimeIfNeeded(
        layout: SherpaOnnxModelLayout,
        modelStorageURL: URL,
        runtimeStorageURL: URL,
    ) throws {
        guard runtimeStorageURL.standardizedFileURL.path != modelStorageURL.standardizedFileURL.path else {
            return
        }
        guard layout.isRuntimeInstalled(storageURL: runtimeStorageURL, fileManager: fileManager) else {
            return
        }

        let runtimeRootURL = runtimeStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        let linkURL = modelStorageURL.appendingPathComponent(layout.runtimeRootDirectory, isDirectory: true)
        if let existingDestination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) {
            if existingDestination == runtimeRootURL.path {
                return
            }
            try fileManager.removeItem(at: linkURL)
        } else if fileManager.fileExists(atPath: linkURL.path) {
            try fileManager.removeItem(at: linkURL)
        }
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    private func directoryContentsMatch(sourceURL: URL, targetURL: URL) -> Bool {
        DirectoryContentMatcher.contentsMatch(
            sourceURL: sourceURL,
            targetURL: targetURL,
            fileManager: fileManager,
        )
    }

    private func logModelArtifactDownload(
        modelArtifact: SherpaOnnxModelArtifact,
        model: LocalSTTModel,
        source: ModelDownloadSource,
    ) {
        switch modelArtifact {
        case let .archive(url, fileName):
            NetworkDebugLogger.logMessage(
                "[Local Model Download] model=\(model.displayName) source=\(source.displayName) kind=model-archive file=\(fileName) url=\(url.absoluteString)"
            )
        case let .files(files):
            for file in files {
                NetworkDebugLogger.logMessage(
                    "[Local Model Download] model=\(model.displayName) source=\(source.displayName) kind=model-file path=\(file.relativePath) url=\(file.url.absoluteString)"
                )
            }
        }
    }

    private func downloadAndExtract(
        archiveURL: URL,
        destinationURL: URL,
        extractedRootDirectoryName: String,
        archiveFileName: String,
    ) async throws {
        let extractedRootURL = destinationURL.appendingPathComponent(
            extractedRootDirectoryName,
            isDirectory: true,
        )
        if (try? fileManager.destinationOfSymbolicLink(atPath: extractedRootURL.path)) != nil {
            try fileManager.removeItem(at: extractedRootURL)
        } else if fileManager.fileExists(atPath: extractedRootURL.path) {
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

    private func pruneRuntimePayload(in runtimeRootURL: URL) throws {
        guard fileManager.fileExists(atPath: runtimeRootURL.path) else {
            return
        }

        let binDirectoryURL = runtimeRootURL.appendingPathComponent("bin", isDirectory: true)
        if fileManager.fileExists(atPath: binDirectoryURL.path) {
            for itemURL in try fileManager.contentsOfDirectory(
                at: binDirectoryURL,
                includingPropertiesForKeys: nil,
            ) where itemURL.lastPathComponent != "sherpa-onnx-offline" {
                try? fileManager.removeItem(at: itemURL)
            }
        }

        let includeDirectoryURL = runtimeRootURL.appendingPathComponent("include", isDirectory: true)
        if fileManager.fileExists(atPath: includeDirectoryURL.path) {
            try? fileManager.removeItem(at: includeDirectoryURL)
        }

        let libDirectoryURL = runtimeRootURL.appendingPathComponent("lib", isDirectory: true)
        guard fileManager.fileExists(atPath: libDirectoryURL.path) else {
            try removeEmptyRuntimeDirectories(in: runtimeRootURL)
            return
        }

        let versionedLibraryURL = libDirectoryURL.appendingPathComponent(
            LocalModelDownloadCatalog.sherpaOnnxRuntimeVersionedLibraryName,
            isDirectory: false,
        )
        let compatibilityLibraryURL = libDirectoryURL.appendingPathComponent("libonnxruntime.dylib", isDirectory: false)

        if !fileManager.fileExists(atPath: versionedLibraryURL.path),
           fileManager.fileExists(atPath: compatibilityLibraryURL.path)
        {
            try fileManager.copyItem(at: compatibilityLibraryURL, to: versionedLibraryURL)
        }

        if fileManager.fileExists(atPath: compatibilityLibraryURL.path) {
            try? fileManager.removeItem(at: compatibilityLibraryURL)
        }

        if fileManager.fileExists(atPath: versionedLibraryURL.path) {
            try fileManager.createSymbolicLink(
                atPath: compatibilityLibraryURL.path,
                withDestinationPath: LocalModelDownloadCatalog.sherpaOnnxRuntimeVersionedLibraryName,
            )
        }

        let keepLibraryNames: Set<String> = [
            "libsherpa-onnx-c-api.dylib",
            "libonnxruntime.dylib",
            LocalModelDownloadCatalog.sherpaOnnxRuntimeVersionedLibraryName,
        ]
        for itemURL in try fileManager.contentsOfDirectory(
            at: libDirectoryURL,
            includingPropertiesForKeys: nil,
        ) where !keepLibraryNames.contains(itemURL.lastPathComponent) {
            try? fileManager.removeItem(at: itemURL)
        }

        try removeEmptyRuntimeDirectories(in: runtimeRootURL)
    }

    private func removeEmptyRuntimeDirectories(in runtimeRootURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: runtimeRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
        ) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                directories.append(url)
            }
        }

        for directoryURL in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: directoryURL.path),
               contents.isEmpty
            {
                try? fileManager.removeItem(at: directoryURL)
            }
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

    private func downloadArchive(from archiveURL: URL, to localArchiveURL: URL) async throws {
        let downloadedURL = try await RequestRetry.perform(
            operationName: "Sherpa-ONNX file download \(archiveURL.absoluteString)",
        ) { [self] in
            try await archiveDownloader.downloadArchive(from: archiveURL)
        }
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
                "--sense-voice-language=auto",
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
        case .funASR:
            return [
                "--print-args=false",
                "--tokens=\(modelDirectory.appendingPathComponent("tokens.txt").path)",
                "--paraformer=\(modelDirectory.appendingPathComponent("model.int8.onnx").path)",
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
