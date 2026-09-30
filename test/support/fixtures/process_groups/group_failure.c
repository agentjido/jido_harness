#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

static pid_t owner;
static int progress[2];

__attribute__((constructor))
static void initialize(void)
{
    owner = getpid();
    if (pipe(progress) < 0)
        _exit(126);
}

int setpgid(pid_t pid, pid_t pgid)
{
    static int (*original)(pid_t, pid_t);
    if (!original)
        original = (int (*)(pid_t, pid_t))dlsym(RTLD_NEXT, "setpgid");
    if (!original)
        _exit(126);

    if (getpid() != owner) {
        char token;
        ssize_t received;
        do {
            received = read(progress[0], &token, 1);
        } while (received < 0 && errno == EINTR);
        if (received != 1)
            _exit(126);
        errno = EPERM;
        return -1;
    }

    if (pid != 0 && pid != owner) {
        int result;
        if (getenv("ERLEXEC_TEST_DENY_PARENT_GROUP")) {
            errno = EPERM;
            result = -1;
        } else {
            result = original(pid, pgid);
        }
        int saved_errno = errno;
        char token = 'x';
        ssize_t sent;
        do {
            sent = write(progress[1], &token, 1);
        } while (sent < 0 && errno == EINTR);
        if (sent != 1)
            _exit(126);
        errno = saved_errno;
        return result;
    }

    return original(pid, pgid);
}
