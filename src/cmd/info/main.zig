const std = @import("std");
const xbps = @import("../../shared/xbps.zig");
const progress = @import("../../shared/progress.zig");
const stderrPrint = @import("../../shared/term.zig").stderrPrint;

pub fn exec(allocator: std.mem.Allocator, io: std.Io, pkg_name: []const u8) !void {
    const xhp = try xbps.init(null, "/var/cache/xbps", xbps.Flag.disable_syslog);
    defer xbps.end(xhp);

    const info = try xbps.pkgInfo(allocator, xhp, pkg_name) orelse {
        stderrPrint(io, "{s}: not found\n", .{pkg_name});
        return;
    };
    defer {
        allocator.free(info.pkgver);
        allocator.free(info.short_desc);
        allocator.free(info.homepage);
        allocator.free(info.license);
        allocator.free(info.repository);
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);

    try w.interface.print("{s}", .{info.pkgver});
    if (info.installed) try w.interface.print(" [installed]", .{});
    try w.interface.print("\n", .{});

    if (info.short_desc.len > 0)
        try w.interface.print("  {s}\n", .{info.short_desc});
    if (info.homepage.len > 0)
        try w.interface.print("  Homepage: {s}\n", .{info.homepage});
    if (info.license.len > 0)
        try w.interface.print("  License: {s}\n", .{info.license});

    if (info.installed_size > 0) {
        var size_buf: [32]u8 = undefined;
        const size_str = progress.humanSize(&size_buf, info.installed_size);
        try w.interface.print("  Installed size: {s}\n", .{size_str});
    }

    if (info.repository.len > 0)
        try w.interface.print("  Repository: {s}\n", .{info.repository});

    try w.flush();
}
