// Opt-in diagnostic interposition. Never linked into the application or helper.
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
#include <spawn.h>
#include <pthread/qos.h>
#include <pthread/spawn.h>

enum { INITIAL = 1, READ_BEGIN, READ_END, SIGNAL_BEGIN, SIGNAL_END, SPAWN_QOS };
typedef struct {
    uint64_t committed, sequence;
    double uptime, entered;
    int64_t size, count, result, offset;
    uint64_t start_seconds, start_microseconds;
    int32_t kind, pid, target, descriptor, status, error;
} Event;
typedef struct {
    _Atomic uint64_t next, dropped;
    uint64_t capacity, event_bytes;
    Event events[];
} Buffer;
static Buffer *buffer;
static _Atomic uint64_t reads;
static _Atomic uintptr_t streams[4096];
static _Atomic uintptr_t seen[4096];
static _Atomic uint64_t bytes[4096];
static mach_timebase_info_data_t timebase;
static bool utility_media;

static double now(void) {
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}
static void identity(Event *event, pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        event->status = info.pbi_status;
        event->start_seconds = info.pbi_start_tvsec;
        event->start_microseconds = info.pbi_start_tvusec;
    }
}
static void emit(Event event) {
    if (!buffer) return;
    uint64_t slot = atomic_fetch_add(&buffer->next, 1);
    if (slot >= buffer->capacity) { atomic_fetch_add(&buffer->dropped, 1); return; }
    event.pid = getpid();
    event.uptime = now();
    buffer->events[slot] = event;
    atomic_store_explicit((_Atomic uint64_t *)&buffer->events[slot].committed, 1, memory_order_release);
}
__attribute__((constructor)) static void initialize(void) {
    mach_timebase_info(&timebase);
    utility_media = getenv("GUL405_MEDIA_UTILITY") && strcmp(getenv("GUL405_MEDIA_UTILITY"), "1") == 0;
    const char *path = getenv("GUL405_IO_BUFFER");
    if (!path) return;
    int fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd < 0) return;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid()
        || (info.st_mode & 077) || info.st_size < (off_t)sizeof(Buffer)) { close(fd); return; }
    Buffer *mapped = mmap(NULL, info.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) return;
    if (mapped->event_bytes != sizeof(Event)
        || mapped->capacity > (info.st_size - sizeof(Buffer)) / sizeof(Event)) {
        munmap(mapped, info.st_size); return;
    }
    buffer = mapped;
    Event event = {.kind = INITIAL, .target = getpid()};
    identity(&event, getpid()); emit(event);
}
static FILE *observed_fopen(const char *path, const char *mode) {
    FILE *file = fopen(path, mode);
    int saved = errno;
    if (buffer && file) {
        int fd = fileno(file); char magic[4];
        if (fd >= 0 && fd < 4096 && pread(fd, magic, 4, 0) == 4
            && magic[0] == 'G' && magic[1] == 'G' && magic[2] == 'U' && magic[3] == 'F')
            { atomic_store(&bytes[fd], 0); atomic_store(&streams[fd], (uintptr_t)file); }
    }
    errno = saved; return file;
}
static int observed_fclose(FILE *file) {
    int fd = fileno(file);
    if (fd >= 0 && fd < 4096) { atomic_store(&streams[fd], 0); atomic_store(&seen[fd], 0); }
    return fclose(file);
}
static size_t observed_fread(void *ptr, size_t size, size_t count, FILE *file) {
    int initial_errno = errno;
    int fd = fileno(file);
    // Native archives can import fopen$DARWIN_EXTSN or fdopen instead of fopen.
    // Identify lazily at fread too, without advancing the stream or inspecting contents beyond magic.
    if (buffer && fd >= 0 && fd < 4096 && atomic_load(&seen[fd]) != (uintptr_t)file) {
        char magic[4]; struct stat info;
        bool gguf = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && pread(fd, magic, 4, 0) == 4
            && magic[0] == 'G' && magic[1] == 'G' && magic[2] == 'U' && magic[3] == 'F';
        atomic_store(&streams[fd], gguf ? (uintptr_t)file : 0);
        atomic_store(&seen[fd], (uintptr_t)file); atomic_store(&bytes[fd], 0);
    }
    errno = initial_errno;
    if (!buffer || fd < 0 || fd >= 4096 || atomic_load(&streams[fd]) != (uintptr_t)file)
        return fread(ptr, size, count, file);
    uint64_t sequence = atomic_fetch_add(&reads, 1) + 1;
    // Dense startup plus periodic progress. Slow completions retain their own entry timestamp.
    bool selected = sequence <= 256 || sequence % 1024 == 0;
    Event event = {.sequence = sequence, .kind = READ_BEGIN, .descriptor = fd,
        .size = size, .count = count, .offset = atomic_load(&bytes[fd]), .entered = now()};
    if (selected) emit(event);
    errno = initial_errno;
    size_t result = fread(ptr, size, count, file);
    int saved = errno;
    atomic_fetch_add(&bytes[fd], result * size);
    if (selected || now() - event.entered >= 0.002) {
        event.kind = READ_END; event.result = result; event.error = saved; emit(event);
    }
    errno = saved; return result;
}
static int observed_kill(pid_t target, int value) {
    if (!buffer || (value != SIGSTOP && value != SIGCONT)) return kill(target, value);
    Event event = {.kind = SIGNAL_BEGIN, .target = target < 0 ? -target : target,
        .count = value, .entered = now()};
    int initial_errno = errno;
    identity(&event, event.target); emit(event);
    errno = initial_errno;
    int result = kill(target, value);
    int saved = errno;
    event.kind = SIGNAL_END; event.result = result; event.error = result < 0 ? saved : 0;
    identity(&event, event.target); emit(event);
    errno = saved; return result;
}
static int observed_spawn_qos(posix_spawnattr_t *attributes, qos_class_t qos) {
    qos_class_t applied = utility_media && qos == QOS_CLASS_BACKGROUND ? QOS_CLASS_UTILITY : qos;
    int result = posix_spawnattr_set_qos_class_np(attributes, applied);
    int saved = errno;
    Event event = {.kind = SPAWN_QOS, .count = qos, .size = applied, .result = result};
    emit(event); errno = saved; return result;
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new; const void *old; } \
    pair_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)&replacement, (const void *)&original };
INTERPOSE(observed_fopen, fopen)
INTERPOSE(observed_fclose, fclose)
INTERPOSE(observed_fread, fread)
INTERPOSE(observed_kill, kill)
INTERPOSE(observed_spawn_qos, posix_spawnattr_set_qos_class_np)
