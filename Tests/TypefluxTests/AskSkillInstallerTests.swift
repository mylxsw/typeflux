import CryptoKit
import Foundation
@testable import Typeflux
import XCTest

/// Serves a fake GitHub repository: the repository API, the recursive tree API and raw files.
final class GitHubStubProtocol: URLProtocol, @unchecked Sendable {
    struct Entry {
        var path: String; var content: String; var mode = "100644"; var type =
            "blob"; var size: Int?; var download: String?
    }

    nonisolated(unsafe) static var entries: [Entry] = []
    static let commit = String(repeating: "a", count: 40)
    nonisolated(unsafe) static var truncated = false
    nonisolated(unsafe) static var commitResponse: String?
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    nonisolated(unsafe) static var networkError: URLError?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [URL] = []

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        Self.requests.append(url)
        if let error = Self.networkError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var status = Self.status
        var body = Data()
        if status == 200 {
            switch url.host {
            case "api.github.com" where url.path == "/repos/owner/repo":
                body = Data(#"{"default_branch":"main"}"#.utf8)
            case "api.github.com" where url.path.hasPrefix("/repos/owner/repo/commits/"):
                body = Self.jsonData(["sha": Self.commitResponse ?? Self.commit])
            case "api.github.com" where url.path == "/repos/owner/repo/git/trees/" + Self.commit:
                let tree = Self.entries.map { entry -> [String: Any] in
                    let data = Data(entry.content.utf8)
                    let blob = Data("blob \(data.count)\0".utf8) + data
                    let sha = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
                    return ["path": entry.path, "mode": entry.mode, "type": entry.type,
                            "size": entry.size ?? data.count, "sha": sha]
                }
                body = Self.jsonData(["tree": tree, "truncated": Self.truncated])
            case "raw.githubusercontent.com":
                let path = url.path.split(separator: "/").dropFirst(3).joined(separator: "/")
                    .removingPercentEncoding ?? ""
                if let entry = Self.entries
                    .first(where: { $0.path == path }) {
                    body = Data((entry.download ?? entry.content).utf8)
                } else {
                    status = 404
                }
            default:
                status = 404
            }
        }
        body = Self.responses[url.path] ?? body
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func jsonData(_ object: Any) -> Data {
        do { return try JSONSerialization.data(withJSONObject: object) } catch {
            XCTFail("Invalid GitHub fixture: " + error.localizedDescription)
            return Data()
        }
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class AskSkillInstallerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-install-\(UUID().uuidString)")
        GitHubStubProtocol.entries = []
        GitHubStubProtocol.status = 200
        GitHubStubProtocol.truncated = false
        GitHubStubProtocol.commitResponse = nil
        GitHubStubProtocol.responses = [:]
        GitHubStubProtocol.networkError = nil
        GitHubStubProtocol.requests = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    var library: AskSkillLibrary {
        AskSkillLibrary(userDirectory: root)
    }

    func installer() -> AskSkillInstaller {
        AskSkillInstaller(library: library, session: GitHubStubProtocol.session,
                          now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    func skill(_ name: String, _ body: String = "Do the task carefully.") -> String {
        "---\nname: \(name)\ndescription: \(name) skill\n---\n\(body)\n"
    }

    func assertError(_ key: String, file: StaticString = #filePath, line: UInt = #line,
                     _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(key)", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, L(key), file: file, line: line)
        }
    }

    // MARK: - URL parsing

    func testParsesRepositoryFolderAndFileLinks() throws {
        XCTAssertEqual(try AskSkillInstaller.parse("https://github.com/owner/repo"),
                       .init(owner: "owner", repository: "repo", ref: nil, path: ""))
        XCTAssertEqual(try AskSkillInstaller.parse(" github.com/owner/repo.git "),
                       .init(owner: "owner", repository: "repo", ref: nil, path: ""))
        XCTAssertEqual(try AskSkillInstaller.parse("https://github.com/owner/repo/tree/main/skills/pdf"),
                       .init(owner: "owner", repository: "repo", ref: "main", path: "skills/pdf"))
        XCTAssertEqual(try AskSkillInstaller.parse("https://www.github.com/owner/repo/blob/v1/skills/pdf/SKILL.md"),
                       .init(owner: "owner", repository: "repo", ref: "v1", path: "skills/pdf"))
        XCTAssertEqual(try AskSkillInstaller.parse("https://github.com/owner/repo/blob/main/SKILL.md"),
                       .init(owner: "owner", repository: "repo", ref: "main", path: ""))
    }

    func testRejectsLinksOutsideGitHubOrWithUnsafePaths() {
        for bad in [
            "https://gitlab.com/owner/repo",
            "https://github.com/owner",
            "https://github.com/owner/repo/issues/1",
            "https://github.com/owner/repo/blob/main/README.md",
            "https://github.com/owner/repo/tree/main/../etc",
            "https://github.com/owner/repo/tree/main/.hidden",
            "https://github.com/ow ner/repo",
            "not a url",
            "http://github.com/owner/repo",
            "https://someone@github.com/owner/repo",
            "https://github.com/owner/repo?ref=bad",
            "https://github.com/owner/repo/tree/..",
            "https://github.com/owner/repo/tree/main/a%0Ab"
        ] {
            XCTAssertThrowsError(try AskSkillInstaller.parse(bad), bad) { error in
                XCTAssertEqual(error.localizedDescription, L("ask.skills.install.invalidURL"), bad)
            }
        }
    }

    func testSkillFoldersAssignFilesToTheDeepestSkill() {
        let files = [
            "SKILL.md",
            "README.md",
            "skills/a/SKILL.md",
            "skills/a/x.py",
            "skills/a/b/SKILL.md",
            "skills/a/b/y.md"
        ]
        .map { AskSkillInstaller.RemoteFile(path: $0, size: 1) }
        let folders = AskSkillInstaller.skillFolders(in: files, under: "")
        XCTAssertEqual(folders, ["", "skills/a", "skills/a/b"])
        XCTAssertEqual(AskSkillInstaller.skillFolders(in: files, under: "skills/a"), ["skills/a", "skills/a/b"])
        XCTAssertTrue(AskSkillInstaller.belongs("README.md", to: "", otherSkills: folders))
        XCTAssertFalse(AskSkillInstaller.belongs("skills/a/x.py", to: "", otherSkills: folders))
        XCTAssertTrue(AskSkillInstaller.belongs("skills/a/x.py", to: "skills/a", otherSkills: folders))
        XCTAssertTrue(AskSkillInstaller.belongs("skills/a/b/y.md", to: "skills/a/b", otherSkills: folders))
        XCTAssertEqual(AskSkillInstaller.relativePath("skills/a/x.py", in: "skills/a"), "x.py")
        XCTAssertEqual(AskSkillInstaller.relativePath("x.py", in: ""), "x.py")
    }

    // MARK: - Install

    func testInstallsEverySkillInARepositoryWithItsFilesAndSource() async throws {
        GitHubStubProtocol.entries = [
            .init(path: "README.md", content: "# Repo"),
            .init(path: "skills/pdf-tools/SKILL.md", content: skill("pdf-tools")),
            .init(path: "skills/pdf-tools/scripts/extract.py", content: "print('hi')"),
            .init(path: "skills/pdf-tools/.env", content: "SECRET=1"),
            .init(path: "skills/reviewer/SKILL.md", content: skill("Reviewer")),
            .init(path: "vendor", content: "", mode: "160000", type: "commit")
        ]
        let result = try await installer().install(from: "https://github.com/owner/repo")
        XCTAssertEqual(result, .init(installed: ["pdf-tools", "reviewer"], replaced: []))

        let pdf = root.appendingPathComponent("pdf-tools")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.appendingPathComponent("scripts/extract.py").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.appendingPathComponent(".env").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.appendingPathComponent("link").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path))

        let installed = library.skills().filter { $0.directory != nil }
        XCTAssertEqual(installed.map(\.name), ["pdf-tools", "reviewer"])
        let source = try XCTUnwrap(library.source(of: installed[0]))
        XCTAssertEqual(source.repository, "owner/repo")
        XCTAssertEqual(source.ref, "main")
        XCTAssertEqual(source.commit, GitHubStubProtocol.commit)
        XCTAssertEqual(source.schemaVersion, 2)
        XCTAssertNotNil(source.installationID)
        XCTAssertEqual(source.resources?.map(\.path), ["SKILL.md", "scripts/extract.py"])
        XCTAssertTrue(source.resources?.allSatisfy { $0.sha256.count == 64 } == true)
        XCTAssertEqual(source.declaredPermissions, [])
        XCTAssertEqual(source.path, "skills/pdf-tools")
        XCTAssertEqual(source.installedAt, Date(timeIntervalSince1970: 1_790_000_000))
        // The source file stays out of the skill's file list shown to the model.
        XCTAssertFalse(try library.load("pdf-tools").contains(AskSkillSource.fileName))
        XCTAssertTrue(try library.load("pdf-tools").contains("scripts"))
    }

    func testFolderLinkInstallsOneSkillAndReinstallUpdatesIt() async throws {
        GitHubStubProtocol.entries = [
            .init(path: "skills/pdf-tools/SKILL.md", content: skill("pdf-tools", "Version one.")),
            .init(path: "skills/other/SKILL.md", content: skill("other"))
        ]
        let url = "https://github.com/owner/repo/tree/main/skills/pdf-tools"
        let first = try await installer().install(from: url)
        XCTAssertEqual(first.installed, ["pdf-tools"])
        XCTAssertFalse(GitHubStubProtocol.requests.contains { $0.path == "/repos/owner/repo" },
                       "An explicit ref must not look up the default branch")

        GitHubStubProtocol.entries[0].content = skill("pdf-tools", "Version two.")
        let second = try await installer().install(from: url)
        XCTAssertEqual(second, .init(installed: ["pdf-tools"], replaced: ["pdf-tools"]))
        XCTAssertTrue(try library.load("pdf-tools").contains("Version two."))
        XCTAssertEqual(library.userSkillNames(), ["pdf-tools"])
    }

    func testRootSkillExcludesNestedSkillFiles() async throws {
        GitHubStubProtocol.entries = [
            .init(path: "SKILL.md", content: skill("root-skill")),
            .init(path: "notes.md", content: "Root notes"),
            .init(path: "nested/SKILL.md", content: skill("nested")),
            .init(path: "nested/data.csv", content: "a,b")
        ]
        _ = try await installer().install(from: "https://github.com/owner/repo/blob/main/SKILL.md")
        let rootSkill = root.appendingPathComponent("root-skill")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootSkill.appendingPathComponent("notes.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootSkill.appendingPathComponent("nested").path))
        XCTAssertEqual(library.userSkillNames(), ["nested", "root-skill"])
    }

    func testFailuresLeaveNothingInstalled() async {
        GitHubStubProtocol.entries = [.init(path: "README.md", content: "no skills")]
        await assertError("ask.skills.install.notFound") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }

        GitHubStubProtocol.entries = [.init(path: "s/SKILL.md", content: "---\nname: empty\n---\n")]
        await assertError("ask.skills.install.invalidSkill") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }

        GitHubStubProtocol.entries = [.init(path: "s/SKILL.md", content: skill("big")),
                                      .init(
                                          path: "s/blob.bin",
                                          content: String(repeating: "x", count: AskSkillInstaller.maximumFileBytes + 1)
                                      )]
        await assertError("ask.skills.install.tooLarge") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }

        GitHubStubProtocol.entries = (0 ... AskSkillInstaller.maximumSkillsPerInstall).map {
            .init(path: "s\($0)/SKILL.md", content: skill("s\($0)"))
        }
        await assertError("ask.skills.install.tooMany") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }

        GitHubStubProtocol.status = 404
        await assertError("ask.skills.install.notFound") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        GitHubStubProtocol.status = 403
        await assertError("ask.skills.install.rateLimited") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        GitHubStubProtocol.status = 500
        await assertError("ask.skills.install.network") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }

        XCTAssertTrue(library.userSkillNames().isEmpty)
    }

    func testRemovesInstalledSkillsButNotBuiltIns() async throws {
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("removable"))]
        _ = try await installer().install(from: "github.com/owner/repo")
        let installed = try XCTUnwrap(library.skills().first { $0.name == "removable" })
        try library.remove(installed)
        XCTAssertTrue(library.userSkillNames().isEmpty)

        let builtin = try XCTUnwrap(library.skills().first { $0.directory == nil })
        XCTAssertNil(library.source(of: builtin))
        XCTAssertThrowsError(try library.remove(builtin)) { error in
            XCTAssertEqual(error.localizedDescription, L("ask.skills.install.cannotRemove"))
        }
    }
}
