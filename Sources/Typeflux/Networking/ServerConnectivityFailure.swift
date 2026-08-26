import Darwin
import Foundation

enum ServerConnectivityFailure {
    static func matches(_ error: Error) -> Bool {
        matches(error, depth: 0)
    }

    private static func matches(_ error: Error, depth: Int) -> Bool {
        guard depth < 8 else { return false }

        if let executorError = error as? CloudRequestExecutorError,
           case let .allEndpointsFailed(lastError) = executorError {
            return matches(lastError, depth: depth + 1)
        }

        if let raceError = error as? CloudLocalTranscriptionRaceError {
            return raceError.cloudError.map { matches($0, depth: depth + 1) } ?? false
        }

        if let integratedError = error as? TypefluxCloudIntegratedRewriteError {
            return matches(integratedError.underlyingError, depth: depth + 1)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           connectivityURLCodes.contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           connectivityPOSIXCodes.contains(nsError.code) {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           matches(underlyingError, depth: depth + 1) {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return connectivityMessageFragments.contains { message.contains($0) }
    }

    private static let connectivityURLCodes: Set<Int> = [
        URLError.timedOut.rawValue,
        URLError.cannotFindHost.rawValue,
        URLError.cannotConnectToHost.rawValue,
        URLError.networkConnectionLost.rawValue,
        URLError.dnsLookupFailed.rawValue,
        URLError.notConnectedToInternet.rawValue,
        URLError.internationalRoamingOff.rawValue,
        URLError.callIsActive.rawValue,
        URLError.dataNotAllowed.rawValue,
        URLError.cannotLoadFromNetwork.rawValue,
        URLError.secureConnectionFailed.rawValue
    ]

    private static let connectivityPOSIXCodes: Set<Int> = [
        Int(ECONNREFUSED),
        Int(ECONNRESET),
        Int(ENETDOWN),
        Int(ENETUNREACH),
        Int(EHOSTDOWN),
        Int(EHOSTUNREACH),
        Int(ETIMEDOUT)
    ]

    private static let connectivityMessageFragments = [
        "could not connect to the server",
        "couldn't connect to the server",
        "couldn’t connect to the server",
        "cannot connect to the server",
        "server is unreachable",
        "network is unreachable",
        "network connection was lost",
        "socket is not connected",
        "socket was not connected",
        "not connected to the internet"
    ]
}
