import Foundation

enum LocalModelDownloadCatalog {
    private static let huggingFaceEndpoint = "https://huggingface.co"
    private static let whisperKitRepositoryID = "argmaxinc/whisperkit-coreml"
    private static let whisperKitDefaultModelName = "whisperkit-medium"
    private static let sherpaOnnxRuntimeRootDirectory = "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts"
    private static let senseVoiceRootDirectory = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    private static let qwen3ASRRootDirectory = "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"

    static var whisperKitDefaultModelIdentifier: String {
        whisperKitDefaultModelName
    }

    static func whisperKitModelRepository(source _: ModelDownloadSource) -> String {
        whisperKitRepositoryID
    }

    static func whisperKitModelRepositoryURL(source _: ModelDownloadSource) -> URL {
        URL(string: "\(huggingFaceEndpoint)/\(whisperKitRepositoryID)")!
    }

    static func whisperKitModelEndpoint(source _: ModelDownloadSource) -> String {
        huggingFaceEndpoint
    }

    static func sherpaOnnxRuntimeArchiveURL(source _: ModelDownloadSource) -> URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.35/\(sherpaOnnxRuntimeRootDirectory).tar.bz2")!
    }

    static var sherpaOnnxRuntimeDirectoryName: String {
        sherpaOnnxRuntimeRootDirectory
    }

    static func sherpaOnnxModelArchiveURL(for model: LocalSTTModel, source _: ModelDownloadSource) -> URL? {
        switch model {
        case .whisperLocal, .whisperLocalLarge:
            nil
        case .senseVoiceSmall:
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(senseVoiceRootDirectory).tar.bz2")!
        case .qwen3ASR:
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(qwen3ASRRootDirectory).tar.bz2")!
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
}
