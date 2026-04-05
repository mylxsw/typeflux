import Foundation

/// Protocol for persistent storage of agent jobs.
protocol AgentJobStore: Sendable {
    /// Save or update a job.
    func save(_ job: AgentJob) async throws
    /// List jobs with optional pagination.
    func list(limit: Int, offset: Int) async throws -> [AgentJob]
    /// Fetch a single job by ID.
    func job(id: UUID) async throws -> AgentJob?
    /// Delete a job by ID.
    func delete(id: UUID) async throws
    /// Delete all jobs.
    func clear() async throws
    /// Count of all jobs.
    func count() async throws -> Int
}
