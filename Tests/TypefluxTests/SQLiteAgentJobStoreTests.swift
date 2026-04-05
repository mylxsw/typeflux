@testable import Typeflux
import XCTest

final class SQLiteAgentJobStoreTests: XCTestCase {
    private var testDir: URL!
    private var store: SQLiteAgentJobStore!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteAgentJobStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = SQLiteAgentJobStore(baseDir: testDir)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: testDir)
        testDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeJob(
        id: UUID = UUID(),
        status: AgentJobStatus = .completed,
        title: String? = nil,
        prompt: String = "Test prompt",
        resultText: String? = "Result",
        steps: [AgentJobStep] = [],
        createdAt: Date = Date(),
    ) -> AgentJob {
        AgentJob(
            id: id,
            createdAt: createdAt,
            completedAt: status != .running ? Date() : nil,
            status: status,
            title: title,
            userPrompt: prompt,
            resultText: resultText,
            steps: steps,
        )
    }

    // MARK: - Save and Fetch

    func testSaveAndFetchJob() async throws {
        let jobID = UUID()
        let job = makeJob(id: jobID, title: "Test Title", prompt: "Hello")

        try await store.save(job)

        let fetched = try await store.job(id: jobID)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, jobID)
        XCTAssertEqual(fetched?.title, "Test Title")
        XCTAssertEqual(fetched?.userPrompt, "Hello")
        XCTAssertEqual(fetched?.status, .completed)
    }

    func testSaveUpdatesExistingJob() async throws {
        let jobID = UUID()
        var job = makeJob(id: jobID, status: .running, prompt: "Initial")
        try await store.save(job)

        job.status = .completed
        job.title = "Updated Title"
        job.resultText = "Final result"
        try await store.save(job)

        let fetched = try await store.job(id: jobID)
        XCTAssertEqual(fetched?.status, .completed)
        XCTAssertEqual(fetched?.title, "Updated Title")
        XCTAssertEqual(fetched?.resultText, "Final result")

        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testFetchNonExistentJobReturnsNil() async throws {
        let fetched = try await store.job(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - List

    func testListEmptyStore() async throws {
        let jobs = try await store.list(limit: 10, offset: 0)
        XCTAssertTrue(jobs.isEmpty)
    }

    func testListReturnsJobsOrderedByCreatedAtDesc() async throws {
        let older = makeJob(
            prompt: "First",
            createdAt: Date(timeIntervalSinceNow: -100),
        )
        let newer = makeJob(
            prompt: "Second",
            createdAt: Date(timeIntervalSinceNow: -10),
        )

        try await store.save(older)
        try await store.save(newer)

        let jobs = try await store.list(limit: 10, offset: 0)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].userPrompt, "Second")
        XCTAssertEqual(jobs[1].userPrompt, "First")
    }

    func testListWithLimit() async throws {
        for i in 0 ..< 5 {
            try await store.save(makeJob(
                prompt: "Job \(i)",
                createdAt: Date(timeIntervalSinceNow: Double(-i * 10)),
            ))
        }

        let jobs = try await store.list(limit: 2, offset: 0)
        XCTAssertEqual(jobs.count, 2)
    }

    func testListWithOffset() async throws {
        for i in 0 ..< 5 {
            try await store.save(makeJob(
                prompt: "Job \(i)",
                createdAt: Date(timeIntervalSinceNow: Double(-i * 10)),
            ))
        }

        let jobs = try await store.list(limit: 10, offset: 3)
        XCTAssertEqual(jobs.count, 2)
    }

    func testListWithOffsetBeyondCount() async throws {
        try await store.save(makeJob())
        let jobs = try await store.list(limit: 10, offset: 100)
        XCTAssertTrue(jobs.isEmpty)
    }

    // MARK: - Delete

    func testDeleteJob() async throws {
        let jobID = UUID()
        try await store.save(makeJob(id: jobID))

        try await store.delete(id: jobID)

        let fetched = try await store.job(id: jobID)
        XCTAssertNil(fetched)
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func testDeleteNonExistentJobDoesNotThrow() async throws {
        try await store.delete(id: UUID())
    }

    // MARK: - Clear

    func testClearRemovesAllJobs() async throws {
        for _ in 0 ..< 3 {
            try await store.save(makeJob())
        }
        let countBefore = try await store.count()
        XCTAssertEqual(countBefore, 3)

        try await store.clear()
        let countAfter = try await store.count()
        XCTAssertEqual(countAfter, 0)
    }

    func testClearOnEmptyStoreDoesNotThrow() async throws {
        try await store.clear()
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Count

    func testCountEmpty() async throws {
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func testCountMultiple() async throws {
        for _ in 0 ..< 4 {
            try await store.save(makeJob())
        }
        let count = try await store.count()
        XCTAssertEqual(count, 4)
    }

    // MARK: - Steps Persistence

    func testStepsArePersisted() async throws {
        let jobID = UUID()
        let tc = AgentJobToolCall(
            id: "tc-1", name: "search", argumentsJSON: #"{"q":"swift"}"#,
            resultContent: "Found results", isError: false,
        )
        let step = AgentJobStep(stepIndex: 0, toolCalls: [tc], assistantText: "Searching...", durationMs: 200)
        let job = makeJob(id: jobID, steps: [step])

        try await store.save(job)

        let fetched = try await store.job(id: jobID)
        XCTAssertEqual(fetched?.steps.count, 1)
        XCTAssertEqual(fetched?.steps[0].stepIndex, 0)
        XCTAssertEqual(fetched?.steps[0].toolCalls.count, 1)
        XCTAssertEqual(fetched?.steps[0].toolCalls[0].name, "search")
        XCTAssertEqual(fetched?.steps[0].assistantText, "Searching...")
        XCTAssertEqual(fetched?.steps[0].durationMs, 200)
    }

    func testEmptyStepsArePersisted() async throws {
        let jobID = UUID()
        let job = makeJob(id: jobID, steps: [])

        try await store.save(job)

        let fetched = try await store.job(id: jobID)
        XCTAssertEqual(fetched?.steps.count, 0)
    }

    // MARK: - Optional Fields

    func testNullableFieldsPersistNil() async throws {
        let jobID = UUID()
        let job = AgentJob(
            id: jobID,
            status: .running,
            userPrompt: "test",
        )

        try await store.save(job)

        let fetched = try await store.job(id: jobID)
        XCTAssertNotNil(fetched)
        XCTAssertNil(fetched?.completedAt)
        XCTAssertNil(fetched?.title)
        XCTAssertNil(fetched?.selectedText)
        XCTAssertNil(fetched?.resultText)
        XCTAssertNil(fetched?.errorMessage)
        XCTAssertNil(fetched?.totalDurationMs)
        XCTAssertNil(fetched?.outcomeType)
    }

    func testAllFieldsPopulated() async throws {
        let jobID = UUID()
        let job = AgentJob(
            id: jobID,
            createdAt: Date(),
            completedAt: Date(),
            status: .failed,
            title: "Failed Job",
            userPrompt: "Do something",
            selectedText: "selected",
            resultText: nil,
            errorMessage: "Something went wrong",
            steps: [],
            totalDurationMs: 5000,
            outcomeType: "error",
        )

        try await store.save(job)

        let fetched = try await store.job(id: jobID)
        XCTAssertEqual(fetched?.status, .failed)
        XCTAssertEqual(fetched?.title, "Failed Job")
        XCTAssertEqual(fetched?.selectedText, "selected")
        XCTAssertEqual(fetched?.errorMessage, "Something went wrong")
        XCTAssertEqual(fetched?.totalDurationMs, 5000)
        XCTAssertEqual(fetched?.outcomeType, "error")
    }

    // MARK: - Notification

    func testSavePostsNotification() async throws {
        let expectation = expectation(forNotification: .agentJobStoreDidChange, object: nil)
        try await store.save(makeJob())
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testDeletePostsNotification() async throws {
        let jobID = UUID()
        try await store.save(makeJob(id: jobID))

        let expectation = expectation(forNotification: .agentJobStoreDidChange, object: nil)
        try await store.delete(id: jobID)
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testClearPostsNotification() async throws {
        try await store.save(makeJob())

        let expectation = expectation(forNotification: .agentJobStoreDidChange, object: nil)
        try await store.clear()
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Persistence Across Instances

    func testDataPersistsAcrossInstances() async throws {
        let jobID = UUID()
        try await store.save(makeJob(id: jobID, title: "Persistent"))

        // Create a new store instance pointing to the same directory
        let store2 = SQLiteAgentJobStore(baseDir: testDir)
        let fetched = try await store2.job(id: jobID)
        XCTAssertEqual(fetched?.title, "Persistent")
    }

    // MARK: - Unicode and Special Characters

    func testUnicodeContentPersisted() async throws {
        let jobID = UUID()
        let job = AgentJob(
            id: jobID,
            status: .completed,
            title: "翻译邮件为日语 🇯🇵",
            userPrompt: "请帮我翻译这封邮件",
            selectedText: "こんにちは",
            resultText: "翻译完成 ✅",
        )
        try await store.save(job)

        let fetched = try await store.job(id: jobID)
        XCTAssertEqual(fetched?.title, "翻译邮件为日语 🇯🇵")
        XCTAssertEqual(fetched?.userPrompt, "请帮我翻译这封邮件")
        XCTAssertEqual(fetched?.selectedText, "こんにちは")
        XCTAssertEqual(fetched?.resultText, "翻译完成 ✅")
    }
}
