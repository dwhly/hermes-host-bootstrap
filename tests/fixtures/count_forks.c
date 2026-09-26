/* Fixture-only process counter for shells when ptrace is unavailable. Never
 * installed in the payload. The test injects it AFTER the production env -i.
 * Map vfork to fork to safely record child creation without sharing the stack. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <spawn.h>
#include <string.h>

static void record(void) {
    const char *path = getenv("CURRENCY_FORK_LOG");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) { (void)!write(fd, "child\n", 6); close(fd); }
}

pid_t fork(void) {
    pid_t (*actual)(void) = dlsym(RTLD_NEXT, "fork");
    pid_t pid = actual();
    if (pid == 0) record();
    return pid;
}

pid_t vfork(void) { return fork(); }

int execve(const char *path, char *const argv[], char *const envp[]) {
    int (*actual)(const char *, char *const[], char *const[]) = dlsym(RTLD_NEXT, "execve");
    const char *log = getenv("CURRENCY_FORK_LOG");
    int fd = log ? open(log, O_WRONLY | O_CREAT | O_APPEND, 0600) : -1;
    if (fd >= 0) {
        (void)!write(fd, "exec ", 5);
        (void)!write(fd, path, strlen(path));
        (void)!write(fd, "\n", 1);
        close(fd);
    }
    return actual(path, argv, envp);
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attrs, char *const argv[], char *const envp[]) {
    int (*actual)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                  const posix_spawnattr_t *, char *const[], char *const[]) = dlsym(RTLD_NEXT, "posix_spawn");
    int result = actual(pid, path, actions, attrs, argv, envp);
    if (!result) record();
    return result;
}

int posix_spawnp(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attrs, char *const argv[], char *const envp[]) {
    int (*actual)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                  const posix_spawnattr_t *, char *const[], char *const[]) = dlsym(RTLD_NEXT, "posix_spawnp");
    int result = actual(pid, path, actions, attrs, argv, envp);
    if (!result) record();
    return result;
}
