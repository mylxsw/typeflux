import Foundation

/// Whether Typeflux Cloud can be reached. Conversations kept on the device and
/// the user's own providers never depend on it.
public enum ChatConnectivity: String, Equatable, Sendable {
    case online
    /// The device has a network, but Typeflux did not answer or answered with a server failure.
    case serviceUnavailable
    /// The device has no usable network.
    case offline

    static let serviceErrorPrefix = "HTTP_"

    static func serviceErrorCode(_ status: Int) -> String {
        serviceErrorPrefix + String(status)
    }

    /// The connectivity an error reveals, or nil when the service answered normally
    /// (a refusal, validation error or expired session is not an outage).
    public static func classify(_ error: Error) -> ChatConnectivity? {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .callIsActive:
                return .offline
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badServerResponse,
                 .secureConnectionFailed, .resourceUnavailable, .cannotLoadFromNetwork:
                return .serviceUnavailable
            case .cancelled:
                return nil
            default:
                return .serviceUnavailable
            }
        }
        if case let ChatAPIError.server(code, _) = error {
            if code.hasPrefix(serviceErrorPrefix + "5") || ["INTERNAL_ERROR", "SERVICE_UNAVAILABLE"].contains(code) {
                return .serviceUnavailable
            }
        }
        return nil
    }
}
