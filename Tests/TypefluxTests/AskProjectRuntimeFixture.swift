import Foundation
@testable import Typeflux
import XCTest

@MainActor final class AskProjectRuntimeFixture {
    let base: URL
    let source: URL
    let projects: AskProjectWorkspace
    let scope = AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "run")
    let approvals = AskApprovalStore()
    let notifications = NotificationCenter()
    var runtime: AskProjectRuntime!
    var workspace: AskWorkspaceRef!
    var roots: [String]

    init(_ script: String = "print('hello')", enabled: Bool = true) throws {
        base = URL(fileURLWithPath: AskProjectFileAccess.normalizedRoot(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        ))
        source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: source.appendingPathComponent("main.py"))
        roots = [source.path]
        projects = AskProjectWorkspace(storageURL: base.appendingPathComponent("workspaces"))
        workspace = try projects.open(root: source.path, scope: scope, authorizedRoots: roots)
        runtime = try AskProjectRuntime(
            storageURL: base.appendingPathComponent("runtime"),
            projects: projects,
            enabled: enabled,
            notificationCenter: notifications
        )
    }

    func close() {
        runtime?.shutdown(); runtime = nil
        try? FileManager.default.removeItem(at: base)
    }

    func grant(_ request: AskProjectLaunchRequest, call: String) throws -> String {
        let approval = try runtime.approval(for: request, workspace: workspace,
                                            scope: scope, authorizedRoots: roots, callId: call)
        return try XCTUnwrap(approvals.issue(approval))
    }

    func launch(_ request: AskProjectLaunchRequest = .init(script: "main.py"),
                mutation: (() throws -> Void)? = nil) throws -> AskProjectRuntimeLease {
        let call = UUID().uuidString, id = try grant(request, call: call)
        return try runtime.start(request, workspace: workspace, scope: scope, authorizedRoots: { self.roots },
                                 callId: call, grantId: id, approvals: approvals, beforeCopyValidation: mutation)
    }

    func input(_ text: String, lease: AskProjectRuntimeLease, eof: Bool = false) throws {
        let data = Data(text.utf8), call = UUID().uuidString
        let request = try runtime.inputApproval(lease, scope: scope, data: data, eof: eof, callId: call)
        let grant = try XCTUnwrap(approvals.issue(request))
        try runtime.send(
            data,
            eof: eof,
            lease: lease,
            scope: scope,
            callId: call,
            grantId: grant,
            approvals: approvals
        )
    }

    func wait(_ lease: AskProjectRuntimeLease, ready: Bool = false) async throws -> AskProjectProcessStatus {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            let status = try runtime.status(lease, scope: scope)
            if ready, status.state == .ready {
                return status
            }
            if ![.running, .starting, .ready].contains(status.state) {
                return status
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Process did not reach expected state")
        try runtime.stop(lease, scope: scope)
        return try runtime.status(lease, scope: scope)
    }

    func text(_ lease: AskProjectRuntimeLease) throws -> String {
        let output = try runtime.output(lease, scope: scope, cursor: 0)
        return try XCTUnwrap(String(data: output.data, encoding: .utf8))
    }
}
