import Darwin
import Foundation

/// Owns all pipe/PTY ends. Only stdio and an optional loopback listener are
/// inherited. In particular, D01 source descriptors are never passed here.
final class AskProjectProcessIO {
    private(set) var reader: Int32 = -1
    private(set) var writer: Int32 = -1
    private var childInput: Int32 = -1
    private var childOutput: Int32 = -1
    private(set) var terminalPath: String?

    init(terminal: AskProjectLaunchRequest.Terminal) throws {
        do {
            if terminal == .pty {
                var primary: Int32 = -1, secondary: Int32 = -1
                var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard openpty(&primary, &secondary, &name, nil, nil) == 0
                else { throw AskSecureDirectory.failure("open pty") }
                reader = primary; writer = primary; childInput = secondary; childOutput = secondary
                terminalPath = String(cString: name)
                var attributes = termios()
                guard tcgetattr(secondary, &attributes) == 0 else { throw AskSecureDirectory.failure("read terminal") }
                // Canonical input supports EOF; no local echo or CRLF rewriting.
                attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
                attributes.c_oflag &= ~tcflag_t(ONLCR)
                guard tcsetattr(secondary, TCSANOW, &attributes) == 0
                else { throw AskSecureDirectory.failure("configure terminal") }
            } else {
                var output = [Int32](repeating: -1, count: 2), input = output
                guard pipe(&output) == 0 else { throw AskSecureDirectory.failure("output pipe") }
                reader = output[0]; childOutput = output[1]
                guard pipe(&input) == 0 else { throw AskSecureDirectory.failure("input pipe") }
                childInput = input[0]; writer = input[1]
            }
            for fileDescriptor in Set([reader, writer, childInput, childOutput]) {
                guard fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0
                else { throw AskSecureDirectory.failure("close on exec") }
            }
            guard fcntl(reader, F_SETFL, O_NONBLOCK) == 0, fcntl(writer, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(writer, F_SETNOSIGPIPE, 1) == 0
            else { throw AskSecureDirectory.failure("nonblocking terminal") }
        } catch { closeAll(); throw error }
    }

    deinit { closeAll() }

    func didSpawn() {
        for fileDescriptor in Set([childInput, childOutput]) where fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        childInput = -1; childOutput = -1
    }

    func closeInput() {
        if writer >= 0, writer != reader {
            close(writer); writer = -1
        }
    }

    func closeAll() {
        for fileDescriptor in Set([reader, writer, childInput, childOutput]) where fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        reader = -1; writer = -1; childInput = -1; childOutput = -1
    }

    /// Keep POSIX setup and teardown in one scope so partial failures close every descriptor.
    static func spawn(arguments: [String], environment: [String: String], cwd: Int32,
                      processIO: AskProjectProcessIO, listener: Int32?) throws -> pid_t {
        func check(_ code: Int32) throws {
            guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        // GUI hosts may have closed stdio. Move every action source above the
        // destination range before dup2 can overwrite another action's source.
        var descriptors: [Int32: Int32] = [:]
        defer { descriptors.values.forEach { close($0) } }
        for original in Set([processIO.childInput, processIO.childOutput, cwd] + (listener.map { [$0] } ?? [])) {
            let duplicate = fcntl(original, F_DUPFD_CLOEXEC, 4)
            guard duplicate >= 0 else { throw AskSecureDirectory.failure("duplicate launch descriptor") }
            descriptors[original] = duplicate
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[processIO.childInput]!, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[processIO.childOutput]!, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[processIO.childOutput]!, STDERR_FILENO))
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addfchdir(&actions, descriptors[cwd]!))
        } else {
            try check(posix_spawn_file_actions_addfchdir_np(&actions, descriptors[cwd]!))
        }
        if let listener {
            try check(posix_spawn_file_actions_adddup2(&actions, descriptors[listener]!, 3))
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty); sigfillset(&defaults)
        try check(posix_spawnattr_setsigmask(&attributes, &empty))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
                POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        let executable = AskCodeSandbox.sandboxExec
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        try argv.withUnsafeBufferPointer { args in
            try envp.withUnsafeBufferPointer { env in
                try check(posix_spawn(&pid, executable, &actions, &attributes,
                                      UnsafeMutablePointer(mutating: args.baseAddress!),
                                      UnsafeMutablePointer(mutating: env.baseAddress!)))
            }
        }
        return pid
    }
}
