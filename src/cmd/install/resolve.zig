const std = @import("std");
const repo = @import("../../shared/repo.zig");
const xbps = @import("../../shared/xbps.zig");
const install_plan = @import("../../shared/install_plan.zig");
const shared_resolve = @import("../../shared/resolve.zig");

// --- Resolve Install ---

pub fn rslvInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_url: [:0]const u8,
    pkg_names: []const []const u8,
    force: bool,
) !install_plan.Plan {
    const parsed = try repo.RepoUrl.parse(repo_url);
    const cachedir = "/var/cache/xbps";

    const flags: c_int = @as(c_int, 0x00000080) | if (force) @as(c_int, 0x00000040) else 0;
    const xhp = try xbps.init(null, cachedir, flags);
    errdefer xbps.end(xhp);
    if (force) xbps.addFlags(xhp, xbps.Flag.force_unpack);

    try xbps.storeRepo(xhp, repo_url);
    try xbps.syncRpoolQ(xhp);

    var not_found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer not_found.deinit(allocator);

    for (pkg_names) |name| {
        xbps.installPkgQ(xhp, name, force) catch |err| switch (err) {
            error.AlreadyExists => {
                if (!force) continue;
                return err;
            },
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

    try xbps.prepTxQ(xhp);

    const pkg_metas = try xbps.txPkgs(allocator, xhp);
    defer {
        for (pkg_metas) |p| {
            allocator.free(p.pkgver);
            allocator.free(p.filename);
            allocator.free(p.sha256);
        }
        allocator.free(pkg_metas);
    }

    const downloads = try shared_resolve.buildDls(allocator, parsed, cachedir, pkg_metas);

    return install_plan.Plan{
        .packages = downloads,
        .repo_url = try allocator.dupe(u8, repo_url),
        .cachedir = cachedir,
        .xhp = xhp,
    };
}
