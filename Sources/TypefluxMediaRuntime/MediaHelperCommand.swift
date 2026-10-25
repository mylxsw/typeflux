import Foundation
import TypefluxMediaProtocol

public enum MediaHelperCommand {
    /// Synchronous adapter for image/PDF protocol tests and callers.
    public static func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
                           directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        do {
            let request = try read(input)
            let response: MediaResponse
            do { response = try decode(request, directory: directory) }
            catch { response = failure(request, error: error) }
            try write(response, output: output)
        } catch { /* Malformed requests terminate without reflecting untrusted bytes. */ }
    }

    public static func runAsync(input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
                                directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                                watchdog: @Sendable (UInt32) -> Void = { _ in }) async {
        do {
            let request = try read(input)
            // Only validated OCR requests extend the disposable child's orphan deadline.
            watchdog(request.operation == .recognizeText ? 95 : 35)
            let response: MediaResponse
            do {
                if request.operation.isRecordingPoster { response = try await MediaRecordingPosterDecoder.decode(request, directory: directory) }
                else if request.operation == .recordingTimeline { response = try await MediaRecordingTimelineDecoder.decode(request, directory: directory) }
                else if request.operation == .clipboardMedia { response = try await MediaClipboardDecoder.decode(request, directory: directory) }
                else if request.operation == .quickLook { response = try await MediaQuickLookDecoder.decode(request, directory: directory) }
                else if request.operation == .nativeIcon { response = try await MediaNativeIconDecoder.decode(request, directory: directory) }
                else if request.operation.isAV { response = try await MediaAVDecoder.decode(request, directory: directory) }
                else { response = try decode(request, directory: directory) }
            } catch { response = failure(request, error: error) }
            try write(response, output: output)
        } catch { /* No raw request, native error or media output is logged. */ }
    }

    private static func decode(_ request: MediaRequest, directory: URL) throws -> MediaResponse {
        guard !request.operation.isRecordingPoster, request.operation != .recordingTimeline, request.operation != .clipboardMedia, request.operation != .nativeIcon, request.operation != .quickLook else { throw MediaFailure.invalidProtocol }
        if request.operation == .registerFrames { return try MediaRegistrationDecoder.decode(request, directory: directory) }
        if request.operation == .recognizeText || request.operation == .textGeometry { return try MediaTextDecoder.decode(request, directory: directory) }
        if request.operation == .clipboardOCR { return try MediaOCRDecoder.decode(request, directory: directory) }
        if request.operation.isWorkflowImage { return try MediaWorkflowDecoder.decode(request, directory: directory) }
        if request.preview != nil { return try MediaPreviewDecoder.decode(request, directory: directory) }
        return try MediaDecoder.decode(request, input: directory.appendingPathComponent("input"))
    }
    private static func failure(_ request: MediaRequest, error: Error) -> MediaResponse {
        MediaResponse(id: request.id, failure: (error as? MediaFailure) ?? .unreadable)
    }
    private static func read(_ input: FileHandle) throws -> MediaRequest {
        var data = Data()
        while data.count <= MediaPreviewOptions.requestBytes {
            let chunk = try input.read(upToCount: MediaPreviewOptions.requestBytes + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= MediaPreviewOptions.requestBytes else { throw MediaFailure.invalidProtocol }
        let request = try JSONDecoder().decode(MediaRequest.self, from: data)
        try request.validate()
        guard data.count <= (request.preview == nil ? MediaLimits.requestBytes : MediaPreviewOptions.requestBytes)
        else { throw MediaFailure.invalidProtocol }
        return request
    }
    private static func write(_ response: MediaResponse, output: FileHandle) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(response)
        guard encoded.count <= MediaLimits.responseBytes else { throw MediaFailure.invalidProtocol }
        try output.write(contentsOf: encoded)
    }
}
