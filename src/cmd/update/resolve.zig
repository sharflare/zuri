const std = @import("std");
const repo = @import("../../shared/repo.zig");
const xbps = @import("../../shared/xbps.zig");
const install_plan = @import("../../shared/install_plan.zig");
const sharedRslv = @import("../../shared/resolve.zig");

// --- Resolve Update ---

pub fn rslvUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    repos: []const repo.Repo,
) !install_plan.Plan {
    const cachedir = "/var/cache/xbps";

    const xhp = try xbps.init(null, cachedir, xbps.Flag.disable_syslog);
    errdefer xbps.end(xhp);

    for (repos) |r| {
        xbps.storeRepo(xhp, r.url) catch {};
    }
    try xbps.syncRpoolQ(xhp);

    xbps.updAllPkgs(xhp) catch |err| switch (err) {
        error.AlreadyExists => {
            return install_plan.Plan{
                .packages = &.{},
                .cachedir = cachedir,
                .xhp = xhp,
                .mode = .update,
            };
        },
        else => |e| return e,
    };

    try xbps.prepTxQ(xhp);

    const pkg_metas = try xbps.txPkgs(allocator, xhp);
    defer {
        for (pkg_metas) |p| {
            allocator.free(p.pkgver);
            allocator.free(p.filename);
            allocator.free(p.sha256);
            allocator.free(p.local_path);
            if (p.repo.len > 0) allocator.free(p.repo);
        }
        allocator.free(pkg_metas);
    }

    const downloads = try sharedRslv.buildDls(allocator, io, cachedir, pkg_metas);

    return install_plan.Plan{
        .packages = downloads,
        .cachedir = cachedir,
        .xhp = xhp,
        .mode = .update,
    };
}
