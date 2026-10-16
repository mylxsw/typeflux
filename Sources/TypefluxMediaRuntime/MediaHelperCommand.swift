import Foundation
import TypefluxMediaProtocol

public enum MediaHelperCommand {
    public static func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
                           directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        do {
            let data = try input.read(upToCount: MediaLimits.requestBytes + 1) ?? Data()
            guard data.count <= MediaLimits.requestBytes else { return }
            let request = try JSONDecoder().decode(MediaRequest.self, from: data)
            try request.validate()
            let response: MediaResponse
            do { response = try MediaDecoder.decode(request, input: directory.appendingPathComponent("input")) }
            catch { response = MediaResponse(id: request.id, failure: (error as? MediaFailure) ?? .unreadable) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let encoded = try encoder.encode(response)
            guard encoded.count <= MediaLimits.responseBytes else { return }
            try output.write(contentsOf: encoded)
        } catch { /* Malformed requests terminate without reflecting untrusted bytes. */ }
    }
}
