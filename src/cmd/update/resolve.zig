const std = @import("std");
const repo = @import("../../shared/repo.zig");
const xbps = @import("../../shared/xbps.zig");
const install_plan = @import("../../shared/install_plan.zig");
const shared_resolve = @import("../../shared/resolve.zig");

// --- Resolve Update ---

pub fn rslvUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_url: [:0]const u8,
) !install_plan.Plan {
    const parsed = try repo.RepoUrl.parse(repo_url);
    const cachedir = "/var/cache/xbps";

    const xhp = try xbps.init(null, cachedir, xbps.Flag.disable_syslog);
    errdefer xbps.end(xhp);

    try xbps.storeRepo(xhp, repo_url);
    try xbps.syncRpoolQ(xhp);

    xbps.updAllPkgs(xhp) catch |err| switch (err) {
        error.AlreadyExists => {
            return install_plan.Plan{
                .packages = &.{},
                .repo_url = try allocator.dupe(u8, repo_url),
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
        }
        allocator.free(pkg_metas);
    }

    const downloads = try shared_resolve.buildDls(allocator, io, parsed, cachedir, pkg_metas);

    return install_plan.Plan{
        .packages = downloads,
        .repo_url = try allocator.dupe(u8, repo_url),
        .cachedir = cachedir,
        .xhp = xhp,
        .mode = .update,
    };
}
