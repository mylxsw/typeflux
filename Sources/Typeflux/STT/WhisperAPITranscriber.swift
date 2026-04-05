import Foundation

final class WhisperAPITranscriber: Transcriber {
    private let settingsStore: SettingsStore
    private let baseURLOverride: String?
    private let apiKeyOverride: (() -> String)?
    private let modelOverride: (() -> String)?

    init(
        settingsStore: SettingsStore,
        baseURLOverride: String? = nil,
        apiKeyOverride: (() -> String)? = nil,
        modelOverride: (() -> String)? = nil
    ) {
        self.settingsStore = settingsStore
        self.baseURLOverride = baseURLOverride
        self.apiKeyOverride = apiKeyOverride
        self.modelOverride = modelOverride
    }

    private var effectiveBaseURL: String {
        if let baseURLOverride {
            return baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return OpenAIAudioModelCatalog.resolvedWhisperEndpoint(settingsStore.whisperBaseURL)
    }
    private var effectiveAPIKey: String { apiKeyOverride?() ?? settingsStore.whisperAPIKey }
    private var effectiveModel: String {
        if let modelOverride {
            return OpenAIAudioModelCatalog.resolvedWhisperModel(
                modelOverride(),
                endpoint: effectiveBaseURL
            )
        }
        return OpenAIAudioModelCatalog.resolvedWhisperModel(
            settingsStore.whisperModel,
            endpoint: effectiveBaseURL
        )
    }

    static func testConnection(baseURL: String, model: String, apiKey: String) async throws -> String {
        let resolvedEndpoint = OpenAIAudioModelCatalog.resolvedWhisperEndpoint(baseURL)
        guard let resolvedBaseURL = URL(string: resolvedEndpoint) else {
            throw NSError(
                domain: "WhisperAPITranscriber",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Invalid transcription endpoint. Please enter a valid URL."]
            )
        }

        let resolvedModel = OpenAIAudioModelCatalog.resolvedWhisperModel(
            model,
            endpoint: resolvedEndpoint
        )
        let request = try makeTestRequest(baseURL: resolvedBaseURL, model: resolvedModel, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "WhisperAPITranscriber",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response type."]
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "WhisperAPITranscriber",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"]
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
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        guard let baseURL = URL(string: effectiveBaseURL) else {
            throw NSError(domain: "WhisperAPITranscriber", code: 1)
        }

        let model = effectiveModel

        let vocabularyPrompt = vocabularyPromptText()
        let uploadURL = try preparedUploadURL(for: audioFile)
        let uploadAttributes = try? FileManager.default.attributesOfItem(atPath: uploadURL.path)
        let uploadSize = (uploadAttributes?[.size] as? NSNumber)?.int64Value ?? -1

        NetworkDebugLogger.logMessage(
            """
            Remote STT upload prepared:
            sourcePath=\(audioFile.fileURL.path)
            uploadPath=\(uploadURL.path)
            ext=\(uploadURL.pathExtension.lowercased())
            sizeBytes=\(uploadSize)
            """
        )

        let shouldRequestStreaming = supportsServerStream(for: model, endpoint: baseURL)
        let request = try makeRequest(
            baseURL: baseURL,
            model: model,
            vocabularyPrompt: vocabularyPrompt,
            uploadURL: uploadURL,
            stream: shouldRequestStreaming
        )

        NetworkDebugLogger.logRequest(
            request,
            bodyDescription: """
            {
              "model": "\(model)",
              "prompt": "\(vocabularyPrompt ?? "")",
              "stream": \(shouldRequestStreaming),
              "file": {
                "path": "\(uploadURL.path)",
                "filename": "\(uploadURL.lastPathComponent)",
                "mimeType": "\(mimeType(for: uploadURL))",
                "sizeBytes": \(request.httpBody?.count ?? 0)
              }
            }
            """
        )

        if shouldRequestStreaming {
            do {
                let text = try await streamResponse(for: request, onUpdate: onUpdate)
                if !text.isEmpty {
                    return text
                }
            } catch {
                NetworkDebugLogger.logError(context: "Remote STT streaming failed, retrying without stream", error: error)
            }
        }

        return try await transcribeOnce(
            baseURL: baseURL,
            model: model,
            vocabularyPrompt: vocabularyPrompt,
            uploadURL: uploadURL,
            onUpdate: onUpdate
        )
    }

    private func vocabularyPromptText() -> String? {
        TranscriptionLanguageHints.remotePrompt(vocabularyTerms: VocabularyStore.activeTerms())
    }

    private func transcribeOnce(
        baseURL: URL,
        model: String,
        vocabularyPrompt: String?,
        uploadURL: URL,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let nonStreamingRequest = try makeRequest(
            baseURL: baseURL,
            model: model,
            vocabularyPrompt: vocabularyPrompt,
            uploadURL: uploadURL,
            stream: false
        )

        let (data, response) = try await URLSession.shared.data(for: nonStreamingRequest)
        guard let http = response as? HTTPURLResponse else {
            NetworkDebugLogger.logResponse(response, data: data)
            throw NSError(domain: "WhisperAPITranscriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response type"])
        }

        NetworkDebugLogger.logResponse(http, data: data)

        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "WhisperAPITranscriber", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await onUpdate(TranscriptionSnapshot(text: text, isFinal: true))
        NetworkDebugLogger.logMessage("Remote STT final result (\(model)): \(text.isEmpty ? "<empty>" : text)")
        return text
    }

    private func streamResponse(
        for request: URLRequest,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "WhisperAPITranscriber",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid stream response type."]
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
            }
            NetworkDebugLogger.logResponse(http, data: errorBody)
            let message = String(data: errorBody, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "WhisperAPITranscriber",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(message)"]
            )
        }

        NetworkDebugLogger.logResponse(http, bodyDescription: "<transcription stream opened>")

        var finalText = ""
        for try await event in SSEClient.lines(for: bytes) {
            if event == "[DONE]" { break }
            guard let payload = event.data(using: .utf8) else { continue }

            let snapshot = try Self.snapshot(from: payload, currentText: finalText)
            guard let snapshot else { continue }
            finalText = snapshot.text
            await onUpdate(snapshot)
            if snapshot.isFinal {
                break
            }
        }

        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func snapshot(from payload: Data, currentText: String) throws -> TranscriptionSnapshot? {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }

        if let type = object["type"] as? String {
            switch type {
            case "transcript.text.delta":
                let delta = object["delta"] as? String ?? ""
                return TranscriptionSnapshot(text: currentText + delta, isFinal: false)
            case "transcript.text.done":
                let text = (object["text"] as? String ?? currentText).trimmingCharacters(in: .whitespacesAndNewlines)
                return TranscriptionSnapshot(text: text, isFinal: true)
            default:
                return nil
            }
        }

        if let text = object["text"] as? String {
            return TranscriptionSnapshot(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: true)
        }

        return nil
    }

    private func preparedUploadURL(for audioFile: AudioFile) throws -> URL {
        switch audioFile.fileURL.pathExtension.lowercased() {
        case "wav", "mp3", "m4a", "mp4", "mpeg", "mpga", "webm":
            return audioFile.fileURL
        default:
            do {
                return try AudioFileTranscoder.wavFileURL(for: audioFile)
            } catch {
                throw NSError(
                    domain: "WhisperAPITranscriber",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Unable to prepare audio upload file.",
                        NSLocalizedFailureReasonErrorKey: "Audio file transcoding failed for \(audioFile.fileURL.lastPathComponent).",
                        NSUnderlyingErrorKey: error
                    ]
                )
            }
        }
    }

    private func supportsServerStream(for model: String, endpoint: URL) -> Bool {
        OpenAIAudioModelCatalog.supportsWhisperStreaming(
            model: model,
            endpoint: endpoint.absoluteString
        )
    }

    private func makeRequest(
        baseURL: URL,
        model: String,
        vocabularyPrompt: String?,
        uploadURL: URL,
        stream: Bool
    ) throws -> URLRequest {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !effectiveAPIKey.isEmpty {
            request.setValue("Bearer \(effectiveAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var parts: [MultipartPart] = [.text(name: "model", value: model)]
        if let vocabularyPrompt, !vocabularyPrompt.isEmpty {
            parts.append(.text(name: "prompt", value: vocabularyPrompt))
        }
        if stream {
            parts.append(.text(name: "stream", value: "true"))
        }
        parts.append(
            .file(
                name: "file",
                filename: uploadURL.lastPathComponent,
                mimeType: mimeType(for: uploadURL),
                fileURL: uploadURL
            )
        )

        request.httpBody = try MultipartFormData.build(boundary: boundary, parts: parts)
        return request
    }

    private static func makeTestRequest(baseURL: URL, model: String, apiKey: String) throws -> URLRequest {
        let url = OpenAIEndpointResolver.resolve(from: baseURL, path: "audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                    data: RemoteSTTTestAudio.wavSilence()
                )
            ]
        )
        return request
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a", "mp4":
            return "audio/m4a"
        case "mp3", "mpeg", "mpga":
            return "audio/mpeg"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }
}

enum MultipartPart {
    case text(name: String, value: String)
    case file(name: String, filename: String, mimeType: String, fileURL: URL)
    case fileData(name: String, filename: String, mimeType: String, data: Data)
}

enum MultipartFormData {
    static func build(boundary: String, parts: [MultipartPart]) throws -> Data {
        var data = Data()

        for part in parts {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)

            switch part {
            case .text(let name, let value):
                data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                data.append("\(value)\r\n".data(using: .utf8)!)

            case .file(let name, let filename, let mimeType, let fileURL):
                data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
                data.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
                data.append(try Data(contentsOf: fileURL))
                data.append("\r\n".data(using: .utf8)!)

            case .fileData(let name, let filename, let mimeType, let fileData):
                data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
                data.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
                data.append(fileData)
                data.append("\r\n".data(using: .utf8)!)
            }
        }

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }
}
