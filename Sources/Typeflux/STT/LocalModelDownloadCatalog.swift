import Foundation

enum LocalModelDownloadCatalog {
    private static let huggingFaceEndpoint = "https://huggingface.co"
    private static let huggingFaceChinaMirrorEndpoint = "https://hf-mirror.com"
    private static let whisperKitRepositoryID = "argmaxinc/whisperkit-coreml"
    private static let whisperKitDefaultModelName = "whisperkit-medium"
    private static let sherpaOnnxRuntimeRootDirectory = "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts"
    private static let senseVoiceRootDirectory = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    private static let qwen3ASRRootDirectory = "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
    private static let senseVoiceMirrorRepositoryID =
        "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    private static let qwen3ASROnnxModelScopeRepositoryID = "zengshuishui/Qwen3-ASR-onnx"
    private static let qwen3ASRTokenizerModelScopeRepositoryID = "Qwen/Qwen3-ASR-0.6B"

    static var whisperKitDefaultModelIdentifier: String {
        whisperKitDefaultModelName
    }

    static func whisperKitModelRepository(source _: ModelDownloadSource) -> String {
        whisperKitRepositoryID
    }

    static func whisperKitModelRepositoryURL(source: ModelDownloadSource) -> URL {
        URL(string: "\(whisperKitModelEndpoint(source: source))/\(whisperKitRepositoryID)")!
    }

    static func whisperKitModelEndpoint(source: ModelDownloadSource) -> String {
        switch source {
        case .huggingFace:
            huggingFaceEndpoint
        case .modelScope:
            huggingFaceChinaMirrorEndpoint
        }
    }

    static func sherpaOnnxRuntimeArchiveURL(source: ModelDownloadSource) -> URL {
        let archiveName = "\(sherpaOnnxRuntimeRootDirectory).tar.bz2"
        switch source {
        case .huggingFace:
            return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.35/\(archiveName)")!
        case .modelScope:
            return URL(string: "https://sourceforge.net/projects/sherpa-onnx.mirror/files/v1.12.35/\(archiveName)/download")!
        }
    }

    static var sherpaOnnxRuntimeDirectoryName: String {
        sherpaOnnxRuntimeRootDirectory
    }

    static func sherpaOnnxModelArchiveURL(for model: LocalSTTModel, source: ModelDownloadSource) -> URL? {
        sherpaOnnxModelArtifact(for: model, source: source)?.archiveURL
    }

    static func sherpaOnnxModelArtifact(
        for model: LocalSTTModel,
        source: ModelDownloadSource,
    ) -> SherpaOnnxModelArtifact? {
        switch (model, source) {
        case (.whisperLocal, _), (.whisperLocalLarge, _):
            nil
        case (.senseVoiceSmall, .huggingFace):
            .archive(
                url: sherpaOnnxASRModelArchiveURL(archiveName: "\(senseVoiceRootDirectory).tar.bz2"),
                fileName: "\(senseVoiceRootDirectory).tar.bz2",
            )
        case (.qwen3ASR, .huggingFace):
            .archive(
                url: sherpaOnnxASRModelArchiveURL(archiveName: "\(qwen3ASRRootDirectory).tar.bz2"),
                fileName: "\(qwen3ASRRootDirectory).tar.bz2",
            )
        case (.senseVoiceSmall, .modelScope):
            .files([
                sherpaOnnxFile(
                    resolveBaseURL: huggingFaceChinaMirrorEndpoint,
                    repositoryID: senseVoiceMirrorRepositoryID,
                    sourcePath: "model.int8.onnx",
                    destinationPath: "\(senseVoiceRootDirectory)/model.int8.onnx",
                ),
                sherpaOnnxFile(
                    resolveBaseURL: huggingFaceChinaMirrorEndpoint,
                    repositoryID: senseVoiceMirrorRepositoryID,
                    sourcePath: "tokens.txt",
                    destinationPath: "\(senseVoiceRootDirectory)/tokens.txt",
                ),
            ])
        case (.qwen3ASR, .modelScope):
            .files([
                sherpaOnnxFile(
                    resolveBaseURL: "https://modelscope.cn/models",
                    repositoryID: qwen3ASROnnxModelScopeRepositoryID,
                    sourcePath: "model_0.6B/conv_frontend.onnx",
                    destinationPath: "\(qwen3ASRRootDirectory)/conv_frontend.onnx",
                ),
                sherpaOnnxFile(
                    resolveBaseURL: "https://modelscope.cn/models",
                    repositoryID: qwen3ASROnnxModelScopeRepositoryID,
                    sourcePath: "model_0.6B/encoder.int8.onnx",
                    destinationPath: "\(qwen3ASRRootDirectory)/encoder.int8.onnx",
                ),
                sherpaOnnxFile(
                    resolveBaseURL: "https://modelscope.cn/models",
                    repositoryID: qwen3ASROnnxModelScopeRepositoryID,
                    sourcePath: "model_0.6B/decoder.int8.onnx",
                    destinationPath: "\(qwen3ASRRootDirectory)/decoder.int8.onnx",
                ),
                sherpaOnnxFile(
                    resolveBaseURL: "https://modelscope.cn/models",
                    repositoryID: qwen3ASRTokenizerModelScopeRepositoryID,
                    sourcePath: "merges.txt",
                    destinationPath: "\(qwen3ASRRootDirectory)/tokenizer/merges.txt",
                ),
                sherpaOnnxFile(
                    resolveBaseURL: "https://modelscope.cn/models",
                    repositoryID: qwen3ASRTokenizerModelScopeRepositoryID,
                    sourcePath: "tokenizer_config.json",
                    destinationPath: "\(qwen3ASRRootDirectory)/tokenizer/tokenizer_config.json",
                ),
                sherpaOnnxFile(
                    resolveBaseURL: "https://modelscope.cn/models",
                    repositoryID: qwen3ASRTokenizerModelScopeRepositoryID,
                    sourcePath: "vocab.json",
                    destinationPath: "\(qwen3ASRRootDirectory)/tokenizer/vocab.json",
                ),
            ])
        }
    }

    static func sherpaOnnxModelDirectoryName(for model: LocalSTTModel) -> String? {
        switch model {
        case .whisperLocal, .whisperLocalLarge:
            nil
        case .senseVoiceSmall:
            senseVoiceRootDirectory
        case .qwen3ASR:
            qwen3ASRRootDirectory
        }
    }

    private static func sherpaOnnxASRModelArchiveURL(archiveName: String) -> URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(archiveName)")!
    }

    private static func sherpaOnnxFile(
        resolveBaseURL: String,
        repositoryID: String,
        sourcePath: String,
        destinationPath: String,
    ) -> SherpaOnnxModelFile {
        SherpaOnnxModelFile(
            url: URL(string: "\(resolveBaseURL)/\(repositoryID)/resolve/master/\(sourcePath)")!,
            relativePath: destinationPath,
        )
    }
}
