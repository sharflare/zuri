const std = @import("std");

// --- Terminal IO ---

pub fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch {};
}

pub fn confirmProceed(io: std.Io, yes: bool) bool {
    if (yes) return true;
    var ebuf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &ebuf);
    _ = w.interface.write("Proceed? [Y/n] ") catch {};
    w.flush() catch {};
    var input: [8]u8 = undefined;
    var rbuf: [256]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &rbuf);
    var read_bufs: [1][]u8 = .{input[0..]};
    const n = r.interface.readVec(&read_bufs) catch return true;
    return !(n > 0 and (input[0] == 'n' or input[0] == 'N'));
}
