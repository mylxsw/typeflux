import Foundation
import GRPC
import NIO
import os

final class GoogleCloudSpeechTranscriber: TypefluxCloudScenarioAwareTranscriber {
    private let settingsStore: SettingsStore
    private let logger = Logger(subsystem: "dev.typeflux", category: "GoogleCloudSpeechTranscriber")

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func transcribeStream(
        audioFile: AudioFile,
        scenario _: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let configuration = try await MainActor.run {
            try GoogleCloudSpeechConfiguration(
                projectID: settingsStore.googleCloudProjectID,
                apiKey: settingsStore.googleCloudAPIKey,
                model: settingsStore.googleCloudModel,
                appLanguage: settingsStore.appLanguage,
            )
        }
        let pcmData = try CloudASRAudioConverter.convert(url: audioFile.fileURL)
        return try await GoogleCloudSpeechStreamingSession.run(
            pcmData: pcmData,
            configuration: configuration,
            onUpdate: onUpdate,
        )
    }

    static func testConnection(projectID: String, apiKey: String, model: String, appLanguage: AppLanguage) async throws -> String {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: projectID,
            apiKey: apiKey,
            model: model,
            appLanguage: appLanguage,
        )
        return try await GoogleCloudSpeechStreamingSession.run(
            pcmData: RemoteSTTTestAudio.pcm16MonoSilence(durationMs: 300),
            configuration: configuration,
        ) { _ in }
    }
}

struct GoogleCloudSpeechConfiguration: Equatable {
    let projectID: String
    let apiKey: String
    let model: String
    let location: String
    let endpointHost: String
    let languageCode: String

    var recognizer: String {
        "projects/\(projectID)/locations/\(location)/recognizers/_"
    }

    var routingMetadataValue: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/&=+")
        let encodedRecognizer = recognizer.addingPercentEncoding(withAllowedCharacters: allowed) ?? recognizer
        return "recognizer=\(encodedRecognizer)"
    }

    init(projectID: String, apiKey: String, model: String, appLanguage: AppLanguage) throws {
        let trimmedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedProjectID.isEmpty else {
            throw GoogleCloudSpeechError.missingProjectID
        }
        guard !trimmedAPIKey.isEmpty else {
            throw GoogleCloudSpeechError.missingAPIKey
        }

        self.projectID = trimmedProjectID
        self.apiKey = trimmedAPIKey
        self.model = trimmedModel.isEmpty ? GoogleCloudSpeechDefaults.model : trimmedModel
        location = Self.googleLocation(for: self.model)
        endpointHost = location == "global" ? "speech.googleapis.com" : "\(location)-speech.googleapis.com"
        languageCode = Self.googleLanguageCode(for: appLanguage)
    }

    static func googleLocation(for model: String) -> String {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chirp_3":
            "us"
        default:
            "global"
        }
    }

    static func googleLanguageCode(for appLanguage: AppLanguage) -> String {
        switch appLanguage {
        case .english:
            "en-US"
        case .simplifiedChinese:
            "zh-CN"
        case .traditionalChinese:
            "zh-TW"
        case .japanese:
            "ja-JP"
        case .korean:
            "ko-KR"
        }
    }
}

enum GoogleCloudSpeechError: LocalizedError {
    case missingProjectID
    case missingAPIKey
    case rpcFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectID:
            "Google Cloud Project ID is required."
        case .missingAPIKey:
            "Google Cloud API key is required."
        case .rpcFailed(let message):
            "Google Cloud Speech-to-Text error: \(message)"
        }
    }
}

private enum GoogleCloudSpeechStreamingSession {
    static func run(
        pcmData: Data,
        configuration: GoogleCloudSpeechConfiguration,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        let channel = ClientConnection.usingTLSBackedByNIOSSL(on: group)
            .connect(host: configuration.endpointHost, port: 443)

        let client = Google_Cloud_Speech_V2_SpeechAsyncClient(channel: channel)
        var callOptions = CallOptions(timeLimit: .timeout(.seconds(30)))
        callOptions.customMetadata.add(name: "x-goog-api-key", value: configuration.apiKey)
        callOptions.customMetadata.add(
            name: "x-goog-request-params",
            value: configuration.routingMetadataValue,
        )

        let responses = client.streamingRecognize(
            makeRequests(pcmData: pcmData, configuration: configuration),
            callOptions: callOptions,
        )

        var finalSegments: [String] = []
        var currentPartial = ""

        do {
            for try await response in responses {
                let update = transcriptUpdate(
                    from: response,
                    finalSegments: &finalSegments,
                    currentPartial: &currentPartial,
                )
                if !update.text.isEmpty {
                    await onUpdate(update)
                }
            }
        } catch {
            await shutdown(channel: channel, group: group)
            throw GoogleCloudSpeechError.rpcFailed(rpcErrorMessage(error))
        }

        let transcript = assembleTranscript(finalSegments: finalSegments, currentPartial: currentPartial)
        if !transcript.isEmpty {
            await onUpdate(TranscriptionSnapshot(text: transcript, isFinal: true))
        }
        await shutdown(channel: channel, group: group)
        return transcript
    }

    private static func rpcErrorMessage(_ error: Error) -> String {
        if let status = error as? GRPCStatus {
            if let message = status.message, !message.isEmpty {
                return "\(status.code): \(message)"
            }
            return String(describing: status.code)
        }
        return error.localizedDescription
    }

    private static func shutdown(channel: ClientConnection, group: EventLoopGroup) async {
        try? await channel.close().get()
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }

    private static func makeRequests(
        pcmData: Data,
        configuration: GoogleCloudSpeechConfiguration,
    ) -> [Google_Cloud_Speech_V2_StreamingRecognizeRequest] {
        var requests = [makeConfigRequest(configuration: configuration)]
        requests.reserveCapacity(1 + Int(ceil(Double(pcmData.count) / Double(CloudASRAudioConverter.chunkSize))))

        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + CloudASRAudioConverter.chunkSize, pcmData.count)
            var request = Google_Cloud_Speech_V2_StreamingRecognizeRequest()
            request.recognizer = configuration.recognizer
            request.audio = Data(pcmData[offset ..< end])
            requests.append(request)
            offset = end
        }
        return requests
    }

    private static func makeConfigRequest(
        configuration: GoogleCloudSpeechConfiguration,
    ) -> Google_Cloud_Speech_V2_StreamingRecognizeRequest {
        var decodingConfig = Google_Cloud_Speech_V2_ExplicitDecodingConfig()
        decodingConfig.encoding = .linear16
        decodingConfig.sampleRateHertz = Int32(CloudASRAudioConverter.targetSampleRate)
        decodingConfig.audioChannelCount = 1

        var recognitionConfig = Google_Cloud_Speech_V2_RecognitionConfig()
        recognitionConfig.explicitDecodingConfig = decodingConfig
        recognitionConfig.model = configuration.model
        recognitionConfig.languageCodes = [configuration.languageCode]

        var features = Google_Cloud_Speech_V2_StreamingRecognitionFeatures()
        features.interimResults = true

        var streamingConfig = Google_Cloud_Speech_V2_StreamingRecognitionConfig()
        streamingConfig.config = recognitionConfig
        streamingConfig.streamingFeatures = features

        var request = Google_Cloud_Speech_V2_StreamingRecognizeRequest()
        request.recognizer = configuration.recognizer
        request.streamingConfig = streamingConfig
        return request
    }

    private static func transcriptUpdate(
        from response: Google_Cloud_Speech_V2_StreamingRecognizeResponse,
        finalSegments: inout [String],
        currentPartial: inout String,
    ) -> TranscriptionSnapshot {
        for result in response.results {
            guard let alternative = result.alternatives.first else { continue }
            let transcript = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { continue }

            if result.isFinal {
                finalSegments.append(transcript)
                currentPartial = ""
            } else {
                currentPartial = transcript
            }
        }

        return TranscriptionSnapshot(
            text: assembleTranscript(finalSegments: finalSegments, currentPartial: currentPartial),
            isFinal: !finalSegments.isEmpty && currentPartial.isEmpty,
        )
    }

    private static func assembleTranscript(finalSegments: [String], currentPartial: String) -> String {
        (finalSegments + [currentPartial])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
