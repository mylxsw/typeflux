@testable import Typeflux
import CoreFoundation
import XCTest

final class CloudDataSyncAPIServiceTests: XCTestCase {
    func testSyncBuildsAuthenticatedRequestAndDecodesResponse() async throws {
        let session = CloudDataSyncStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/sync")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["protocol_version"] as? Int, 2)
            XCTAssertEqual(object["dataset_generation"] as? Int, 3)
            XCTAssertEqual(object["device_id"] as? String, "33333333-3333-4333-8333-333333333333")
            let mutations = try XCTUnwrap(object["mutations"] as? [[String: Any]])
            let payload = try XCTUnwrap(mutations.first?["payload"] as? [String: Any])
            let count = try XCTUnwrap(payload["occurrence_count"] as? NSNumber)
            XCTAssertNotEqual(CFGetTypeID(count), CFBooleanGetTypeID())
            XCTAssertEqual(count.intValue, 1)
            for (key, expected) in [("zero", 0), ("one", 1), ("two", 2)] {
                let number = try XCTUnwrap(payload[key] as? NSNumber)
                XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID())
                XCTAssertEqual(number.intValue, expected)
            }
            let flag = try XCTUnwrap(payload["flag"] as? NSNumber)
            XCTAssertEqual(CFGetTypeID(flag), CFBooleanGetTypeID())
            XCTAssertTrue(flag.boolValue)
            return (
                Data(
                    #"{"code":"OK","data":{"dataset_generation":3,"reset_required":false,"snapshot":[],"cursor":4,"checkpoint":4,"has_more":false,"results":[],"changes":[]}}"#.utf8
                ),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let selector = CloudEndpointSelector(
            baseURLs: [URL(string: "https://api.example")!], prober: CloudDataSyncNoOpProber()
        )
        let service = CloudDataSyncAPIService(
            executor: CloudRequestExecutor(selector: selector, session: session)
        )

        let response = try await service.sync(
            token: "token-1",
            request: CloudSyncRequest(
                datasetGeneration: 3,
                deviceID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                cursor: 0, ackCursor: 0, checkpoint: 0,
                mutations: [CloudSyncMutation(
                    mutationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                    entityType: .vocabulary,
                    entityID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    operation: "create", baseRevision: 0,
                    payload: Data(
                        #"{"term":"Typeflux","source":"manual","created_at":"2026-08-27T00:00:00Z","occurrence_count":1,"zero":0,"one":1,"two":2,"flag":true}"#.utf8
                    )
                )]
            )
        )
        XCTAssertEqual(response.cursor, 4)
        XCTAssertFalse(response.hasMore)
    }

    func testResetBuildsDeleteRequestAndDecodesGeneration() async throws {
        let session = CloudDataSyncStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/sync")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            return (
                Data(#"{"code":"OK","data":{"dataset_generation":5}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let selector = CloudEndpointSelector(
            baseURLs: [URL(string: "https://api.example")!], prober: CloudDataSyncNoOpProber()
        )
        let service = CloudDataSyncAPIService(
            executor: CloudRequestExecutor(selector: selector, session: session)
        )
        let response = try await service.reset(token: "token-1")
        XCTAssertEqual(response.datasetGeneration, 5)
    }
}

private actor CloudDataSyncStubSession: CloudHTTPSession {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var handler: Handler?
    func setHandler(_ handler: @escaping Handler) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let handler else { throw URLError(.badServerResponse) }
        return try await handler(request)
    }
}

private struct CloudDataSyncNoOpProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        CloudEndpointProbeResult(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}
