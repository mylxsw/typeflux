import Foundation

extension TypefluxOfficialTranscriber {
    static func recordingCredential(
        from credentialProvider: @Sendable () async -> TypefluxCloudSessionCredential?
    ) async throws -> TypefluxCloudSessionCredential {
        guard let credential = await credentialProvider(), !credential.accessToken.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }
        return credential
    }

    /// Requests a replacement grant with a currently valid access token of the
    /// session that started the recording. A failover attempt can run long
    /// after the recording began, so the original access token may have
    /// expired; a recording whose session was logged out or replaced stops
    /// instead of continuing on (and billing) another account.
    static func fetchReplacementRoute(
        for recording: TypefluxCloudSessionCredential,
        credentialProvider: @Sendable () async -> TypefluxCloudSessionCredential?,
        routingClient: any TypefluxOfficialASRRoutingClient,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        guard let current = await credentialProvider(), !current.accessToken.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }
        guard current.session == recording.session else {
            throw TypefluxOfficialASRError.sessionChanged
        }
        try Task.checkCancellation()
        return try await routingClient.fetchRoute(accessToken: current.accessToken, scenario: scenario)
    }

    /// Runs an ASR session against the highest-priority cloud endpoint and
    /// retries against the next endpoint when an attempt fails before any
    /// audio was sent. Each attempt must take its own one-time grant (see
    /// `TypefluxOfficialASRGrantSequence`). Once audio has been sent
    /// (`TypefluxOfficialASRAdmittedStreamError`) the failure is final:
    /// mid-session migration is not supported because replaying the audio
    /// elsewhere could duplicate the transcript and its billing. A cancelled
    /// recording stops without another grant or attempt.
    static func runWithASRServerFailover<T>(
        preferredServers: [URL],
        serverRegistry: any TypefluxASRServerProviding = TypefluxASRServerRegistry.shared,
        operation: @Sendable (String) async throws -> T
    ) async throws -> T {
        let baseURLs = await serverRegistry.orderedServers(preferred: preferredServers)

        guard !baseURLs.isEmpty else {
            throw TypefluxOfficialASRError.connectionFailed("No Typeflux Cloud endpoint configured.")
        }

        var lastError: Error?
        for baseURL in baseURLs {
            try Task.checkCancellation()
            do {
                return try await operation(baseURL.absoluteString)
            } catch {
                if Task.isCancelled || TypefluxOfficialASRCancellation.isCancellation(error) {
                    throw CancellationError()
                }
                let admitted = error is TypefluxOfficialASRAdmittedStreamError
                let failure = (error as? TypefluxOfficialASRAdmittedStreamError)?.underlying ?? error
                if let refreshError = failure as? TypefluxOfficialASRGrantRefreshError {
                    throw refreshError.underlying
                }
                if TypefluxCloudASRDirectiveError.fromError(failure) != nil {
                    throw TypefluxCloudASRDirectiveError()
                }
                if failure is TypefluxCloudIntegratedRewriteError {
                    // A billing stop after the transcript arrived; the caller
                    // keeps the transcript.
                    throw failure
                }
                if let billingError = TypefluxCloudBillingError.fromError(failure) {
                    throw billingError
                }
                await serverRegistry.reportFailure(baseURL, error: failure)
                if admitted {
                    throw failure
                }
                lastError = failure
            }
        }
        throw lastError ?? TypefluxOfficialASRError.connectionFailed("All endpoints failed.")
    }
}

/// Maps a WebSocket receive failure to the error a recording reports.
/// Spelled out step by step: chaining the differently typed optionals with
/// `??` made the compiler wrap the first one, so the fallbacks never ran and
/// an unexpected close could end the recording as an empty success.
enum TypefluxOfficialASRReceiveFailure {
    static func classify(_ error: Error) -> Error {
        if let directive = TypefluxCloudASRDirectiveError.fromError(error) {
            return directive
        }
        if let billing = TypefluxCloudBillingError.fromError(error) {
            return billing
        }
        return TypefluxOfficialASRError.unexpectedClose
    }
}
