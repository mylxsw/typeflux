import Foundation
import TypefluxMediaProtocol

public enum MediaHelperCommand {
    public static func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
                           directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        do {
            var data = Data()
            while data.count <= MediaPreviewOptions.requestBytes {
                let chunk = try input.read(upToCount: MediaPreviewOptions.requestBytes + 1 - data.count) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count <= MediaPreviewOptions.requestBytes else { return }
            let request = try JSONDecoder().decode(MediaRequest.self, from: data)
            try request.validate()
            guard data.count <= (request.preview == nil ? MediaLimits.requestBytes : MediaPreviewOptions.requestBytes)
            else { return }
            let response: MediaResponse
            do {
                if request.preview != nil { response = try MediaPreviewDecoder.decode(request, directory: directory) }
                else { response = try MediaDecoder.decode(request, input: directory.appendingPathComponent("input")) }
            }
            catch { response = MediaResponse(id: request.id, failure: (error as? MediaFailure) ?? .unreadable) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let encoded = try encoder.encode(response)
            guard encoded.count <= MediaLimits.responseBytes else { return }
            try output.write(contentsOf: encoded)
        } catch { /* Malformed requests terminate without reflecting untrusted bytes. */ }
    }
}
