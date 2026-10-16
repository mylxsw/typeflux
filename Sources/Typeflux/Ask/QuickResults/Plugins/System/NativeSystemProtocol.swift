import Foundation

enum NativeSystemOperation: String, Codable, Sendable, CaseIterable {
    case probe, toggleWiFi, toggleBluetooth, toggleScrollDirection
}

enum NativeSystemOutcome: String, Codable, Sendable {
    case completed, notExecuted, unknown
}

struct NativeSystemRequest: Codable, Sendable {
    var version = 1
    var requestID = UUID()
    var operation: NativeSystemOperation
}

struct NativeSystemResponse: Codable, Sendable {
    var version = 1
    var requestID: UUID
    var operation: NativeSystemOperation
    var outcome: NativeSystemOutcome
}

/// One small request and one final response; no arbitrary command or user payload.
enum NativeSystemProtocol {
    static let maximumBytes = 1024

    static func decodeRequest(_ data: Data) throws -> NativeSystemRequest {
        guard data.count <= maximumBytes else { throw NativeSystemFailure.notExecuted }
        let request = try JSONDecoder().decode(NativeSystemRequest.self, from: data)
        guard request.version == 1 else { throw NativeSystemFailure.notExecuted }
        return request
    }

    static func decodeResponse(_ data: Data, for request: NativeSystemRequest) throws -> NativeSystemOutcome {
        guard data.count <= maximumBytes else { throw NativeSystemFailure.unknown }
        let response = try JSONDecoder().decode(NativeSystemResponse.self, from: data)
        guard response.version == 1, response.requestID == request.requestID,
              response.operation == request.operation else { throw NativeSystemFailure.unknown }
        return response.outcome
    }
}

enum NativeSystemFailure: Error, Equatable {
    case notExecuted, unknown, busy, coolingDown, disabled

    var messageKey: String {
        switch self {
        case .notExecuted: "ask.system.notExecuted"
        case .unknown: "ask.system.unknownOutcome"
        case .busy: "ask.system.busy"
        case .coolingDown: "ask.system.coolingDown"
        case .disabled: "ask.system.disabled"
        }
    }
}
