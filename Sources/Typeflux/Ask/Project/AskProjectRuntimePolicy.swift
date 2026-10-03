import Foundation

enum AskProjectRuntimeError: Error, Equatable {
    case disabled, unavailable, invalidRequest, approvalRequired, denied, unknownLease
    case installationUnavailable, capacity, closed, inputFull, invalidCursor, portUnavailable
}

struct AskProjectLaunchRequest: Codable, Equatable {
    enum Terminal: String, Codable { case pipe, pty }
    enum Network: String, Codable { case offline, dependencyInstallation }
    var script: String
    var arguments: [String] = []
    var cwd = "."
    var environment: [String: String] = [:]
    var terminal: Terminal = .pipe
    var network: Network = .offline
    var timeout: TimeInterval = 300
    /// nil is a command; zero asks the kernel to allocate a loopback port.
    var servicePort: UInt16?
    var readinessTimeout: TimeInterval = 10
}

enum AskProjectRuntimePolicy {
    static let version = "project-python-single-process-v1"

    static func interpreter() throws -> String {
        let path = AskCodeSandbox.realPath("/Library/Developer/CommandLineTools/usr/bin/python3")
        guard path.hasPrefix("/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/"),
              FileManager.default.isExecutableFile(atPath: path),
              FileManager.default.isExecutableFile(atPath: AskCodeSandbox.sandboxExec) else {
            throw AskProjectRuntimeError.unavailable
        }
        return path
    }

    static func validate(_ request: AskProjectLaunchRequest) throws {
        guard request.network == .offline else { throw AskProjectRuntimeError.installationUnavailable }
        _ = try AskProjectFileAccess.parts(request.script)
        if request.cwd != "." {
            _ = try AskProjectFileAccess.parts(request.cwd)
        }
        let allowed = Set(["LANG", "LC_ALL", "TERM"])
        guard request.timeout.isFinite, (0.05 ... 3600).contains(request.timeout),
              request.readinessTimeout.isFinite, (0.05 ... 30).contains(request.readinessTimeout),
              request.arguments.count <= 128,
              request.arguments.reduce(0, { $0 + $1.utf8.count }) <= 32768,
              request.arguments.allSatisfy({ !$0.contains("\0") }),
              Set(request.environment.keys).isSubset(of: allowed),
              request.environment.values.allSatisfy({ $0.utf8.count <= 256 && !$0.contains("\0") }),
              request.servicePort.map({ $0 == 0 || $0 >= 1024 }) ?? true else {
            throw AskProjectRuntimeError.invalidRequest
        }
    }

    static func environment(_ request: AskProjectLaunchRequest, home: String, temporary: String,
                            port: AskProjectPortLease?) -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                      "HOME": home, "TMPDIR": temporary, "PYTHONDONTWRITEBYTECODE": "1",
                      "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1"]
        result.merge(request.environment) { _, new in new }
        if let port {
            result["TYPEFLUX_LISTEN_FD"] = "3"
            result["TYPEFLUX_PORT"] = String(port.port)
            result["TYPEFLUX_READY_TOKEN"] = port.token
        }
        return result
    }

    /// Deny-by-default Seatbelt policy. There is no network installation fallback.
    /// Fork/spawn and IPC remain denied; exec can only replace the single owned
    /// process with the preinstalled Python runtime, under the same sandbox.
    static func profile(project: String, temporary: String, interpreter: String,
                        terminal: String?, port: AskProjectPortLease?) -> String {
        let runtime = (interpreter as NSString).deletingLastPathComponent as NSString
        let runtimeRoot = runtime.deletingLastPathComponent
        let roots = ["/System/Library", "/usr/lib", "/usr/share/locale", "/usr/share/zoneinfo",
                     runtimeRoot, project, temporary]
        let quote = AskCodeSandbox.quoted
        var ancestors = Set(["/var", "/tmp", "/etc"])
        for root in roots {
            var parent = (root as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "/" {
                ancestors.insert(parent); parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var profile = """
        (version 1)
        (deny default)
        (allow process-exec (subpath \(quote(runtimeRoot))))
        (allow sysctl-read)
        (allow process-info-pidinfo (target self))
        (allow file-read-metadata \(ancestors.sorted().map { "(literal \(quote($0)))" }.joined(separator: " ")))
        (allow file-read* \(roots.map { "(subpath \(quote($0)))" }.joined(separator: " "))
          (literal "/") (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))
        (allow file-write* (subpath \(quote(project))) (subpath \(quote(temporary))) (literal "/dev/null"))
        (deny file-write* (literal \(quote(project))) (literal \(quote(temporary))))
        """
        if let terminal {
            profile += "\n(allow file-read* file-write-data file-ioctl (literal \(quote(terminal))))"
        }
        if let port {
            // Bind is deliberately denied even for this port: only the host's
            // inherited IPv4 loopback listener can receive connections.
            profile += "\n(allow network-inbound (local tcp \"localhost:\(port.port)\"))"
        }
        return profile
    }
}
