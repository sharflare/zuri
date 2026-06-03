const std = @import("std");
const repo = @import("../../shared/repo.zig");
const xbps = @import("../../shared/xbps.zig");
const install_plan = @import("../../shared/install_plan.zig");
const shared_resolve = @import("../../shared/resolve.zig");

pub fn resolveForInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_url: [:0]const u8,
    pkg_names: []const []const u8,
) !install_plan.InstallPlan {
    const parsed = try repo.RepoUrl.parse(repo_url);
    const cachedir = "/var/cache/xbps";

    const xhp = try xbps.init(null, cachedir, xbps.Flag.disable_syslog);
    errdefer xbps.end(xhp);

    try xbps.repoStore(xhp, repo_url);
    try xbps.rpoolSyncQuiet(xhp);

    var not_found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer not_found.deinit(allocator);

    for (pkg_names) |name| {
        xbps.installPkgQuiet(xhp, name, false) catch |err| switch (err) {
            error.AlreadyExists => continue,
            error.NotFound => {
                try not_found.append(allocator, name);
                continue;
            },
            else => |e| return e,
        };
    }

    if (not_found.items.len > 0) {
        var ebuf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &ebuf);
        for (not_found.items) |name| {
            w.interface.print("{s}: not found in repositories\n", .{name}) catch {};
        }
        w.flush() catch {};
        return error.NotFound;
    }

    try xbps.transactionPrepareQuiet(xhp);

    const pkg_metas = try xbps.transactionPkgs(allocator, xhp);
    defer {
        for (pkg_metas) |p| {
            allocator.free(p.pkgver);
            allocator.free(p.filename);
            allocator.free(p.sha256);
        }
        allocator.free(pkg_metas);
    }

    const downloads = try shared_resolve.buildDownloads(allocator, parsed, cachedir, pkg_metas);

    return install_plan.InstallPlan{
        .packages = downloads,
        .repo_url = try allocator.dupe(u8, repo_url),
        .cachedir = cachedir,
        .xhp = xhp,
    };
}
