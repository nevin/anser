#include "anser_pty.h"
#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/ioctl.h>

pid_t anser_spawn_pty(const char *path, char *const argv[], char *const envp[], const char *cwd,
                      unsigned short rows, unsigned short cols, int *master) {
    struct winsize ws = { rows ? rows : 24, cols ? cols : 80, 0, 0 };
    pid_t pid = forkpty(master, NULL, NULL, &ws);
    if (pid != 0) {
        if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
        return pid;
    }
    // Child: only async-signal-safe calls from here.
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
    int maxfd = getdtablesize();
    for (int fd = 3; fd < maxfd; fd++) close(fd);
    if (cwd == NULL || chdir(cwd) != 0) {
        const char *home = NULL;
        for (char *const *e = envp; e && *e; e++) {
            const char *v = *e;
            if (v[0] == 'H' && v[1] == 'O' && v[2] == 'M' && v[3] == 'E' && v[4] == '=') { home = v + 5; break; }
        }
        if (home == NULL || chdir(home) != 0) chdir("/");
    }
    execve(path, argv, envp);
    _exit(127);
}
