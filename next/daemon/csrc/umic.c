#include "umic.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

// ---- processes ----

pid_t umi_spawn_pty(const char *path, char *const argv[], char *const envp[],
                    const char *cwd, uint16_t cols, uint16_t rows,
                    int *master_fd) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols};
    int m = -1;
    pid_t pid = forkpty(&m, NULL, NULL, &ws);
    if (pid < 0) return -1;
    if (pid == 0) {
        // Child: undo the daemon's signal setup, close inherited fds.
        int sigs[] = {SIGHUP, SIGPIPE, SIGCHLD, SIGINT, SIGQUIT, SIGTERM,
                      SIGTSTP, SIGTTIN, SIGTTOU, SIGWINCH};
        for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
            signal(sigs[i], SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        int maxfd = (int)sysconf(_SC_OPEN_MAX);
        if (maxfd < 0 || maxfd > 4096) maxfd = 4096;
        for (int fd = 3; fd < maxfd; fd++) close(fd);
        struct termios t;
        if (tcgetattr(0, &t) == 0) {
            t.c_iflag |= IUTF8;
            tcsetattr(0, TCSANOW, &t);
        }
        if (cwd && *cwd && chdir(cwd) != 0) {
            const char *home = getenv("HOME");
            if (!home || chdir(home) != 0) chdir("/");
        }
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK);
    fcntl(m, F_SETFD, FD_CLOEXEC);
    *master_fd = m;
    return pid;
}

int umi_set_winsize(int fd, uint16_t cols, uint16_t rows) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols};
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int umi_get_winsize(int fd, uint16_t *cols, uint16_t *rows) {
    struct winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return -1;
    *cols = ws.ws_col;
    *rows = ws.ws_row;
    return 0;
}

int umi_daemonize(int log_fd) {
    pid_t p = fork();
    if (p < 0) return -1;
    if (p > 0) _exit(0);
    if (setsid() < 0) return -1;
    signal(SIGHUP, SIG_IGN);
    p = fork();
    if (p < 0) return -1;
    if (p > 0) _exit(0);
    int null = open("/dev/null", O_RDWR);
    if (null >= 0) {
        dup2(null, 0);
        dup2(null, 1);
        if (null > 2) close(null);
    }
    if (log_fd >= 0) dup2(log_fd, 2);
    return 0;
}

static int sigchld_fd = -1;
static int sigwinch_fd = -1;
static void on_sigchld(int sig) {
    (void)sig;
    int e = errno;
    char c = 'c';
    if (sigchld_fd >= 0) (void)!write(sigchld_fd, &c, 1);
    errno = e;
}
static void on_sigwinch(int sig) {
    (void)sig;
    int e = errno;
    char c = 'w';
    if (sigwinch_fd >= 0) (void)!write(sigwinch_fd, &c, 1);
    errno = e;
}

void umi_install_sigchld(int wfd) {
    sigchld_fd = wfd;
    struct sigaction sa = {0};
    sa.sa_handler = on_sigchld;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGCHLD, &sa, NULL);
}

void umi_install_sigwinch(int wfd) {
    sigwinch_fd = wfd;
    struct sigaction sa = {0};
    sa.sa_handler = on_sigwinch;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGWINCH, &sa, NULL);
}

void umi_ignore_hup_pipe(void) {
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
}

static struct termios saved_tty;
static int saved_tty_ok = 0;

int umi_tty_raw(int fd) {
    if (tcgetattr(fd, &saved_tty) != 0) return -1;
    saved_tty_ok = 1;
    struct termios t = saved_tty;
    cfmakeraw(&t);
    return tcsetattr(fd, TCSANOW, &t);
}

void umi_tty_restore(int fd) {
    if (saved_tty_ok) tcsetattr(fd, TCSANOW, &saved_tty);
}

void umi_proc_name(pid_t pid, char *buf, size_t len) {
    buf[0] = 0;
    if (pid <= 0) return;
    if (proc_name(pid, buf, (uint32_t)len) <= 0) buf[0] = 0;
}

pid_t umi_tcgetpgrp(int fd) { return tcgetpgrp(fd); }

// ---- libghostty-vt ----

GhosttyTerminal umi_vt_new(uint16_t cols, uint16_t rows) {
    GhosttyTerminal t = NULL;
    if (ghostty_terminal_new(NULL, &t, cols, rows) != GHOSTTY_SUCCESS)
        return NULL;
    size_t cont = 64 * 1024;
    ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &cont);
    size_t lines = 10000;
    ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines);
    return t;
}

typedef struct {
    void *userdata;
    void (*fn)(void *, const uint8_t *, size_t);
} WritePty;

static void on_write_pty(GhosttyTerminal t, void *ud, const uint8_t *data,
                         size_t len) {
    (void)t;
    WritePty *w = ud;
    if (w && w->fn) w->fn(w->userdata, data, len);
}

void umi_vt_set_write_pty(GhosttyTerminal t, void *userdata,
                          void (*fn)(void *, const uint8_t *, size_t)) {
    // One small allocation per terminal; lives as long as the terminal.
    WritePty *w = malloc(sizeof(WritePty));
    w->userdata = userdata;
    w->fn = fn;
    ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_USERDATA, w);
    ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                         (const void *)on_write_pty);
}

void umi_vt_resize(GhosttyTerminal t, uint16_t cols, uint16_t rows) {
    ghostty_terminal_resize(t, cols, rows, 0, 0);
}

typedef struct {
    uint8_t *ptr;
    size_t len, cap;
} Buf;

static bool buf_append(Buf *b, const uint8_t *data, size_t len) {
    if (b->len + len > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 4096;
        while (cap < b->len + len) cap *= 2;
        uint8_t *p = realloc(b->ptr, cap);
        if (!p) return false;
        b->ptr = p;
        b->cap = cap;
    }
    memcpy(b->ptr + b->len, data, len);
    b->len += len;
    return true;
}

static bool buf_writer(void *ud, const uint8_t *data, size_t len) {
    return buf_append(ud, data, len);
}

static bool format_into(GhosttyTerminal t, Buf *b, bool all_extras) {
    GhosttyFormatterTerminalOptions o =
        GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    o.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    o.unwrap = false;
    o.trim = false;
    o.extra.size = sizeof(o.extra);
    o.extra.screen.size = sizeof(o.extra.screen);
    o.extra.palette = all_extras;
    o.extra.modes = all_extras;
    o.extra.scrolling_region = all_extras;
    o.extra.tabstops = all_extras;
    o.extra.pwd = all_extras;
    o.extra.keyboard = all_extras;
    o.extra.screen.cursor = true;
    o.extra.screen.style = true;
    o.extra.screen.hyperlink = true;
    o.extra.screen.protection = all_extras;
    o.extra.screen.kitty_keyboard = all_extras;
    o.extra.screen.charsets = all_extras;
    GhosttyFormatter f = NULL;
    if (ghostty_formatter_terminal_new(NULL, &f, t, o) != GHOSTTY_SUCCESS)
        return false;
    GhosttyWriter w = {.write = buf_writer, .userdata = b};
    GhosttyResult r = ghostty_formatter_format(f, w);
    ghostty_formatter_free(f);
    return r == GHOSTTY_SUCCESS;
}

// A copy of t (via a snapshot) switched back to the primary screen, so the
// primary screen can be formatted while the app is in the alternate screen.
static GhosttyTerminal primary_copy(GhosttyTerminal t) {
    uint8_t *snap = NULL;
    size_t snap_len = 0;
    if (ghostty_snapshot_encode_alloc(t, NULL, &snap, &snap_len) !=
        GHOSTTY_SUCCESS)
        return NULL;
    GhosttySnapshotDecoder d = NULL;
    GhosttyTerminal copy = NULL;
    if (ghostty_snapshot_decoder_new_buf(NULL, &d, snap, snap_len) ==
        GHOSTTY_SUCCESS) {
        if (ghostty_snapshot_decoder_decode(d, &copy) != GHOSTTY_SUCCESS)
            copy = NULL;
        ghostty_snapshot_decoder_free(d);
    }
    ghostty_free(NULL, snap, snap_len);
    if (!copy) return NULL;
    // Finish any partial sequence harmlessly, then leave the alternate
    // screen (restores the primary cursor saved by 1049).
    const char *leave = "\x18\x1b[?1049l\x1b[?1047l\x1b[?47l";
    ghostty_terminal_vt_write(copy, (const uint8_t *)leave, strlen(leave));
    return copy;
}

uint8_t *umi_vt_replay(GhosttyTerminal t, size_t *out_len) {
    Buf b = {0};
    // RIS: start from a blank terminal whatever the client showed before.
    if (!buf_append(&b, (const uint8_t *)"\x1b" "c", 2)) goto fail;
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    if (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
        GhosttyTerminal copy = primary_copy(t);
        if (copy) {
            bool ok = format_into(copy, &b, false);
            // Reset the style the primary content left set.
            ok = ok && buf_append(&b, (const uint8_t *)"\x1b[0m", 4);
            ghostty_terminal_free(copy);
            if (!ok) goto fail;
        }
    }
    if (!format_into(t, &b, true)) goto fail;
    // An escape sequence cut mid-way: the live stream carries its tail.
    uint8_t *cont = NULL;
    size_t cont_len = 0;
    if (ghostty_terminal_continuation_alloc(t, NULL, &cont, &cont_len) ==
            GHOSTTY_SUCCESS &&
        cont) {
        bool ok = buf_append(&b, cont, cont_len);
        ghostty_free(NULL, cont, cont_len);
        if (!ok) goto fail;
    }
    *out_len = b.len;
    return b.ptr;
fail:
    free(b.ptr);
    *out_len = 0;
    return NULL;
}

static void utf8_append(Buf *b, uint32_t cp) {
    uint8_t s[4];
    size_t n;
    if (cp < 0x80) {
        s[0] = (uint8_t)cp;
        n = 1;
    } else if (cp < 0x800) {
        s[0] = 0xC0 | (cp >> 6);
        s[1] = 0x80 | (cp & 0x3F);
        n = 2;
    } else if (cp < 0x10000) {
        s[0] = 0xE0 | (cp >> 12);
        s[1] = 0x80 | ((cp >> 6) & 0x3F);
        s[2] = 0x80 | (cp & 0x3F);
        n = 3;
    } else {
        s[0] = 0xF0 | (cp >> 18);
        s[1] = 0x80 | ((cp >> 12) & 0x3F);
        s[2] = 0x80 | ((cp >> 6) & 0x3F);
        s[3] = 0x80 | (cp & 0x3F);
        n = 4;
    }
    buf_append(b, s, n);
}

char *umi_vt_plain(GhosttyTerminal t, size_t *out_len) {
    uint16_t cols = 0, rows = 0;
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    Buf b = {0};
    uint32_t cps[16];
    for (uint16_t y = 0; y < rows; y++) {
        size_t line_start = b.len;
        size_t last_nonspace = b.len;
        for (uint16_t x = 0; x < cols; x++) {
            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            GhosttyPoint pt = {.tag = GHOSTTY_POINT_TAG_ACTIVE,
                               .value = {.coordinate = {.x = x, .y = y}}};
            if (ghostty_terminal_grid_ref(t, pt, &ref) != GHOSTTY_SUCCESS)
                continue;
            GhosttyCell cell;
            if (ghostty_grid_ref_cell(&ref, &cell) != GHOSTTY_SUCCESS)
                continue;
            GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
            if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ||
                wide == GHOSTTY_CELL_WIDE_SPACER_HEAD)
                continue;
            size_t n = 0;
            if (ghostty_grid_ref_graphemes(&ref, cps, 16, &n) !=
                    GHOSTTY_SUCCESS ||
                n == 0) {
                buf_append(&b, (const uint8_t *)" ", 1);
                continue;
            }
            for (size_t i = 0; i < n && i < 16; i++) utf8_append(&b, cps[i]);
            if (!(n == 1 && cps[0] == ' ')) last_nonspace = b.len;
        }
        (void)line_start;
        b.len = last_nonspace;  // trim trailing spaces
        buf_append(&b, (const uint8_t *)"\n", 1);
    }
    buf_append(&b, (const uint8_t *)"", 1);  // NUL
    b.len -= 1;
    *out_len = b.len;
    return (char *)b.ptr;
}

static bool mode(GhosttyTerminal t, GhosttyMode m) {
    GhosttyTerminalModeConfig c = {.mode = m, .value = false};
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MODE, &c);
    return c.value;
}

void umi_vt_info(GhosttyTerminal t, UmiVtInfo *o) {
    memset(o, 0, sizeof(*o));
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &o->cols);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &o->rows);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &o->cursor_x);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &o->cursor_y);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE,
                         &o->cursor_visible);
    GhosttyTerminalScreen s = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &s);
    o->alternate = s == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS,
                         &o->kitty_flags);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
                         &o->mouse_tracking);
    o->bracketed_paste = mode(t, GHOSTTY_MODE_BRACKETED_PASTE);
    o->app_cursor_keys = mode(t, GHOSTTY_MODE_DECCKM);
}

static void color_str(Buf *b, const GhosttyStyleColor *c) {
    char s[32];
    int n;
    switch (c->tag) {
    case GHOSTTY_STYLE_COLOR_PALETTE:
        n = snprintf(s, sizeof s, "p%u", (unsigned)c->value.palette);
        break;
    case GHOSTTY_STYLE_COLOR_RGB:
        n = snprintf(s, sizeof s, "#%02x%02x%02x", c->value.rgb.r,
                     c->value.rgb.g, c->value.rgb.b);
        break;
    default:
        n = snprintf(s, sizeof s, "-");
    }
    buf_append(b, (const uint8_t *)s, (size_t)n);
}

char *umi_vt_styles(GhosttyTerminal t, size_t *out_len) {
    uint16_t cols = 0, rows = 0;
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    Buf b = {0};
    for (uint16_t y = 0; y < rows; y++) {
        for (uint16_t x = 0; x < cols; x++) {
            GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
            GhosttyPoint pt = {.tag = GHOSTTY_POINT_TAG_ACTIVE,
                               .value = {.coordinate = {.x = x, .y = y}}};
            GhosttyStyle st;
            memset(&st, 0, sizeof st);
            st.size = sizeof st;
            if (x) buf_append(&b, (const uint8_t *)" ", 1);
            GhosttyCell cell = 0;
            if (ghostty_terminal_grid_ref(t, pt, &ref) != GHOSTTY_SUCCESS ||
                ghostty_grid_ref_cell(&ref, &cell) != GHOSTTY_SUCCESS ||
                ghostty_grid_ref_style(&ref, &st) != GHOSTTY_SUCCESS) {
                buf_append(&b, (const uint8_t *)"?", 1);
                continue;
            }
            bool has_text = false;
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
            uint32_t cp = 0;
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
            if (cp == ' ') has_text = false;  // a space looks like an empty cell
            GhosttyCellContentTag tag = GHOSTTY_CELL_CONTENT_CODEPOINT;
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag);
            // What is visible: a blank cell shows only its background (an
            // erase with a background colour stores it in the cell itself)
            // plus inverse/underline/strikethrough.
            GhosttyStyleColor bg = st.bg_color;
            if (tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
                bg.tag = GHOSTTY_STYLE_COLOR_PALETTE;
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_COLOR_PALETTE, &bg.value.palette);
            } else if (tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
                bg.tag = GHOSTTY_STYLE_COLOR_RGB;
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_COLOR_RGB, &bg.value.rgb);
            }
            if (!has_text) {
                if (bg.tag == GHOSTTY_STYLE_COLOR_NONE && !st.inverse &&
                    !st.underline && !st.strikethrough) {
                    buf_append(&b, (const uint8_t *)".", 1);
                    continue;
                }
                buf_append(&b, (const uint8_t *)"_/", 2);
                color_str(&b, &bg);
                char f[16];
                int n = snprintf(f, sizeof f, "/%s%s%d", st.inverse ? "r" : "",
                                 st.strikethrough ? "s" : "", st.underline);
                buf_append(&b, (const uint8_t *)f, (size_t)n);
                continue;
            }
            if (ghostty_style_is_default(&st)) {
                buf_append(&b, (const uint8_t *)".", 1);
                continue;
            }
            color_str(&b, &st.fg_color);
            buf_append(&b, (const uint8_t *)"/", 1);
            color_str(&b, &bg);
            char f[16];
            int n = snprintf(f, sizeof f, "/%s%s%s%s%s%d", st.bold ? "b" : "",
                             st.italic ? "i" : "", st.faint ? "f" : "",
                             st.inverse ? "r" : "", st.strikethrough ? "s" : "",
                             st.underline);
            buf_append(&b, (const uint8_t *)f, (size_t)n);
        }
        buf_append(&b, (const uint8_t *)"\n", 1);
    }
    buf_append(&b, (const uint8_t *)"", 1);
    b.len -= 1;
    *out_len = b.len;
    return (char *)b.ptr;
}
