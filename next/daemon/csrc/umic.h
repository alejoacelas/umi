// C helpers for the umi-next daemon: process plumbing that Swift can't do
// safely (fork/exec, signal handlers) and the libghostty-vt calls that rely
// on C macros (GHOSTTY_INIT_SIZED).
#ifndef UMIC_H
#define UMIC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <ghostty/vt.h>

// Fork a child on a new pty (forkpty: new session, the pty is its
// controlling terminal), chdir to cwd and execve path. Returns the pid, or
// -1 with errno set. *master_fd receives the pty master (non-blocking,
// close-on-exec).
pid_t umi_spawn_pty(const char *path, char *const argv[], char *const envp[],
                    const char *cwd, uint16_t cols, uint16_t rows,
                    int *master_fd);

// Set the pty size (TIOCSWINSZ; the kernel sends SIGWINCH to the
// foreground process group).
int umi_set_winsize(int fd, uint16_t cols, uint16_t rows);
// Read a tty's size. Returns 0 on success.
int umi_get_winsize(int fd, uint16_t *cols, uint16_t *rows);

// Detach from the parent: fork, setsid, fork again, stdin/stdout to
// /dev/null, stderr to log_fd. Returns 0 in the grandchild; the parent and
// the middle child exit. Must be called before any threads start.
int umi_daemonize(int log_fd);

// Install a SIGCHLD handler that writes one byte to wfd (self-pipe).
void umi_install_sigchld(int wfd);
// Ignore SIGHUP and SIGPIPE.
void umi_ignore_hup_pipe(void);
// Install a SIGWINCH handler that writes one byte to wfd.
void umi_install_sigwinch(int wfd);

// Raw mode on fd; saves the previous settings for umi_tty_restore.
int umi_tty_raw(int fd);
void umi_tty_restore(int fd);

// Name of a process (libproc), or "" if unknown. buf must hold 256 bytes.
void umi_proc_name(pid_t pid, char *buf, size_t len);
// Foreground process group of a tty fd, or -1.
pid_t umi_tcgetpgrp(int fd);

// ---- libghostty-vt ----

// New terminal with continuation tracking (so a replay can finish an
// escape sequence that was cut mid-way) and a 10000-line scrollback.
GhosttyTerminal umi_vt_new(uint16_t cols, uint16_t rows);
// Route VT query responses (DA, DSR, …) to fn(userdata, data, len).
void umi_vt_set_write_pty(GhosttyTerminal t, void *userdata,
                          void (*fn)(void *userdata, const uint8_t *data,
                                     size_t len));
// Resize (cell pixel size 0).
void umi_vt_resize(GhosttyTerminal t, uint16_t cols, uint16_t rows);

// The bytes that reproduce the terminal on a blank terminal of the same
// size: RIS, then (when the alternate screen is active) the primary screen
// with its scrollback, then the formatter's VT output of the active screen
// with every extra (palette, modes, scrolling region, tabstops, pwd,
// keyboard modes, cursor, style, hyperlink, protection, kitty keyboard
// flags, charsets), then any unfinished escape sequence. Returns a
// malloc'd buffer (free with free()), or NULL.
uint8_t *umi_vt_replay(GhosttyTerminal t, size_t *out_len);

// The active area as plain text: exactly `rows` lines, each ending in
// '\n', trailing spaces trimmed. malloc'd, free with free().
char *umi_vt_plain(GhosttyTerminal t, size_t *out_len);

// Per-cell style of the active area: one line per row, cells separated by
// spaces, "." for the default style, else fg/bg/flags+underline.
char *umi_vt_styles(GhosttyTerminal t, size_t *out_len);

typedef struct {
    uint16_t cols, rows;
    uint16_t cursor_x, cursor_y;
    bool cursor_visible;
    bool alternate;
    uint8_t kitty_flags;
    bool mouse_tracking;
    bool bracketed_paste;
    bool app_cursor_keys;
} UmiVtInfo;
void umi_vt_info(GhosttyTerminal t, UmiVtInfo *out);

#endif
