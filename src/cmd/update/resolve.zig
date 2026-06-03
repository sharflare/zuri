const std = @import("std");
const repo = @import("../../shared/repo.zig");
const xbps = @import("../../shared/xbps.zig");
const install_plan = @import("../../shared/install_plan.zig");
const shared_resolve = @import("../../shared/resolve.zig");

pub fn resolveForUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_url: [:0]const u8,
) !install_plan.InstallPlan {
    _ = io;
    const parsed = try repo.RepoUrl.parse(repo_url);
    const cachedir = "/var/cache/xbps";

    const xhp = try xbps.init(null, cachedir, xbps.Flag.disable_syslog);
    errdefer xbps.end(xhp);

    try xbps.repoStore(xhp, repo_url);
    try xbps.rpoolSyncQuiet(xhp);

    xbps.updateAllPkgs(xhp) catch |err| switch (err) {
        error.AlreadyExists => {
            return install_plan.InstallPlan{
                .packages = &.{},
                .repo_url = try allocator.dupe(u8, repo_url),
                .cachedir = cachedir,
                .xhp = xhp,
                .mode = .update,
            };
        },
        else => |e| return e,
    };

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
        .mode = .update,
    };
}
