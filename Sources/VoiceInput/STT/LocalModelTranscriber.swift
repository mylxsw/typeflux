import Foundation

final class LocalModelTranscriber: Transcriber {
    private let settingsStore: SettingsStore
    private let serviceManager: LocalSTTServiceManager

    init(settingsStore: SettingsStore, serviceManager: LocalSTTServiceManager) {
        self.settingsStore = settingsStore
        self.serviceManager = serviceManager
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        let baseURL = try await serviceManager.ensureServerReady(settingsStore: settingsStore)
        let model = settingsStore.localSTTModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settingsStore.localSTTModel.defaultModelIdentifier
            : settingsStore.localSTTModelIdentifier
        let uploadURL = audioFile.fileURL
        let vocabularyPrompt = vocabularyPromptText()

        let url = baseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var parts: [MultipartPart] = [
            .text(name: "model", value: model),
            .text(name: "provider", value: settingsStore.localSTTModel.rawValue)
        ]
        if let vocabularyPrompt, !vocabularyPrompt.isEmpty {
            parts.append(.text(name: "prompt", value: vocabularyPrompt))
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

        NetworkDebugLogger.logRequest(
            request,
            bodyDescription: """
            {
              "model": "\(model)",
              "provider": "\(settingsStore.localSTTModel.rawValue)",
              "prompt": "\(vocabularyPrompt ?? "")",
              "file": {
                "path": "\(uploadURL.path)",
                "filename": "\(uploadURL.lastPathComponent)",
                "mimeType": "\(mimeType(for: uploadURL))"
              }
            }
            """
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            NetworkDebugLogger.logResponse(response, data: data)
            throw NSError(
                domain: "LocalModelTranscriber",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response from local STT service."]
            )
        }

        NetworkDebugLogger.logResponse(http, data: data)

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "LocalModelTranscriber",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a", "mp4":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        case "caf":
            return "audio/x-caf"
        default:
            return "application/octet-stream"
        }
    }

    private func vocabularyPromptText() -> String? {
        let terms = VocabularyStore.activeTerms()
        guard !terms.isEmpty else { return nil }
        return "Vocabulary terms to recognize accurately: \(terms.joined(separator: ", "))"
    }
}
