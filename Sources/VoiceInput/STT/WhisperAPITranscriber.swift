import Foundation

final class WhisperAPITranscriber: Transcriber {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        guard let baseURL = URL(string: settingsStore.whisperBaseURL), !settingsStore.whisperBaseURL.isEmpty else {
            throw NSError(domain: "WhisperAPITranscriber", code: 1)
        }

        let model = settingsStore.whisperModel.isEmpty ? "whisper-1" : settingsStore.whisperModel

        let url = baseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !settingsStore.whisperAPIKey.isEmpty {
            request.setValue("Bearer \(settingsStore.whisperAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try MultipartFormData.build(boundary: boundary, parts: [
            .text(name: "model", value: model),
            .file(name: "file", filename: audioFile.fileURL.lastPathComponent, mimeType: "audio/m4a", fileURL: audioFile.fileURL)
        ])
        request.httpBody = body

        NetworkDebugLogger.logRequest(
            request,
            bodyDescription: """
            {
              "model": "\(model)",
              "file": {
                "path": "\(audioFile.fileURL.path)",
                "filename": "\(audioFile.fileURL.lastPathComponent)",
                "mimeType": "audio/m4a",
                "sizeBytes": \(body.count)
              }
            }
            """
        )

        let (data, response) = try await URLSession.shared.data(for: request)
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
        let text = json?["text"] as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum MultipartPart {
    case text(name: String, value: String)
    case file(name: String, filename: String, mimeType: String, fileURL: URL)
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
            }
        }

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }
}
