# Managed analysis execution (GUL-167 / P01)

## Release behavior

`run_code` is **disabled by default**, even if the user's existing code-execution
setting is enabled. It is omitted from tool discovery. Calls retained in an older
conversation fail with an explicit containment error. There is no unsandboxed
fallback. Existing conversation records and user settings are unchanged.

`allowProcessGroupExecution` is an internal integration/test opt-in, not a user
preference. Do not wire it to settings or enable it in production before the
containment gate below is satisfied. The change intentionally disables a formerly
available capability; it does not claim complete isolation of arbitrary code.

## File contract

- `AskSecureDirectory` opens every path component with `O_DIRECTORY | O_NOFOLLOW`
  and pins it with a close-on-exec descriptor. Only the OS-owned `/var`, `/tmp`, and
  `/etc` aliases are normalized. Root/session/control directories must belong to
  the current UID and have no group/other permissions.
- `TypefluxAskSandbox-v2/sessions/<SHA256(conversationID)>` persists user artifacts.
  Hashing the full identifier avoids aliases caused by stripping punctuation or
  truncating IDs. Existing v1 workspaces are not migrated or reused.
- `scripts/<random-run-ID>/main.<extension>` is outside every writable workspace.
  Host writes use `openat(O_CREAT | O_EXCL | O_NOFOLLOW)` and descriptor-relative
  cleanup. Script directories are removed on success, failure, timeout and cancel.
- One nonblocking `flock` holds each session for execution, artifact collection and
  cleanup. Concurrent same-session calls fail; different sessions may run in
  parallel. Pruning skips locked sessions and never follows directory symlinks.
- Artifact enumeration does not follow symlinks, ignores multiply-linked files,
  and is bounded to 4,096 entries / 16 directory levels. Image reads reopen every
  component without following links, reject non-regular/multiply-linked files and
  cap input at 10 MiB. This also avoids blocking on FIFOs and reading outside the
  workspace through image links. Enumeration is a bounded best-effort report,
  not a complete artifact manifest for very large workspaces.

## Environment and read contract

The child receives only fixed `PATH`, `LANG`, `LC_ALL`, `MPLBACKEND`,
`PYTHONDONTWRITEBYTECODE`, `PYTHONNOUSERSITE`, and session-specific `HOME`/`TMPDIR`.
No app environment variables, provider keys, proxy settings, loader overrides,
Python paths, or Node options are inherited. No descriptors other than stdio
survive spawn. stdin is `/dev/null`.

Seatbelt denies network operations and file reads/writes by default, then allows
specific system runtime trees, this workspace, this run's script directory, and
explicit skill directories. Read grants overlapping the storage root are refused.
The workspace root itself cannot be renamed or modified. Mach lookup, Apple
Events, inspection of other processes and signalling other processes are denied
as well. Metadata on allowed roots' ancestors and self PID information remain
available for runtime path resolution; ancestor file contents remain denied.

The supported integration runtimes are `/bin/zsh -f` and the real executable of
Apple Command Line Tools Python with `-I`; Python's version-specific framework
root is readable for its standard library and extension modules. These are tested
using real shell commands and Python `sqlite3`, `hashlib`, `socket`, `math` and
image output. `node`, Homebrew, pyenv, nvm and arbitrary PATH executables are not
advertised: their transitive library/package read roots have not been validated.
Third-party Python packages such as matplotlib are not promised.

## ManagedProcess contract for P09 / D02

`ManagedProcess.Request` requires an absolute executable, explicit argv and env,
a caller-owned open working-directory descriptor, a positive finite timeout, and
a byte limit (default 30,000 bytes **per stream**). The caller must keep that
descriptor open until `run` returns. No shared app process runner is reused. The parent must not install a competing
child reaper or ignore SIGCHLD; loss of child ownership fails instead of signalling
a potentially reused PID.

`posix_spawn` creates a process group atomically, resets signal dispositions and
mask, changes directory by descriptor, and closes unspecified descriptors.
`Result.termination` is one of `exited`, `signalled`, `timedOut`, or `cancelled`.
The raw exit code, bounded stdout/stderr, omission counts and truncation flag are
also returned. Launch errors throw. A cancellation observed before spawn throws
`CancellationError`; after spawn it returns `cancelled` only after cleanup. Ask
converts that state back to `CancellationError`.

A single monotonic deadline covers spawn, execution and pipe drainage. Each
nonblocking read cycle is bounded so flooding one stream cannot starve the other
stream or cancellation. The first observed cancellation/timeout state is stable
through cleanup; cancellation wins if both are first observed together.

On parent exit, cancel or timeout, TERM is sent to the group and direct child;
200 ms later KILL is sent. Readers close at most 300 ms after that grace interval
rather than waiting indefinitely for EOF. The direct child is reaped. Its PID
is reserved using `waitid(WNOWAIT)` until group signalling completes, avoiding a
PID/PGID reuse signal race. Normal returns also clean remaining group members.
The deadline-plus-two-seconds target is tested on this host, not a production SLO;
kernel-uninterruptible processes and system suspension are outside that bound.

## Process model and containment gate

This executor owns descendants **only while they remain in its process group**.
`setsid`, changing process group, double-fork daemonization, external job services,
and cooperating unsandboxed same-UID programs are not contained by group signals.
A finite real fork/setsid fixture demonstrates session escape without leaving a
daemon running. The file/network profile is inherited, but that does not imply
lifecycle containment. Apple XNU's [setsid/setpgid implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_prot.c)
is the relevant boundary; there is no group ownership guarantee for hostile code.

Before enabling untrusted `run_code`, provide and validate a stronger supervisor
or isolation boundary that prevents or owns all session/group escape. Include
hostile daemonization, surviving pipe writers, fork floods, resource exhaustion,
and cleanup across app termination. Also validate required interpreters and
Seatbelt behavior across supported macOS versions. Do not turn on the integration
switch based solely on the ordinary-process-group tests passing.

P09/D02 may reuse the explicit request/result contract for a separately authorized
process model. They must add their own containment, service lifetime and resource
policies, and must not present process-group management as a hostile-code sandbox.
