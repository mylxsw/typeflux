import Foundation

protocol OllamaModelManaging {
    func ensureModelReady(settingsStore: SettingsStore) async throws
}

final class OllamaLocalModelManager: OllamaModelManaging {
    private let commandRunner: ProcessCommandRunning
    private let fileManager = FileManager.default
    private let analyticsReporter: AnalyticsEventReporting
    private let session: URLSession

    init(
        analyticsReporter: AnalyticsEventReporting = NoopAnalyticsEventReporter.shared,
        commandRunner: ProcessCommandRunning = ProcessCommandRunner(),
        session: URLSession = .shared
    ) {
        self.analyticsReporter = analyticsReporter
        self.commandRunner = commandRunner
        self.session = session
    }

    func ensureModelReady(settingsStore: SettingsStore) async throws {
        let model = settingsStore.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw NSError(
                domain: "OllamaLocalModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Please configure a local Ollama model first."]
            )
        }

        let baseURL = try validatedBaseURL(from: settingsStore.ollamaBaseURL)
        let executable = try await resolveExecutable(autoInstall: settingsStore.ollamaAutoSetup)

        if try await !isServerReachable(baseURL: baseURL) {
            try startServer(executablePath: executable)
            try await waitUntilServerReady(baseURL: baseURL)
        }

        if try await !hasModel(named: model, baseURL: baseURL) {
            NetworkDebugLogger.logMessage("Ollama model \(model) is missing locally, pulling it now")
            let attemptID = UUID().uuidString.lowercased()
            let startedAt = ContinuousClock.now
            let baseProperties = [
                "attempt_id": attemptID, "job_id": attemptID, "model_kind": "llm", "model_type": "ollama",
                "model_identifier": model, "download_source": "ollama",
                "source_host": baseURL.host ?? "local-ollama", "normalized_path": model
            ]
            analyticsReporter.report(eventName: "model_download_started", properties: baseProperties)
            do {
                _ = try await commandRunner.run(executablePath: executable, arguments: ["pull", model])
                var properties = baseProperties
                properties["duration_ms"] = String(startedAt.duration(to: .now).milliseconds)
                properties["status"] = "succeeded"
                analyticsReporter.report(eventName: "model_download_succeeded", properties: properties)
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                var properties = baseProperties
                properties["duration_ms"] = String(startedAt.duration(to: .now).milliseconds)
                properties["status"] = cancelled ? "cancelled" : "failed"
                properties["error_category"] = cancelled ? "cancelled" : "ollama_pull_failed"
                analyticsReporter.report(
                    eventName: cancelled ? "model_download_cancelled" : "model_download_failed",
                    properties: properties
                )
                throw error
            }
        }
    }

    private func validatedBaseURL(from string: String) throws -> URL {
        let fallback = "http://127.0.0.1:11434"
        guard let url = URL(string: string.isEmpty ? fallback : string) else {
            throw NSError(
                domain: "OllamaLocalModelManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama base URL."]
            )
        }

        return url
    }

    private func resolveExecutable(autoInstall: Bool) async throws -> String {
        let commonPaths = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/usr/bin/ollama"
        ]

        if let existing = commonPaths.first(where: fileManager.isExecutableFile(atPath:)) {
            return existing
        }

        do {
            let result = try await commandRunner.run(executablePath: "/usr/bin/env", arguments: ["which", "ollama"])
            let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty {
                return resolved
            }
        } catch {
            NetworkDebugLogger.logError(context: "Unable to locate ollama", error: error)
        }

        guard autoInstall else {
            throw NSError(
                domain: "OllamaLocalModelManager",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Ollama is not installed. Enable auto setup or install Ollama manually."
                ]
            )
        }

        NetworkDebugLogger.logMessage("Installing Ollama automatically")
        _ = try await commandRunner.run(
            executablePath: "/bin/bash",
            arguments: ["-lc", "curl -fsSL https://ollama.com/install.sh | sh"]
        )

        if let existing = commonPaths.first(where: fileManager.isExecutableFile(atPath:)) {
            return existing
        }

        let result = try await commandRunner.run(executablePath: "/usr/bin/env", arguments: ["which", "ollama"])
        let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "OllamaLocalModelManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Ollama install finished but executable was not found."]
            )
        }

        return resolved
    }

    private func isServerReachable(baseURL: URL) async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200 ..< 300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func startServer(executablePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["serve"]

        let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("typeflux-ollama.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle

        try process.run()
    }

    private func waitUntilServerReady(baseURL: URL) async throws {
        for _ in 0 ..< 20 {
            if try await isServerReachable(baseURL: baseURL) {
                return
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw NSError(
            domain: "OllamaLocalModelManager",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Ollama service did not start in time."]
        )
    }

    private func hasModel(named model: String, baseURL: URL) async throws -> Bool {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            return false
        }

        let payload = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return payload.models.contains { entry in
            entry.name == model || entry.name.hasPrefix("\(model):")
        }
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let components = self.components
        return components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaTagModel]
}

private struct OllamaTagModel: Decodable {
    let name: String
}
