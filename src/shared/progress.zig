const std = @import("std");

// --- Types ---

pub const StateTag = enum(u8) {
    pending,
    downloading,
    done,
    failed,
};

const winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

const Item = struct {
    label: []const u8,
    state: std.atomic.Value(u8),
    current: std.atomic.Value(u64),
    total: std.atomic.Value(u64),
};

const BAR_WIDTH: usize = 13;

// --- Terminal ---

fn termWidth() usize {
    var ws: winsize = undefined;
    if (std.os.linux.ioctl(2, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)) != 0)
        return 0;
    return @max(ws.col, 40);
}

fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@as(i64, @intCast(ms))), .awake) catch {};
}

fn stderrWrite(io: std.Io, bytes: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    _ = w.interface.write(bytes) catch {};
    w.flush() catch {};
}

// --- Size Formatting ---

fn sizeUnit(bytes: u64) struct { divisor: f64, suffix: []const u8 } {
    if (bytes >= 1_000_000_000) return .{ .divisor = 1_000_000_000, .suffix = "GB" };
    if (bytes >= 1_000_000) return .{ .divisor = 1_000_000, .suffix = "MB" };
    if (bytes >= 1_000) return .{ .divisor = 1_000, .suffix = "KB" };
    return .{ .divisor = 1, .suffix = "B" };
}

pub fn humanSize(buf: []u8, bytes: u64) []const u8 {
    const u = sizeUnit(bytes);
    const v = @as(f64, @floatFromInt(bytes)) / u.divisor;
    if (u.divisor == 1) return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, u.suffix }) catch return buf[0..0];
    if (u.divisor == 1_000) return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, u.suffix }) catch return buf[0..0];
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, u.suffix }) catch return buf[0..0];
}

fn fmtBytesProg(buf: []u8, current: u64, total: u64) []const u8 {
    const u = sizeUnit(total);
    const cur_v = @as(f64, @floatFromInt(current)) / u.divisor;
    const tot_v = @as(f64, @floatFromInt(total)) / u.divisor;
    if (u.divisor == 1) return std.fmt.bufPrint(buf, "{d}/{d} {s}", .{ current, total, u.suffix }) catch return buf[0..0];
    if (u.divisor == 1_000) return std.fmt.bufPrint(buf, "{d:.0}/{d:.0} {s}", .{ cur_v, tot_v, u.suffix }) catch return buf[0..0];
    return std.fmt.bufPrint(buf, "{d:.1}/{d:.1} {s}", .{ cur_v, tot_v, u.suffix }) catch return buf[0..0];
}

// --- Bar Rendering ---

fn formatBar(bar_buf: []u8, pct: u8, fill_char: u8, empty_char: u8) void {
    const filled = @min(@as(usize, @intCast(pct)) * BAR_WIDTH / 100, BAR_WIDTH);
    const remaining = BAR_WIDTH - filled;
    @memset(bar_buf[0..filled], fill_char);
    @memset(bar_buf[filled..][0..remaining], empty_char);
}

fn buildBarBlock(bar_block_buf: []u8, tag: StateTag, current: u64, total: u64) []const u8 {
    return switch (tag) {
        .pending => "",
        .downloading => {
            const pct: u8 = if (total > 0) @intCast(@min(current * 100 / @max(total, 1), 100)) else 0;
            var bar: [BAR_WIDTH]u8 = undefined;
            formatBar(&bar, pct, '/', '-');
            var size_buf: [32]u8 = undefined;
            const size_str = fmtBytesProg(&size_buf, current, total);
            const result = std.fmt.bufPrint(bar_block_buf, "[{s}] {d:>3}% {s}", .{ bar[0..], pct, size_str }) catch return "";
            return result;
        },
        .done => {
            var bar: [BAR_WIDTH]u8 = undefined;
            formatBar(&bar, 100, '/', '-');
            var size_buf: [32]u8 = undefined;
            const size_str = fmtBytesProg(&size_buf, total, total);
            const result = std.fmt.bufPrint(bar_block_buf, "[{s}] 100% {s}", .{ bar[0..], size_str }) catch return "";
            return result;
        },
        .failed => "",
    };
}

fn fmtFetchLine(buf: []u8, item: *const Item, label_width: usize, term_width: usize) []const u8 {
    const tag: StateTag = @enumFromInt(item.state.load(.monotonic));
    const current = item.current.load(.monotonic);
    const total = item.total.load(.monotonic);

    var prefix_buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "Fetching {s}", .{item.label}) catch return buf[0..0];

    var padded: [256]u8 = undefined;
    const max_pad = @min(prefix.len, label_width);
    @memcpy(padded[0..max_pad], prefix[0..max_pad]);
    if (label_width > prefix.len) {
        @memset(padded[prefix.len..label_width], ' ');
    }
    const padded_prefix = padded[0..label_width];

    if (tag == .failed)
        return std.fmt.bufPrint(buf, "{s} failed", .{padded_prefix}) catch return buf[0..0];

    if (tag == .pending)
        return std.fmt.bufPrint(buf, "{s}", .{padded_prefix}) catch return buf[0..0];

    var bar_block_buf: [128]u8 = undefined;
    const bar_block = buildBarBlock(&bar_block_buf, tag, current, total);

    // ralign bar
    if (term_width > 0) {
        const min_gap: usize = 1;
        const padding_needed = if (label_width + min_gap + bar_block.len < term_width)
            term_width - label_width - bar_block.len
        else
            min_gap;

        var full_buf: [1024]u8 = undefined;
        @memcpy(full_buf[0..label_width], padded_prefix);
        @memset(full_buf[label_width..][0..padding_needed], ' ');
        @memcpy(full_buf[label_width + padding_needed ..][0..bar_block.len], bar_block);
        const full = full_buf[0 .. label_width + padding_needed + bar_block.len];
        return std.fmt.bufPrint(buf, "{s}", .{full}) catch return buf[0..0];
    }

    return std.fmt.bufPrint(buf, "{s} {s}", .{ padded_prefix, bar_block }) catch return buf[0..0];
}

// --- Progress ---

pub const MultiProgress = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    items: []Item,
    label_width: usize,
    is_tty: bool,
    running: std.atomic.Value(u8),
    drawn: std.atomic.Value(u8),
    thread: ?std.Thread,
    term_width: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, labels: []const []const u8) !MultiProgress {
        const items = try allocator.alloc(Item, labels.len);
        errdefer allocator.free(items);
        var max_label: usize = 0;
        for (labels) |l| {
            const fetch_len = "Fetching ".len + l.len;
            if (fetch_len > max_label) max_label = fetch_len;
        }
        for (items, labels) |*item, label| {
            item.* = .{
                .label = try allocator.dupe(u8, label),
                .state = std.atomic.Value(u8).init(@intFromEnum(StateTag.pending)),
                .current = std.atomic.Value(u64).init(0),
                .total = std.atomic.Value(u64).init(0),
            };
        }
        return .{
            .allocator = allocator,
            .io = io,
            .items = items,
            .label_width = max_label,
            .is_tty = try std.Io.File.stderr().isTty(io),
            .running = std.atomic.Value(u8).init(0),
            .drawn = std.atomic.Value(u8).init(0),
            .thread = null,
            .term_width = termWidth(),
        };
    }

    pub fn deinit(self: *MultiProgress) void {
        self.stop();
        for (self.items) |item| {
            self.allocator.free(item.label);
        }
        self.allocator.free(self.items);
    }

    pub fn start(self: *MultiProgress) !void {
        self.running.store(1, .monotonic);
        if (self.is_tty and self.items.len > 0) {
            for (0..self.items.len) |i| {
                var line_buf: [512]u8 = undefined;
                const line = fmtFetchLine(&line_buf, &self.items[i], self.label_width, self.term_width);
                stderrWrite(self.io, "\r\x1b[K");
                stderrWrite(self.io, line);
                stderrWrite(self.io, "\n");
            }
            self.drawn.store(1, .monotonic);
            self.thread = try std.Thread.spawn(.{}, renderLoop, .{self});
        }
    }

    pub fn stop(self: *MultiProgress) void {
        self.running.store(0, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.items.len == 0) return;

        if (!self.is_tty) {
            for (0..self.items.len) |i| {
                const tag: StateTag = @enumFromInt(self.items[i].state.load(.monotonic));
                if (tag != .done and tag != .failed) {
                    var line_buf: [512]u8 = undefined;
                    const line = fmtFetchLine(&line_buf, &self.items[i], self.label_width, self.term_width);
                    stderrWrite(self.io, line);
                    stderrWrite(self.io, "\n");
                }
            }
        }
    }

    pub fn setTotal(self: *MultiProgress, idx: usize, total: u64) void {
        self.items[idx].total.store(total, .monotonic);
    }

    pub fn setCurrent(self: *MultiProgress, idx: usize, current: u64) void {
        self.items[idx].current.store(current, .monotonic);
    }

    pub fn setProgress(self: *MultiProgress, idx: usize, current: u64) void {
        self.items[idx].current.store(current, .monotonic);
        _ = self.items[idx].state.cmpxchgStrong(
            @intFromEnum(StateTag.pending),
            @intFromEnum(StateTag.downloading),
            .monotonic,
            .monotonic,
        );
    }

    pub fn setDone(self: *MultiProgress, idx: usize) void {
        self.items[idx].state.store(@intFromEnum(StateTag.done), .monotonic);
        if (!self.is_tty) {
            var line_buf: [512]u8 = undefined;
            const line = fmtFetchLine(&line_buf, &self.items[idx], self.label_width, self.term_width);
            stderrWrite(self.io, line);
            stderrWrite(self.io, "\n");
        }
    }

    pub fn setFailed(self: *MultiProgress, idx: usize) void {
        self.items[idx].state.store(@intFromEnum(StateTag.failed), .monotonic);
        if (!self.is_tty) {
            var line_buf: [512]u8 = undefined;
            const line = fmtFetchLine(&line_buf, &self.items[idx], self.label_width, self.term_width);
            stderrWrite(self.io, line);
            stderrWrite(self.io, "\n");
        }
    }

    pub fn anyFailed(self: *MultiProgress) bool {
        for (self.items) |*item| {
            if (@as(StateTag, @enumFromInt(item.state.load(.monotonic))) == .failed)
                return true;
        }
        return false;
    }

    fn renderAllInPlace(self: *MultiProgress) void {
        var up_buf: [32]u8 = undefined;
        const up = std.fmt.bufPrint(&up_buf, "\x1b[{d}A", .{self.items.len}) catch return;
        stderrWrite(self.io, up);
        for (0..self.items.len) |i| {
            var line_buf: [512]u8 = undefined;
            const line = fmtFetchLine(&line_buf, &self.items[i], self.label_width, self.term_width);
            stderrWrite(self.io, "\r\x1b[K");
            stderrWrite(self.io, line);
            stderrWrite(self.io, "\n");
        }
    }

    fn allFinished(self: *MultiProgress) bool {
        for (self.items) |*item| {
            const tag: StateTag = @enumFromInt(item.state.load(.monotonic));
            if (tag != .done and tag != .failed) return false;
        }
        return true;
    }

    fn renderLoop(self: *MultiProgress) void {
        while (self.running.load(.monotonic) != 0) {
            sleepMs(self.io, 100);
            if (self.drawn.load(.monotonic) == 0) continue;
            self.renderAllInPlace();
            if (self.allFinished()) break;
        }
        if (self.drawn.load(.monotonic) != 0) self.renderAllInPlace();
    }
};

pub fn printStep(io: std.Io, current: usize, total: usize, label: []const u8, status: []const u8) void {
    var buf2: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf2);
    if (total > 0) {
        w.interface.print("({d}/{d}) {s}... {s}\n", .{ current, total, label, status }) catch return;
    } else {
        w.interface.print("{s}... {s}\n", .{ label, status }) catch return;
    }
    w.flush() catch {};
}
