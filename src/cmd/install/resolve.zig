const std = @import("std");
const repo = @import("../../shared/repo.zig");
const xbps = @import("../../shared/xbps.zig");
const install_plan = @import("../../shared/install_plan.zig");
const shared_resolve = @import("../../shared/resolve.zig");

// --- Local ---

fn isXbpsFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".xbps");
}

const local_repo_dir = "/var/cache/xbps/local-repo";

fn setupLocalRepo(allocator: std.mem.Allocator, io: std.Io, local_paths: []const []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, local_repo_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    for (local_paths) |path| {
        const pkgver = try xbps.binpkgPkgver(allocator, path);
        defer allocator.free(pkgver);
        const arch = try xbps.binpkgArch(allocator, path);
        defer allocator.free(arch);

        const filename = try std.fmt.allocPrint(allocator, "{s}.{s}.xbps", .{ pkgver, arch });
        defer allocator.free(filename);
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ local_repo_dir, filename });
        defer allocator.free(dest);

        std.Io.Dir.copyFile(std.Io.Dir.cwd(), path, std.Io.Dir.cwd(), dest, io, .{ .replace = true }) catch |err| {
            var ebuf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &ebuf);
            w.interface.print("error copying {s} to local repo: {s}\n", .{ path, @errorName(err) }) catch {};
            w.flush() catch {};
            return err;
        };

        const rindex_result = std.process.run(allocator, io, .{
            .argv = &.{ "xbps-rindex", "-a", dest },
        }) catch |err| {
            var ebuf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &ebuf);
            w.interface.print("error running xbps-rindex: {s}\n", .{@errorName(err)}) catch {};
            w.flush() catch {};
            return err;
        };
        defer {
            allocator.free(rindex_result.stdout);
            allocator.free(rindex_result.stderr);
        }
        switch (rindex_result.term) {
            .exited => |code| {
                if (code != 0) {
                    var ebuf: [4096]u8 = undefined;
                    var w = std.Io.File.stderr().writer(io, &ebuf);
                    w.interface.print("xbps-rindex failed for {s} (exit code {d})\n", .{ path, code }) catch {};
                    w.flush() catch {};
                    return error.Unexpected;
                }
            },
            else => {
                var ebuf: [4096]u8 = undefined;
                var w = std.Io.File.stderr().writer(io, &ebuf);
                w.interface.print("xbps-rindex terminated abnormally for {s}\n", .{path}) catch {};
                w.flush() catch {};
                return error.Unexpected;
            },
        }
    }
}

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

    var local_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer local_paths.deinit(allocator);
    var remote_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer remote_names.deinit(allocator);

    for (pkg_names) |arg| {
        if (isXbpsFile(arg)) {
            std.Io.Dir.access(std.Io.Dir.cwd(), io, arg, .{}) catch {
                var ebuf: [4096]u8 = undefined;
                var w = std.Io.File.stderr().writer(io, &ebuf);
                w.interface.print("{s}: file not found\n", .{arg}) catch {};
                w.flush() catch {};
                return error.NotFound;
            };
            try local_paths.append(allocator, arg);
        } else {
            try remote_names.append(allocator, arg);
        }
    }

    const flags: c_int = @as(c_int, 0x00000080) | if (force) @as(c_int, 0x00000040) else 0;
    const xhp = try xbps.init(null, cachedir, flags);
    errdefer xbps.end(xhp);
    if (force) xbps.addFlags(xhp, xbps.Flag.force_unpack);

    if (local_paths.items.len > 0) {
        try setupLocalRepo(allocator, io, local_paths.items);
        var url_buf: [4096]u8 = undefined;
        const url_slice = try std.fmt.bufPrint(&url_buf, "file://{s}", .{local_repo_dir});
        url_buf[url_slice.len] = 0;
        try xbps.storeRepo(xhp, url_buf[0..url_slice.len :0]);
    }

    try xbps.storeRepo(xhp, repo_url);
    try xbps.syncRpoolQ(xhp);

    for (local_paths.items) |path| {
        const pkgver = try xbps.binpkgPkgver(allocator, path);
        defer allocator.free(pkgver);
        const dash_pos = std.mem.lastIndexOfScalar(u8, pkgver, '-') orelse return error.NotFound;
        const pkgname = pkgver[0..dash_pos];

        xbps.installPkgQ(xhp, pkgname, force) catch |err| switch (err) {
            error.AlreadyExists => {
                if (!force) continue;
                return err;
            },
            else => |e| return e,
        };
    }

    var not_found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer not_found.deinit(allocator);

    for (remote_names.items) |name| {
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
    };
}
