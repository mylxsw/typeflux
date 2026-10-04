import CryptoKit
import Foundation

extension AskSkillInstaller {
    struct RemoteFile: Equatable {
        var path: String
        var size: Int
        var mode = "100644"
        var sha: String = ""
    }

    func defaultBranch(_ target: Target) async throws -> String {
        let data = try await get(apiBase.appendingPathComponent("repos/\(target.owner)/\(target.repository)"))
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branch = body["default_branch"] as? String, !branch.isEmpty else {
            throw AskLocalError.message(L("ask.skills.install.notFound"))
        }
        return branch
    }

    func resolveCommit(_ target: Target, ref: String) async throws -> String {
        let data = try await get(apiBase.appendingPathComponent("repos/\(target.owner)/\(target.repository)/commits/\(ref)"))
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = body["sha"] as? String, Self.isSHA(sha) else {
            throw AskLocalError.message(L("ask.skills.install.invalidSource"))
        }
        return sha
    }

    func tree(_ target: Target, commit: String) async throws -> [RemoteFile] {
        let endpoint = apiBase.appendingPathComponent("repos/\(target.owner)/\(target.repository)/git/trees/\(commit)")
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let data = try await get(url.url!, maximumBytes: 8_000_000)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let truncated = body["truncated"] as? Bool,
              let entries = body["tree"] as? [[String: Any]] else {
            throw AskLocalError.message(L("ask.skills.install.invalidSource"))
        }
        guard !truncated else { throw AskLocalError.message(L("ask.skills.install.truncated")) }
        var paths = Set<String>()
        return try entries.compactMap { entry in
            guard let path = entry["path"] as? String,
                  !path.hasPrefix("/"), !path.contains("\\"),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                          && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                  }), paths.insert(path.lowercased().precomposedStringWithCanonicalMapping).inserted else {
                throw AskLocalError.message(L("ask.skills.install.unsafeResource"))
            }
            if entry["type"] as? String == "tree", entry["mode"] as? String == "040000" { return nil }
            guard let mode = entry["mode"] as? String else {
                throw AskLocalError.message(L("ask.skills.install.invalidSource"))
            }
            if !["100644", "100755"].contains(mode) { return RemoteFile(path: path, size: 0, mode: mode) }
            guard entry["type"] as? String == "blob", let size = entry["size"] as? Int, size >= 0,
                  let sha = entry["sha"] as? String, Self.isSHA(sha) else {
                throw AskLocalError.message(L("ask.skills.install.invalidSource"))
            }
            return RemoteFile(path: path, size: size, mode: mode, sha: sha)
        }
    }

    func download(_ target: Target, commit: String, file: RemoteFile) async throws -> Data {
        let url = rawBase.appendingPathComponent("\(target.owner)/\(target.repository)/\(commit)/\(file.path)")
        let data = try await get(url, maximumBytes: Self.maximumFileBytes)
        let blob = Data("blob \(data.count)\0".utf8) + data
        let sha = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        guard data.count == file.size, sha == file.sha else {
            throw AskLocalError.message(L("ask.skills.install.invalidSource"))
        }
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func get(_ url: URL, maximumBytes: Int = 1_000_000) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response, maximumBytes: maximumBytes)
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw AskLocalError.message(L("ask.skills.install.tooLarge"))
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AskLocalError {
            throw error
        } catch {
            throw AskLocalError.message(L("ask.skills.install.network"))
        }
    }

    private func validate(_ response: URLResponse, maximumBytes: Int) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AskLocalError.message(L("ask.skills.install.network"))
        }
        switch http.statusCode {
        case 200..<300: break
        case 404: throw AskLocalError.message(L("ask.skills.install.notFound"))
        case 403, 429: throw AskLocalError.message(L("ask.skills.install.rateLimited"))
        default: throw AskLocalError.message(L("ask.skills.install.network"))
        }
        guard response.expectedContentLength <= maximumBytes else {
            throw AskLocalError.message(L("ask.skills.install.tooLarge"))
        }
    }

}
