@testable import Typeflux
import XCTest

final class DefaultSenseVoiceFallbackTranscriberTests: XCTestCase {
    func testMissingBundledModelFailsWithoutStartingDownload() async {
        let modelManager = MissingFallbackModelManager()
        let transcriber = DefaultSenseVoiceFallbackTranscriber(modelManager: modelManager)

        do {
            _ = try await transcriber.transcribe(
                audioFile: AudioFile(fileURL: URL(fileURLWithPath: "/dev/null"), duration: 1)
            )
            XCTFail("Expected the bundled model to be unavailable")
        } catch {
            XCTAssertEqual((error as NSError).domain, LocalModelTranscriber.notPreparedErrorDomain)
        }

        XCTAssertEqual(modelManager.prepareCallCount, 0)
    }
}

private final class MissingFallbackModelManager: LocalSTTModelManaging {
    private(set) var prepareCallCount = 0

    func prepareModel(
        settingsStore _: SettingsStore,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        prepareCallCount += 1
    }

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        nil
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        false
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}

    func storagePath(for _: LocalSTTConfiguration) -> String {
        ""
    }
}
