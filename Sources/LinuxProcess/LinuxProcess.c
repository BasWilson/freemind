#define _GNU_SOURCE
#include "LinuxProcess.h"
#include <spawn.h>
#include <signal.h>
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

int fm_spawn(pid_t *pid, const char *executable, char *const argv[], char *const env[],
             const char *cwd, int input, int output, int error) {
    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (result) return result;
    posix_spawnattr_t attributes;
    result = posix_spawnattr_init(&attributes);
    if (result) { posix_spawn_file_actions_destroy(&actions); return result; }
    // Dispatch worker threads block signals. Do not pass their mask to tmux,
    // which needs SIGCHLD to observe pane exits and finish server shutdown.
    sigset_t mask;
    sigemptyset(&mask);
    result = posix_spawnattr_setsigmask(&attributes, &mask);
    if (!result) result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP);
    if (result) {
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }
    if (!(result = posix_spawn_file_actions_adddup2(&actions, input, 0)) &&
        !(result = posix_spawn_file_actions_adddup2(&actions, output, 1)) &&
        !(result = posix_spawn_file_actions_adddup2(&actions, error, 2)) &&
        !(result = posix_spawn_file_actions_addclosefrom_np(&actions, 3)) &&
        (!cwd || !(result = posix_spawn_file_actions_addchdir_np(&actions, cwd)))) {
        result = posix_spawn(pid, executable, &actions, &attributes, argv, env);
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}
int fm_exit_status(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status);
}
ssize_t fm_write(int fd, const void *buffer, size_t count) {
    sigset_t signals, original, pending;
    sigemptyset(&signals);
    sigaddset(&signals, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &signals, &original);
    sigpending(&pending);
    ssize_t result = write(fd, buffer, count);
    int saved_errno = errno;
    if (result < 0 && saved_errno == EPIPE && !sigismember(&pending, SIGPIPE)) {
        struct timespec zero = {0, 0};
        while (sigtimedwait(&signals, NULL, &zero) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &original, NULL);
    errno = saved_errno;
    return result;
}
