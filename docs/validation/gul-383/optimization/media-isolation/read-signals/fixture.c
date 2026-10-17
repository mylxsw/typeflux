// A synthetic stream and an owned child; no model or application execution.
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <pthread/qos.h>
#include <pthread/spawn.h>
static int retire(pid_t child, int code) {
    int status; pid_t result;
    do { result = waitpid(child, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    // Only a still-reserved direct child may receive a cleanup signal.
    if (result == 0) {
        kill(child, SIGKILL);
        do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
    }
    return code;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes)
        || posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_BACKGROUND)
        || posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_UTILITY)) return 11;
    posix_spawnattr_destroy(&attributes);
    FILE *file = fdopen(open(argv[1], O_RDONLY), "rb");
    if (!file) return 3;
    char data[16] = {0};
    if (fread(data, 1, 16, file) != 16 || memcmp(data, "GGUFprivate-test", 16)) return 4;
    if (fread(data, 1, 16, file) != 0 || !feof(file)) return 5;
    fclose(file);
    pid_t child = fork();
    if (child < 0) return 6;
    if (child == 0) { for (;;) pause(); }
    int status;
    if (kill(child, SIGSTOP) || waitpid(child, &status, WUNTRACED) != child || !WIFSTOPPED(status)) return retire(child, 7);
    if (kill(child, SIGCONT)) return retire(child, 8);
    usleep(10000);
    if (kill(child, SIGTERM) || waitpid(child, &status, 0) != child) return retire(child, 9);
    errno = 0;
    if (kill(child, SIGCONT) != -1 || errno != ESRCH) return 10;
    puts("forwarding-ok");
    return 0;
}
