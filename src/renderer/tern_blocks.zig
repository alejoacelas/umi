//! Tern: Warp's look for terminals.
//!
//! Tern's zsh integration prints each prompt as two spacer rows, the
//! folder and an empty command line, and marks its first row with OSC
//! 133;A;tern=1 (see Terminal.ternPromptStarted). This works out, from the
//! terminal, where those blocks are in the viewport and how far down the
//! view sits so the last used row is at the bottom. The renderer draws
//! from it: a separator above each block, the folder as a header with
//! the command's duration (or as a box at the prompt), the command in
//! bold, and a tint with a bar for commands that failed. Nothing is
//! written to the terminal, so programs reading the pane see what the
//! shell printed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const Pin = terminal.Pin;
const PageRow = terminal.page.Row;

/// What a viewport row is in its block.
pub const Role = enum(u8) {
    /// Not in a block (the look is off, or no block starts above).
    none,
    /// The block's first spacer row: the space below the block above.
    spacer_top,
    /// The second spacer row; the separator is drawn along its top.
    spacer,
    /// The folder: the block's header, or the folder box at the prompt.
    header,
    /// The command line (more than one row for long or multi-line ones).
    command,
    /// What the command printed.
    output,
};

pub const State = enum(u8) {
    /// The prompt the user is typing at.
    active,
    /// A prompt left behind without running anything (Ctrl-C, Enter on
    /// an empty line).
    prompt,
    running,
    done,
};

pub const Block = struct {
    /// Viewport row of the block's first row; negative when it starts
    /// above the viewport.
    first: i32,
    state: State,
    failed: bool,
    /// How long the command took (done) or has run so far in whole
    /// seconds (running). Null when unknown.
    ms: ?u64,
    /// The block's first row. Valid only while the terminal stays locked.
    start: ?Pin = null,
};

pub const Row = struct {
    role: Role = .none,
    /// Index in `Layout.blocks` (meaningless when role is none).
    block: u16 = 0,

    pub fn eql(a: Row, b: Row) bool {
        return a.role == b.role and a.block == b.block;
    }
};

/// What a row was drawn as. When it changes the row is drawn again: the
/// header shows the folder box at the prompt and the duration after it
/// ran; the command is bold once it ran.
pub const Drawn = struct {
    role: Role = .none,
    state: State = .prompt,
    ms: ?u64 = null,

    pub fn eql(a: Drawn, b: Drawn) bool {
        return a.role == b.role and a.state == b.state and a.ms == b.ms;
    }
};

/// How many rows above the viewport to look for the start of the block
/// the viewport begins in.
const lookback_rows = 4096;

pub const Layout = struct {
    /// True when the look applies to what the terminal shows now.
    on: bool = false,

    /// How many rows the view is moved down so the last used row (or
    /// the cursor's) sits at the bottom.
    offset_rows: u16 = 0,

    /// One entry per viewport row.
    rows: std.ArrayList(Row) = .empty,
    blocks: std.ArrayList(Block) = .empty,

    /// Milliseconds until a running block's elapsed time next changes,
    /// when one is visible.
    tick_ms: ?u64 = null,

    pub fn deinit(self: *Layout, alloc: Allocator) void {
        self.rows.deinit(alloc);
        self.blocks.deinit(alloc);
    }

    pub fn block(self: *const Layout, r: Row) ?*const Block {
        if (r.role == .none) return null;
        return &self.blocks.items[r.block];
    }

    /// The row at viewport row `y`.
    pub fn row(self: *const Layout, y: usize) Row {
        if (y >= self.rows.items.len) return .{};
        return self.rows.items[y];
    }

    /// What viewport row `y` is drawn as.
    pub fn drawn(self: *const Layout, y: usize) Drawn {
        const r = self.row(y);
        const b = self.block(r) orelse return .{};
        return switch (r.role) {
            .header => .{ .role = .header, .state = b.state, .ms = b.ms },
            .command => .{ .role = .command, .state = if (b.state == .active) .active else .done },
            else => .{ .role = r.role },
        };
    }

    /// Work out the layout for the viewport whose rows are `pins`. Must
    /// be called with the terminal locked.
    pub fn compute(
        self: *Layout,
        alloc: Allocator,
        t: *Terminal,
        pins: []const Pin,
        cursor_y: ?usize,
        now: std.Io.Timestamp,
    ) Allocator.Error!void {
        self.on = false;
        self.offset_rows = 0;
        self.tick_ms = null;
        self.blocks.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        try self.rows.appendNTimes(alloc, .{}, pins.len);

        if (!t.ternBlocksActive() or pins.len == 0) return;
        self.on = true;

        const screen = t.screens.active;

        // The view sits at the bottom: the cursor's row, or the last row
        // below it that has anything (a completion list below the
        // prompt, a program's status line), is the last row shown.
        if (cursor_y) |cy| {
            var last: usize = cy;
            var y: usize = pins.len - 1;
            while (y > cy) : (y -= 1) {
                if (rowHasContent(pins[y])) {
                    last = y;
                    break;
                }
            }
            self.offset_rows = @intCast(pins.len - 1 - last);
        }

        // The block the viewport starts in may start above it.
        var current: ?u16 = null;
        var in_command = false;
        // How many rows the block's folder took (a long one wraps), so the
        // command starts after it.
        var header_rows: i32 = 1;
        {
            var p = pins[0];
            var d: i32 = 0;
            while (d < lookback_rows) {
                p = p.up(1) orelse break;
                d += 1;
                // Scrollback compressed out of view isn't restored for this:
                // the block starting above it stays unknown.
                if (p.node.pageIfResident() == null) break;
                if (isBlockStart(p)) {
                    current = try self.addBlock(alloc, screen, p, -d, now);
                    // Its folder may wrap into the viewport.
                    var h = p.down(2);
                    while (h) |row_pin| {
                        if (!row_pin.rowAndCell().row.wrap) break;
                        header_rows += 1;
                        h = row_pin.down(1);
                    }
                    break;
                }
            }
        }

        for (pins, 0..) |pin, y_usize| {
            const y: i32 = @intCast(y_usize);
            const page_row = pin.rowAndCell().row;
            if (isBlockStart(pin)) {
                current = try self.addBlock(alloc, screen, pin, y, now);
                header_rows = 1;
            }
            const index = current orelse continue;
            const b = self.blocks.items[index];
            const rel = y - b.first;
            // A row continuing a wrapped folder is header too.
            if (rel == 2 + header_rows and page_row.wrap_continuation) header_rows += 1;
            const role: Role = switch (rel) {
                0 => .spacer_top,
                1 => .spacer,
                else => if (rel < 2 + header_rows) .header else if (rel == 2 + header_rows) command: {
                    in_command = true;
                    break :command .command;
                } else role: {
                    // Continuation lines of the command are prompt rows;
                    // the command ends at the first row of output.
                    if ((in_command or y == 0) and page_row.semantic_prompt != .none) {
                        in_command = true;
                        break :role .command;
                    }
                    in_command = false;
                    break :role .output;
                },
            };
            self.rows.items[y_usize] = .{ .role = role, .block = index };
        }
    }

    fn addBlock(
        self: *Layout,
        alloc: Allocator,
        screen: *const terminal.Screen,
        pin: Pin,
        first: i32,
        now: std.Io.Timestamp,
    ) Allocator.Error!u16 {
        const page_row = pin.rowAndCell().row;
        const newest = if (screen.tern_block_pin) |p|
            !p.garbage and p.node == pin.node and p.y == pin.y
        else
            false;

        var b: Block = .{
            .first = first,
            .state = .prompt,
            .failed = false,
            .ms = null,
            .start = pin,
        };
        switch (page_row.tern_state) {
            .prompt => if (newest and screen.cursor.semantic_content != .output) {
                b.state = .active;
            },
            .running => {
                b.state = .running;
                if (newest) if (screen.tern_block_started) |started| {
                    const ns = started.durationTo(now).nanoseconds;
                    const ms: u64 = @intCast(@max(0, @divTrunc(ns, std.time.ns_per_ms)));
                    b.ms = ms / 1000 * 1000;
                    const next = 1000 - ms % 1000;
                    self.tick_ms = if (self.tick_ms) |t| @min(t, next) else next;
                };
            },
            .done => {
                b.state = .done;
                b.failed = page_row.tern_failed;
                b.ms = page_row.ternDurationMs();
            },
        }

        const index: u16 = @intCast(@min(self.blocks.items.len, std.math.maxInt(u16)));
        if (self.blocks.items.len < std.math.maxInt(u16)) try self.blocks.append(alloc, b);
        return index;
    }
};

fn isBlockStart(pin: Pin) bool {
    const row = pin.rowAndCell().row;
    return row.tern_block and row.semantic_prompt == .prompt;
}

fn rowHasContent(pin: Pin) bool {
    const cells = pin.cells(.all);
    for (cells) |cell| if (!cell.isEmpty() or cell.hasStyling()) return true;
    return false;
}

/// Warp's format for a block's duration, with its leading space:
/// " (0.041s)", " (1m 8.92s)", " (3h 4m 12s)", " (10h 43s)".
pub fn formatDuration(buf: []u8, ms: u64) []const u8 {
    const hours = ms / std.time.ms_per_hour;
    const minutes = (ms / std.time.ms_per_min) % 60;
    const in_minute = ms % std.time.ms_per_min;
    if (hours > 0) {
        const secs = (in_minute + 500) / 1000;
        if (minutes > 0) {
            return std.fmt.bufPrint(buf, " ({d}h {d}m {d}s)", .{ hours, minutes, secs }) catch "";
        }
        return std.fmt.bufPrint(buf, " ({d}h {d}s)", .{ hours, secs }) catch "";
    }
    if (minutes > 0) {
        const cs = (in_minute + 5) / 10;
        return std.fmt.bufPrint(buf, " ({d}m {d}.{d:0>2}s)", .{ minutes, cs / 100, cs % 100 }) catch "";
    }

    // Seconds with the shortest decimals: 0.041, 2, 16.471.
    var frac = ms % 1000;
    var digits: usize = 3;
    while (digits > 0 and frac % 10 == 0) {
        frac /= 10;
        digits -= 1;
    }
    if (digits == 0) return std.fmt.bufPrint(buf, " ({d}s)", .{ms / 1000}) catch "";
    return switch (digits) {
        1 => std.fmt.bufPrint(buf, " ({d}.{d}s)", .{ ms / 1000, frac }) catch "",
        2 => std.fmt.bufPrint(buf, " ({d}.{d:0>2}s)", .{ ms / 1000, frac }) catch "",
        else => std.fmt.bufPrint(buf, " ({d}.{d:0>3}s)", .{ ms / 1000, frac }) catch "",
    };
}

/// `a` moved toward `b` by `t` (0–1).
pub fn mix(a: terminal.color.RGB, b: terminal.color.RGB, t: f32) terminal.color.RGB {
    const f = struct {
        fn c(x: u8, y: u8, w: f32) u8 {
            const xf: f32 = @floatFromInt(x);
            const yf: f32 = @floatFromInt(y);
            return @intFromFloat(@round(xf + (yf - xf) * w));
        }
    };
    return .{ .r = f.c(a.r, b.r, t), .g = f.c(a.g, b.g, t), .b = f.c(a.b, b.b, t) };
}

test "formatDuration" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(" (0.041s)", formatDuration(&buf, 41));
    try testing.expectEqualStrings(" (2s)", formatDuration(&buf, 2000));
    try testing.expectEqualStrings(" (0s)", formatDuration(&buf, 0));
    try testing.expectEqualStrings(" (16.471s)", formatDuration(&buf, 16471));
    try testing.expectEqualStrings(" (4.88s)", formatDuration(&buf, 4880));
    try testing.expectEqualStrings(" (4.9s)", formatDuration(&buf, 4900));
    try testing.expectEqualStrings(" (1m 8.92s)", formatDuration(&buf, 68920));
    try testing.expectEqualStrings(" (1m 0.00s)", formatDuration(&buf, 60000));
    try testing.expectEqualStrings(" (3h 4m 12s)", formatDuration(&buf, 3 * 3600_000 + 4 * 60_000 + 12_000));
    try testing.expectEqualStrings(" (10h 43s)", formatDuration(&buf, 10 * 3600_000 + 43_000));
}

test "row duration units" {
    const testing = std.testing;
    var row: PageRow = .{ .cells = undefined };
    for ([_]u64{ 0, 41, 131_071, 131_072, 600_000, 1_310_710, 3_600_000, 50_000_000 }) |ms| {
        row.ternSetDurationMs(ms);
        const back = row.ternDurationMs();
        try testing.expect(back <= ms);
        try testing.expect(ms - back < 1000);
    }
    row.ternSetDurationMs(41);
    try testing.expectEqual(@as(u64, 41), row.ternDurationMs());
}

test "a folder wrapped over rows above the viewport stays header" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try Terminal.init(testing.io, alloc, .{ .cols = 6, .rows = 5 });
    defer t.deinit(alloc);
    t.flags.tern_blocks = true;

    {
        var s = t.vtStream();
        defer s.deinit();
        // Tern's prompt: two spacers, a folder that wraps over three rows,
        // the command; then ten lines of output and the next prompt's start.
        s.nextSlice("\x1b]133;A;cl=line;tern=1\x07\r\n\x1b]133;P;k=s\x07\r\n\x1b]133;P;k=s\x07");
        s.nextSlice("abcdefghijklmnopq");
        s.nextSlice("\r\n\x1b]133;P;k=s\x07\x1b]133;B\x07ls\r\n\x1b]133;C\x07");
        for (0..10) |i| {
            var buf: [8]u8 = undefined;
            s.nextSlice(std.fmt.bufPrint(&buf, "o{d}\r\n", .{i}) catch unreachable);
        }
    }

    // Rows: S1 S2 H1 H2 H3 C o0 … o9, then the cursor's row. Show H3 first.
    t.scrollViewport(.{ .delta = -8 });
    const screen = t.screens.active;
    var pins: [5]Pin = undefined;
    var p = screen.pages.getTopLeft(.viewport);
    for (&pins) |*pin| {
        pin.* = p;
        p = p.down(1) orelse p;
    }

    var layout: Layout = .{};
    defer layout.deinit(alloc);
    try layout.compute(alloc, &t, &pins, null, .{ .nanoseconds = 0 });
    try testing.expect(layout.on);
    try testing.expectEqual(Role.header, layout.row(0).role);
    try testing.expectEqual(Role.command, layout.row(1).role);
    try testing.expectEqual(Role.output, layout.row(2).role);
}
