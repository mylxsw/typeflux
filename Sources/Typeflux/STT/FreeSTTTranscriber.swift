import Foundation

struct ResolvedFreeSTTConnection {
    let baseURL: URL
    let model: String
    let apiKey: String
    let additionalHeaders: [String: String]
}

enum FreeSTTConnectionResolver {
    static func resolve(modelName: String) throws -> ResolvedFreeSTTConnection {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw NSError(
                domain: "FreeSTT",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("settings.models.freeSTT.validation.emptyModel")],
            )
        }
        guard let resolved = FreeSTTModelRegistry.resolve(modelName: trimmedModel) else {
            throw NSError(
                domain: "FreeSTT",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: L(
                        "settings.models.freeSTT.validation.unsupportedModel",
                        trimmedModel,
                    ),
                ],
            )
        }
        guard let baseURL = URL(string: resolved.baseURL), !resolved.baseURL.isEmpty else {
            throw NSError(
                domain: "FreeSTT",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: L("settings.models.freeSTT.validation.invalidEndpoint")],
            )
        }

        return ResolvedFreeSTTConnection(
            baseURL: baseURL,
            model: resolved.modelName,
            apiKey: resolved.apiKey,
            additionalHeaders: resolved.additionalHeaders,
        )
    }
}

final class FreeSTTTranscriber: Transcriber {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    static func testConnection(modelName: String) async throws -> String {
        let connection = try FreeSTTConnectionResolver.resolve(modelName: modelName)
        let request = try makeTestRequest(
            baseURL: connection.baseURL,
            model: connection.model,
            apiKey: connection.apiKey,
            additionalHeaders: connection.additionalHeaders,
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FreeSTTTranscriber",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response type."],
            )
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "FreeSTTTranscriber",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"],
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
    ) async throws -> String {
        let connection = try FreeSTTConnectionResolver.resolve(modelName: settingsStore.freeSTTModel)
        let uploadURL = try preparedUploadURL(for: audioFile)
        let request = try makeRequest(
            baseURL: connection.baseURL,
            model: connection.model,
            apiKey: connection.apiKey,
            additionalHeaders: connection.additionalHeaders,
            uploadURL: uploadURL,
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            NetworkDebugLogger.logResponse(response, data: data)
            throw NSError(
                domain: "FreeSTTTranscriber",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response type."],
            )
        }

        NetworkDebugLogger.logResponse(http, data: data)

        guard (200 ..< 300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "FreeSTTTranscriber",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"],
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await onUpdate(TranscriptionSnapshot(text: text, isFinal: true))
        return text
    }

    private func preparedUploadURL(for audioFile: AudioFile) throws -> URL {
        switch audioFile.fileURL.pathExtension.lowercased() {
        case "wav", "mp3", "m4a", "mp4", "mpeg", "mpga", "webm":
            audioFile.fileURL
        default:
            try AudioFileTranscoder.wavFileURL(for: audioFile)
        }
    }

    private func makeRequest(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
        uploadURL: URL,
    ) throws -> URLRequest {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MultipartFormData.build(
            boundary: boundary,
            parts: [
                .text(name: "model", value: model),
                .file(
                    name: "file",
                    filename: uploadURL.lastPathComponent,
                    mimeType: mimeType(for: uploadURL),
                    fileURL: uploadURL,
                ),
            ],
        )
        return request
    }

    private static func makeTestRequest(
        baseURL: URL,
        model: String,
        apiKey: String,
        additionalHeaders: [String: String],
    ) throws -> URLRequest {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MultipartFormData.build(
            boundary: boundary,
            parts: [
                .text(name: "model", value: model),
                .fileData(
                    name: "file",
                    filename: "typeflux-stt-test.wav",
                    mimeType: "audio/wav",
                    data: RemoteSTTTestAudio.wavSilence(),
                ),
            ],
        )
        return request
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            "audio/wav"
        case "m4a", "mp4":
            "audio/m4a"
        case "mp3", "mpeg", "mpga":
            "audio/mpeg"
        case "webm":
            "audio/webm"
        default:
            "application/octet-stream"
        }
    }
}
