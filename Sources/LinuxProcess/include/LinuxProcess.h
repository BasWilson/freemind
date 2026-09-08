#ifndef FREEMIND_LINUX_PROCESS_H
#define FREEMIND_LINUX_PROCESS_H
#include <sys/types.h>
int fm_spawn(pid_t *pid, const char *executable, char *const argv[], char *const env[],
             const char *cwd, int input, int output, int error);
int fm_exit_status(int status);
ssize_t fm_write(int fd, const void *buffer, size_t count);
#endif
