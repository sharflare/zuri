const std = @import("std");
const repo = @import("../../shared/repo.zig");
const xbps = @import("../../shared/xbps.zig");

pub fn exec(allocator: std.mem.Allocator, io: std.Io, repos: []const repo.Repo, query: []const u8) !void {
    const xhp = try xbps.init(null, "/var/cache/xbps", xbps.Flag.disable_syslog);
    defer xbps.end(xhp);

    for (repos) |r| {
        xbps.storeRepo(xhp, r.url) catch {};
    }
    try xbps.syncRpool(xhp);

    const results = try xbps.searchPkgs(allocator, xhp, query);
    defer {
        for (results) |r| {
            allocator.free(r.pkgver);
            allocator.free(r.short_desc);
            allocator.free(r.pkgname);
        }
        allocator.free(results);
    }

    if (results.len == 0)
        return;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);

    for (results) |r| {
        if (r.installed) {
            try w.interface.print("{s} [installed]\n  {s}\n", .{ r.pkgver, r.short_desc });
        } else {
            try w.interface.print("{s}\n  {s}\n", .{ r.pkgver, r.short_desc });
        }
    }

    try w.flush();
}
