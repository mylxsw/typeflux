# Project terminal and development service runtime (GUL-177 / D02)

`AskProjectRuntime` is an independent, default-disabled host component. It does
not enable analysis `run_code`, register model tools, change Settings, or enable
provider/wire capabilities. D04's [project integration](project-loop.md) supplies
optional `AskLocalTools` injection, approval presentation, terminal UI and the
D03 preview connection. Application composition keeps these disabled.

## Supported execution boundary

The first backend runs a **single preinstalled Command Line Tools Python
process**. It supports multi-file Python projects and stdlib dependencies in a
private working copy. It does not support shells, npm, pip installation,
subprocess-based build tools, multiprocessing, daemonization, Homebrew runtimes,
or arbitrary executables. Unsupported network installation requests fail even
if the host has issued an execution approval; there is no implicit network grant
or domain-filter claim. A future installer needs separate approval and a real
network enforcement backend.

The macOS Seatbelt profile starts with `deny default`. It permits reads of the
copied project, private temporary directory, system libraries and the resolved
CLT Python version directory. Writes stay in the project and temporary
directories. The parent directories, source root, control journal and output log
are not writable by the child. Metadata-only access to required ancestors does
not expose their contents. The environment is constructed from scratch; only
`LANG`, `LC_ALL`, and `TERM` can be overridden. `HOME` and `TMPDIR` point to the
private copy. Python uses `-I -u -B`, then a fixed bootstrap adds only the copied
script directory to `sys.path` for local modules.

Fork/spawn, Mach/Apple-event IPC, outbound connections, new network binds and
signals to other processes stay denied. `exec` can only replace the current
process with a binary in the installed Python runtime directory under the same
sandbox. The supervisor owns and reaps its direct child PID. Its cleanup does
not depend on a descendant staying in a process group. P01's unrestricted
fork/setsid counterexample is not an enabled project execution mode.

The threat model includes hostile project code and concurrent source editors.
It excludes kernel exploits and another unrestricted process running as the
same macOS user. This is not a resource-quota backend: CPU/memory/private-copy
disk quotas are not provided. Production rollout remains disabled. Validation
is specific to the macOS/CLT versions in `d02-validation.md`; availability of
`sandbox-exec` alone is not a cross-version acceptance result.

## Snapshot and authorization transaction

1. The trusted host provides the current `AskProjectScope`, `WorkspaceRef`, roots
   callback and typed launch request. Model arguments cannot choose the scope.
2. `approval` validates D01 ownership, root identity and revision, and produces
   a P02 single-use approval binding the full serialized request, workspace,
   owner, conversation, run, call and runtime version. Show the complete launch
   request in the integration approval UI, including arguments, cwd and limits.
3. `start` copies within `withValidatedSnapshot`. It overlays `entries.updated`,
   records versions of every unstaged file, records directory identity and
   modification stamps, and revalidates after traversal. Source descriptors
   remain inside the callback. No process starts until the callback succeeds.
4. Current roots, root identity, staged revision and grant expiry/revocation are
   checked again immediately before single-use consumption and synchronous
   launch. There is no actor suspension in this final boundary. Failed
   preparation removes only the private unpublished copy.
5. Every API checks the opaque lease, app session, owner, conversation and run.
   Each stdin submission/EOF requires a new P02 approval bound to its exact bytes
   and lease. Stop is always available to the owning scope without new approval.

The copy permits binary assets but rejects symlinks, hardlinks, FIFOs, traversal
and unsafe path names. It excludes `.git` metadata explicitly. More than 500
entries in any directory, a 1,024-entry budget, directory depth 16, 16 MiB in one source
file, or 32 MiB copied content causes failure; there is no partial project
success. New staged files conservatively charge every path component against
the entry budget, including parent directories that might already exist.
Empty directories and newly staged directories are preserved. External
editors cannot be locked out atomically across an entire source tree, but the
launched files are the private captured bytes and never overwrite the source.

## Terminal, cursors and logs

Pipe and PTY modes expose stdin and merged, ordered stdout/stderr. PTY mode
supports `isatty`, canonical line input, no local echo and EOF; it is not a
controlling-terminal shell or job-control implementation. Use pipe mode for
binary input. The queue is bounded to 64 KiB. PTY input additionally rejects
lines above 255 bytes across submissions instead of letting the terminal driver
silently truncate them. Short writes and nonblocking
backpressure are handled without blocking the main actor.

Output is raw `Data`, not independently decoded strings. Cursors are absolute
byte offsets. Each page returns `offset`, `nextCursor`, and `lostBytes`; callers
must acknowledge a gap if they fall behind the 1 MiB in-memory window, and keep
UTF-8 decoder state across pages. Reading the same cursor is idempotent. The
supervisor always drains output, including after the retained log fills, with
bounded work between lifecycle checks. `output.bin` retains the first 1 MiB;
status reports total bytes, truncation and persistence errors. The original
output may contain sensitive project data; it stays local and is not telemetry.

## Loopback service contract

`servicePort == nil` launches a command; `0` asks the OS for an available port.
An explicit port must be at least 1024. The host binds an exclusive IPv4
`127.0.0.1` listener **before** spawn and inherits only that descriptor as fd 3.
The reservation stays open for the lease, eliminating the close/rebind race.
The child is forbidden from binding even its own port, wildcard addresses,
IPv6 or a second port. Its sandbox allows inbound traffic on the allocated
loopback port and no outbound connects.

Each readiness probe is bounded to 270 ms (connect/write readiness plus response
reading); lifecycle checks resume between probes. HTTP headers and bodies may
arrive in separate packets. The response is bounded to 4 KiB.

The program reads `TYPEFLUX_LISTEN_FD`, `TYPEFLUX_PORT`, and
`TYPEFLUX_READY_TOKEN`. It accepts the inherited socket and implements
`GET /__typeflux_ready/<token>` with a 200 HTTP response whose body is exactly
the token. A successful TCP connection alone is not readiness. The runtime
does not return a service address until a real token-matching response arrives.
Port conflicts fail before launching a process. Readiness expiry stops and
reaps the child and closes the reservation.

See `AskProjectServiceTests` for a complete executable stdlib service. A service
that expects to bind its own port needs an adapter or remains unsupported.
Loopback is not authentication against unrelated local applications. D04 must
still enforce D03 preview navigation, origin and native-bridge policy, and must
not expose internal lease metadata as model-selected authority.

## Lifetime, recovery and rollback

At most four processes and 128 retained execution directories are allowed per
runtime store. A store lock prevents simultaneous runtime instances from
invalidating each other's journals. The host must bind cancellation/steering to
`cancel(scope:)`, workspace deletion to `workspaceDeleted`, and rollback to
`shutdown`. The runtime also checks live folder grants/root identity every
250 ms and listens to `NSApplication.willTerminateNotification`.

Stop, cancellation, revocation, timeout, readiness timeout, and graceful app
exit synchronously wait for child reaping and listener closure. The first stop
reason wins. SIGTERM gets 150 ms before SIGKILL; kernel-uninterruptible processes
are outside that latency bound. Finished output/status remain readable by the
owning scope. Logs and generated files remain in private execution directories;
no user root or D01 manifest is deleted. There is no automatic stale-result
replay or retry.

On reopening the store, prior leases are marked invalid for the new app session;
their journals, copies and logs remain. A stored numeric PID is never signalled.
**An abrupt host crash/SIGKILL is not a guaranteed cleanup path:** there is no
external guardian; an orphan can remain sandboxed, and old deadlines no longer
run. Recovery invalidates its handle and reports the old lease instead of
pretending it was cleaned up or risking PID-reuse kills. A crash-proof guardian
with process identity validation is required before claiming cleanup after
ungraceful termination. This limitation remains a rollout gate even with D04's
optional UI wiring, not silently accepted production behavior.

Disabling this component stops new launches and calls `shutdown`, retaining
artifacts/logs. Analysis mode never inherits project execution or network
permissions. No production switch is enabled by this change.
