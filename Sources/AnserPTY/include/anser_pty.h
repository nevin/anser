#ifndef ANSER_PTY_H
#define ANSER_PTY_H
#include <sys/types.h>

/// Starts `path` with `argv`/`envp` in `cwd` on a new pseudo-terminal of the
/// given size, as the leader of its own session with the terminal as its
/// controlling terminal. Returns the child's pid (or -1) and the master side in
/// `*master`. Everything else open in the caller is closed in the child.
pid_t anser_spawn_pty(const char *path, char *const argv[], char *const envp[], const char *cwd,
                      unsigned short rows, unsigned short cols, int *master);

#endif
