import Foundation

struct SenseVoiceDecodingConfiguration: Equatable {
    enum Language: String, CaseIterable, Equatable {
        case auto
        case zh
        case en
    }

    enum AudioNormalization: Equatable {
        case preserveInput
        case mono16k
    }

    static let `default` = SenseVoiceDecodingConfiguration()

    var language: Language = .auto
    var useITN: Bool = true
    var audioNormalization: AudioNormalization = .preserveInput
}
