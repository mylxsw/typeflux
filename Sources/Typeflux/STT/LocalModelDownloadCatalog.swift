import Foundation

enum LocalModelDownloadCatalog {
    /// Centralized download metadata for bundled STT models.
    ///
    /// The public API intentionally stays small because callers only need a handful of
    /// answers: where WhisperKit lives, where the Sherpa runtime archive lives, and how
    /// a specific Sherpa model should be downloaded for a given source.
    ///
    /// The data is intentionally written in a "catalog" style: most URLs are listed here
    /// as complete values instead of being assembled from smaller parts. This makes the
    /// supported download locations easier to audit and update.

    private struct WhisperKitSourceDescriptor {
        let repositoryID: String
        let endpointKey: LocalModelDownloadURLCatalog.Key
        let repositoryURLKey: LocalModelDownloadURLCatalog.Key
    }

    private enum WhisperKitCatalog {
        static let defaultModelIdentifier = "whisperkit-medium"
        static let repositoryID = "argmaxinc/whisperkit-coreml"
        static let tokenizerRepositoryIDsByModelName: [String: String] = [
            "tiny": "openai/whisper-tiny",
            "tiny.en": "openai/whisper-tiny.en",
            "base": "openai/whisper-base",
            "base.en": "openai/whisper-base.en",
            "small": "openai/whisper-small",
            "small.en": "openai/whisper-small.en",
            "medium": "openai/whisper-medium",
            "medium.en": "openai/whisper-medium.en",
            "large": "openai/whisper-large",
            "large-v2": "openai/whisper-large-v2",
            "large-v3": "openai/whisper-large-v3",
        ]

        static let sources: [ModelDownloadSource: WhisperKitSourceDescriptor] = [
            .huggingFace: WhisperKitSourceDescriptor(
                repositoryID: repositoryID,
                endpointKey: .whisperKitHuggingFaceEndpoint,
                repositoryURLKey: .whisperKitHuggingFaceRepository
            ),
            .modelScope: WhisperKitSourceDescriptor(
                repositoryID: repositoryID,
                endpointKey: .whisperKitChinaMirrorEndpoint,
                repositoryURLKey: .whisperKitChinaMirrorRepository
            ),
        ]
    }

    private enum SherpaOnnxRuntimeCatalog {
        static let rootDirectory = "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts"
        static let onnxRuntimeVersionedLibraryName = "libonnxruntime.1.23.2.dylib"
        static let archiveURLKeys: [ModelDownloadSource: LocalModelDownloadURLCatalog.Key] = [
            .huggingFace: .sherpaOnnxRuntimeHuggingFaceArchive,
            .modelScope: .sherpaOnnxRuntimeChinaMirrorArchive,
        ]
    }

    private struct SherpaOnnxFileDescriptor {
        let urlKey: LocalModelDownloadURLCatalog.Key
        let destinationPath: String

        func makeFile() -> SherpaOnnxModelFile {
            SherpaOnnxModelFile(
                url: LocalModelDownloadURLCatalog.url(for: urlKey),
                relativePath: destinationPath,
            )
        }
    }

    private enum SherpaOnnxDelivery {
        /// Use the upstream pre-packaged model archive as-is.
        case archive(urlKey: LocalModelDownloadURLCatalog.Key, fileName: String)
        /// Rebuild the expected folder layout from individual files when a full archive is
        /// not available or not practical from the selected domestic source.
        case files([SherpaOnnxFileDescriptor])

        func makeArtifact() -> SherpaOnnxModelArtifact {
            switch self {
            case let .archive(urlKey, fileName):
                return .archive(
                    url: LocalModelDownloadURLCatalog.url(for: urlKey),
                    fileName: fileName,
                )
            case let .files(files):
                return .files(files.map { $0.makeFile() })
            }
        }
    }

    private struct SherpaOnnxModelDescriptor {
        let rootDirectory: String
        let deliveryBySource: [ModelDownloadSource: SherpaOnnxDelivery]

        func artifact(for source: ModelDownloadSource) -> SherpaOnnxModelArtifact? {
            deliveryBySource[source]?.makeArtifact()
        }
    }

    static var whisperKitDefaultModelIdentifier: String {
        WhisperKitCatalog.defaultModelIdentifier
    }

    static func whisperKitModelRepository(source: ModelDownloadSource) -> String {
        WhisperKitCatalog.sources[source]?.repositoryID ?? WhisperKitCatalog.repositoryID
    }

    static func whisperKitModelRepositoryURL(source: ModelDownloadSource) -> URL {
        LocalModelDownloadURLCatalog.url(for: WhisperKitCatalog.sources[source]!.repositoryURLKey)
    }

    static func whisperKitModelEndpoint(source: ModelDownloadSource) -> String {
        LocalModelDownloadURLCatalog.url(for: WhisperKitCatalog.sources[source]!.endpointKey).absoluteString
    }

    static func downloadSources(for model: LocalSTTModel) -> [ModelDownloadSource] {
        switch model {
        case .whisperLocal, .whisperLocalLarge, .senseVoiceSmall, .qwen3ASR, .funASR:
            [.huggingFace, .modelScope]
        }
    }

    static func probeURLs(for model: LocalSTTModel, source: ModelDownloadSource) -> [URL] {
        switch model {
        case .whisperLocal, .whisperLocalLarge:
            [whisperKitModelRepositoryURL(source: source)]
        case .senseVoiceSmall:
            [
                LocalModelDownloadURLCatalog.url(for: source == .huggingFace
                    ? .senseVoiceHuggingFaceModel
                    : .senseVoiceChinaMirrorModel),
                LocalModelDownloadURLCatalog.url(for: source == .huggingFace
                    ? .senseVoiceHuggingFaceTokens
                    : .senseVoiceChinaMirrorTokens),
            ]
        case .qwen3ASR:
            switch source {
            case .huggingFace:
                [LocalModelDownloadURLCatalog.url(for: .qwen3ASRHuggingFaceArchive)]
            case .modelScope:
                [LocalModelDownloadURLCatalog.url(for: .qwen3ASRModelScopeEncoder)]
            }
        case .funASR:
            [
                LocalModelDownloadURLCatalog.url(for: source == .huggingFace
                    ? .funASRHuggingFaceModel
                    : .funASRChinaMirrorModel),
                LocalModelDownloadURLCatalog.url(for: source == .huggingFace
                    ? .funASRHuggingFaceTokens
                    : .funASRChinaMirrorTokens),
            ]
        }
    }

    static func whisperTokenizerRepositoryID(for modelName: String) -> String? {
        WhisperKitCatalog.tokenizerRepositoryIDsByModelName[modelName]
    }

    static func whisperTokenizerFileURL(
        for modelName: String,
        fileName: String,
        source: ModelDownloadSource,
    ) -> URL? {
        guard let repositoryID = whisperTokenizerRepositoryID(for: modelName) else {
            return nil
        }

        var url = URL(string: whisperKitModelEndpoint(source: source))!
        for component in repositoryID.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        url.appendPathComponent("resolve", isDirectory: false)
        url.appendPathComponent("main", isDirectory: false)
        url.appendPathComponent(fileName, isDirectory: false)
        return url
    }

    static func sherpaOnnxRuntimeArchiveURL(source: ModelDownloadSource) -> URL {
        LocalModelDownloadURLCatalog.url(for: SherpaOnnxRuntimeCatalog.archiveURLKeys[source]!)
    }

    static var sherpaOnnxRuntimeDirectoryName: String {
        SherpaOnnxRuntimeCatalog.rootDirectory
    }

    static var sherpaOnnxRuntimeVersionedLibraryName: String {
        SherpaOnnxRuntimeCatalog.onnxRuntimeVersionedLibraryName
    }

    static func sherpaOnnxModelArchiveURL(for model: LocalSTTModel, source: ModelDownloadSource) -> URL? {
        sherpaOnnxModelArtifact(for: model, source: source)?.archiveURL
    }

    static func sherpaOnnxModelArtifact(
        for model: LocalSTTModel,
        source: ModelDownloadSource,
    ) -> SherpaOnnxModelArtifact? {
        sherpaOnnxModelDescriptor(for: model)?.artifact(for: source)
    }

    static func sherpaOnnxModelDirectoryName(for model: LocalSTTModel) -> String? {
        sherpaOnnxModelDescriptor(for: model)?.rootDirectory
    }

    private static func sherpaOnnxModelDescriptor(for model: LocalSTTModel) -> SherpaOnnxModelDescriptor? {
        switch model {
        case .whisperLocal, .whisperLocalLarge:
            return nil
        case .senseVoiceSmall:
            return senseVoiceDescriptor
        case .qwen3ASR:
            return qwen3ASRDescriptor
        case .funASR:
            return funASRDescriptor
        }
    }

    private static let senseVoiceDescriptor = SherpaOnnxModelDescriptor(
        rootDirectory: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
        deliveryBySource: [
            .huggingFace: .files([
                SherpaOnnxFileDescriptor(
                    urlKey: .senseVoiceHuggingFaceModel,
                    destinationPath: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .senseVoiceHuggingFaceTokens,
                    destinationPath: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt",
                ),
            ]),
            .modelScope: .files([
                SherpaOnnxFileDescriptor(
                    urlKey: .senseVoiceChinaMirrorModel,
                    destinationPath: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .senseVoiceChinaMirrorTokens,
                    destinationPath: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt",
                ),
            ]),
        ],
    )

    private static let qwen3ASRDescriptor = SherpaOnnxModelDescriptor(
        rootDirectory: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
        deliveryBySource: [
            .huggingFace: .archive(
                urlKey: .qwen3ASRHuggingFaceArchive,
                fileName: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2"
            ),
            .modelScope: .files([
                SherpaOnnxFileDescriptor(
                    urlKey: .qwen3ASRModelScopeConvFrontend,
                    destinationPath: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/conv_frontend.onnx",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .qwen3ASRModelScopeEncoder,
                    destinationPath: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/encoder.int8.onnx",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .qwen3ASRModelScopeDecoder,
                    destinationPath: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/decoder.int8.onnx",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .qwen3ASRModelScopeTokenizerMerges,
                    destinationPath: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/tokenizer/merges.txt",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .qwen3ASRModelScopeTokenizerConfig,
                    destinationPath: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/tokenizer/tokenizer_config.json",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .qwen3ASRModelScopeTokenizerVocab,
                    destinationPath: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/tokenizer/vocab.json",
                ),
            ]),
        ],
    )

    private static let funASRDescriptor = SherpaOnnxModelDescriptor(
        rootDirectory: "sherpa-onnx-paraformer-zh-small-2024-03-09",
        deliveryBySource: [
            .huggingFace: .files([
                SherpaOnnxFileDescriptor(
                    urlKey: .funASRHuggingFaceModel,
                    destinationPath: "sherpa-onnx-paraformer-zh-small-2024-03-09/model.int8.onnx",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .funASRHuggingFaceTokens,
                    destinationPath: "sherpa-onnx-paraformer-zh-small-2024-03-09/tokens.txt",
                ),
            ]),
            .modelScope: .files([
                SherpaOnnxFileDescriptor(
                    urlKey: .funASRChinaMirrorModel,
                    destinationPath: "sherpa-onnx-paraformer-zh-small-2024-03-09/model.int8.onnx",
                ),
                SherpaOnnxFileDescriptor(
                    urlKey: .funASRChinaMirrorTokens,
                    destinationPath: "sherpa-onnx-paraformer-zh-small-2024-03-09/tokens.txt",
                ),
            ]),
        ],
    )
}
