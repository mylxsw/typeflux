@testable import Typeflux
import XCTest

final class ProjectVocabularyScannerTests: XCTestCase {
    func testScanContextDirectoriesExtractsProjectSpecificTermsFromCodexAndClaude() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-vocabulary-\(UUID().uuidString)", isDirectory: true)
        let codexRoot = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let claudeRoot = tempRoot.appendingPathComponent(".claude", isDirectory: true)

        try FileManager.default.createDirectory(
            at: codexRoot.appendingPathComponent("projects/typeflux", isDirectory: true),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: claudeRoot.appendingPathComponent("projects/whisperkit", isDirectory: true),
            withIntermediateDirectories: true,
        )

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let codexFile = codexRoot.appendingPathComponent("projects/typeflux/notes.md")
        let claudeFile = claudeRoot.appendingPathComponent("projects/whisperkit/context.txt")

        try """
        Prefer TypefluxCloud and Qwen3-ASR when the workspace mentions WhisperKit.
        Avoid generic project instructions.
        """
        .write(to: codexFile, atomically: true, encoding: .utf8)

        try """
        Typeflux agents often call WhisperKit and DoubaoRealtime in this repository.
        """
        .write(to: claudeFile, atomically: true, encoding: .utf8)

        let discovery = ProjectVocabularyScanner.scanContextDirectories([codexRoot, claudeRoot])

        XCTAssertEqual(discovery.roots.count, 2)
        XCTAssertTrue(discovery.terms.contains("TypefluxCloud"))
        XCTAssertTrue(discovery.terms.contains("Qwen3-ASR"))
        XCTAssertTrue(discovery.terms.contains("WhisperKit"))
        XCTAssertTrue(discovery.terms.contains("DoubaoRealtime"))
        XCTAssertFalse(discovery.terms.contains(where: { $0.lowercased() == "project" }))
        XCTAssertFalse(discovery.terms.contains(where: { $0.lowercased() == "instructions" }))
    }

    func testCandidateTermsAllowsPathBasedLowercaseIdentifiersButFiltersPlainLowercaseText() {
        let pathTerms = ProjectVocabularyScanner.candidateTerms(
            in: "projects/typeflux/workspace-config",
            allowPlainLowercase: true,
        )
        let contentTerms = ProjectVocabularyScanner.candidateTerms(
            in: "plain lowercase words should stay out",
            allowPlainLowercase: false,
        )

        XCTAssertTrue(pathTerms.contains("typeflux"))
        XCTAssertTrue(pathTerms.contains("workspace-config"))
        XCTAssertTrue(contentTerms.isEmpty)
    }
}
