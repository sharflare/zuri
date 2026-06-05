const std = @import("std");

pub var REQUESTED = std.atomic.Value(bool).init(false);

fn handler(sig: std.os.linux.SIG) callconv(.c) void {
    _ = sig;
    REQUESTED.store(true, .monotonic);
}

pub fn setup() void {
    const set = std.mem.zeroes(std.os.linux.sigset_t);
    const sa = std.os.linux.Sigaction{
        .handler = .{ .handler = handler },
        .mask = set,
        .flags = 0,
    };
    _ = std.os.linux.sigaction(.INT, &sa, null);
    _ = std.os.linux.sigaction(.TERM, &sa, null);
}

pub fn isCancelled() bool {
    return REQUESTED.load(.monotonic);
}

pub fn reset() void {
    REQUESTED.store(false, .monotonic);
}
