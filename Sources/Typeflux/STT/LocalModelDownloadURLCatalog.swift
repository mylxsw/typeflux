import Foundation

enum LocalModelDownloadURLCatalog {
    enum Key: String {
        case whisperKitHuggingFaceEndpoint
        case whisperKitHuggingFaceRepository
        case whisperKitChinaMirrorEndpoint
        case whisperKitChinaMirrorRepository
        case sherpaOnnxRuntimeHuggingFaceArchive
        case sherpaOnnxRuntimeChinaMirrorArchive
        case senseVoiceHuggingFaceModel
        case senseVoiceHuggingFaceTokens
        case senseVoiceChinaMirrorModel
        case senseVoiceChinaMirrorTokens
        case qwen3ASRHuggingFaceArchive
        case qwen3ASRModelScopeConvFrontend
        case qwen3ASRModelScopeEncoder
        case qwen3ASRModelScopeDecoder
        case qwen3ASRModelScopeTokenizerMerges
        case qwen3ASRModelScopeTokenizerConfig
        case qwen3ASRModelScopeTokenizerVocab
        case funASRHuggingFaceModel
        case funASRHuggingFaceTokens
        case funASRChinaMirrorModel
        case funASRChinaMirrorTokens
    }

    /// Single lookup entry point for download addresses.
    ///
    /// The current implementation uses an in-memory key-value table so the catalog is easy
    /// to read in source control. Later we can replace this function with a server-backed
    /// fetch without changing the rest of the catalog structure.
    static func url(for key: Key) -> URL {
        guard let url = urlTable[key] else {
            preconditionFailure("Missing URL catalog entry for key: \(key.rawValue)")
        }

        return url
    }

    private static let urlTable: [Key: URL] = [
        // MARK: - WhisperKit (Hugging Face)

        // Base endpoint passed to WhisperKit so it knows which host to talk to for model downloads.
        .whisperKitHuggingFaceEndpoint: URL(string: "https://huggingface.co")!,
        // Repository page that hosts the Core ML WhisperKit model variants.
        .whisperKitHuggingFaceRepository: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml")!,

        // MARK: - WhisperKit (China Mirror)

        // Domestic mirror endpoint used when Hugging Face access is slow or restricted.
        .whisperKitChinaMirrorEndpoint: URL(string: "https://hf-mirror.com")!,
        // Mirror repository page for the same WhisperKit Core ML model collection.
        .whisperKitChinaMirrorRepository: URL(string: "https://hf-mirror.com/argmaxinc/whisperkit-coreml")!,

        // MARK: - Sherpa ONNX Runtime

        // Full runtime archive from the official release, containing the offline binary and shared libraries.
        .sherpaOnnxRuntimeHuggingFaceArchive: URL(
            string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.35/sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts.tar.bz2"
        )!,
        // Domestic mirror of the same Sherpa ONNX runtime archive used for local ASR execution.
        .sherpaOnnxRuntimeChinaMirrorArchive: URL(
            string: "https://sourceforge.net/projects/sherpa-onnx.mirror/files/v1.12.35/sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts.tar.bz2/download"
        )!,

        // MARK: - SenseVoice Small

        // Quantized SenseVoice ONNX weights hosted on Hugging Face for the smallest usable download.
        .senseVoiceHuggingFaceModel: URL(
            string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx"
        )!,
        // Token vocabulary file required to decode SenseVoice model outputs into text.
        .senseVoiceHuggingFaceTokens: URL(
            string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt"
        )!,
        // Quantized SenseVoice ONNX weights used by the offline recognizer for inference.
        .senseVoiceChinaMirrorModel: URL(
            string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx"
        )!,
        // Token vocabulary file required to decode SenseVoice model outputs into text.
        .senseVoiceChinaMirrorTokens: URL(
            string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt"
        )!,

        // MARK: - Qwen3-ASR

        // Pre-packaged Qwen3-ASR archive from the upstream Sherpa ONNX ASR model releases.
        .qwen3ASRHuggingFaceArchive: URL(
            string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2"
        )!,
        // Convolutional frontend that converts raw acoustic features into encoder-ready representations.
        .qwen3ASRModelScopeConvFrontend: URL(
            string: "https://modelscope.cn/models/zengshuishui/Qwen3-ASR-onnx/resolve/master/model_0.6B/conv_frontend.onnx"
        )!,
        // Quantized encoder network that produces the main speech representations for recognition.
        .qwen3ASRModelScopeEncoder: URL(
            string: "https://modelscope.cn/models/zengshuishui/Qwen3-ASR-onnx/resolve/master/model_0.6B/encoder.int8.onnx"
        )!,
        // Quantized decoder network that works with the encoder output during transcription.
        .qwen3ASRModelScopeDecoder: URL(
            string: "https://modelscope.cn/models/zengshuishui/Qwen3-ASR-onnx/resolve/master/model_0.6B/decoder.int8.onnx"
        )!,
        // BPE merge rules used by the tokenizer to reconstruct token pieces for Qwen3-ASR.
        .qwen3ASRModelScopeTokenizerMerges: URL(
            string: "https://modelscope.cn/models/Qwen/Qwen3-ASR-0.6B/resolve/master/merges.txt"
        )!,
        // Tokenizer configuration describing the tokenizer behavior and special token settings.
        .qwen3ASRModelScopeTokenizerConfig: URL(
            string: "https://modelscope.cn/models/Qwen/Qwen3-ASR-0.6B/resolve/master/tokenizer_config.json"
        )!,
        // Tokenizer vocabulary mapping token ids to the text units used by Qwen3-ASR.
        .qwen3ASRModelScopeTokenizerVocab: URL(
            string: "https://modelscope.cn/models/Qwen/Qwen3-ASR-0.6B/resolve/master/vocab.json"
        )!,

        // MARK: - FunASR (Paraformer ZH Small)

        // Quantized Paraformer ZH Small ONNX weights hosted on Hugging Face.
        .funASRHuggingFaceModel: URL(
            string: "https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09/resolve/main/model.int8.onnx"
        )!,
        // Token vocabulary file required to decode Paraformer model outputs into text.
        .funASRHuggingFaceTokens: URL(
            string: "https://huggingface.co/csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09/resolve/main/tokens.txt"
        )!,
        // Quantized Paraformer ZH Small ONNX weights from the China mirror.
        .funASRChinaMirrorModel: URL(
            string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09/resolve/main/model.int8.onnx"
        )!,
        // Token vocabulary file from the China mirror.
        .funASRChinaMirrorTokens: URL(
            string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09/resolve/main/tokens.txt"
        )!,
    ]
}
