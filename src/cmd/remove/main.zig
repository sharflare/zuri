const std = @import("std");
const xbps = @import("../../shared/xbps.zig");
const term = @import("../../shared/term.zig");

const stderrPrint = term.stderrPrint;
const confirmProceed = term.confirmProceed;

// --- Exec ---

pub fn exec(gpa: std.mem.Allocator, io: std.Io, pkg_names: []const []const u8, keep_deps: bool, dry_run: bool, yes: bool, rootdir: ?[]const u8) !void {
    if (pkg_names.len == 0) {
        stderrPrint(io, "remove: no packages specified\n", .{});
        return;
    }

    const cachedir = "/var/cache/xbps";
    const xhp = try xbps.init(rootdir, cachedir, xbps.Flag.disable_syslog);
    errdefer xbps.end(xhp);

    for (pkg_names) |name| {
        xbps.removePkg(xhp, name, false) catch |err| switch (err) {
            error.NotFound => {
                stderrPrint(io, "{s}: package not found\n", .{name});
                return;
            },
            else => |e| return e,
        };
    }

    if (!keep_deps) {
        xbps.autoRemovePkgs(xhp) catch |err| switch (err) {
            error.AlreadyExists => {},
            else => |e| return e,
        };
    }

    try xbps.prepTxQ(xhp);

    const pkg_metas = try xbps.txPkgs(gpa, xhp);
    defer {
        for (pkg_metas) |p| {
            gpa.free(p.pkgver);
            gpa.free(p.filename);
            gpa.free(p.sha256);
            gpa.free(p.local_path);
        }
        gpa.free(pkg_metas);
    }

    if (dry_run) {
        stderrPrint(io, "Packages to remove ({d}): ", .{pkg_metas.len});
        for (pkg_metas, 0..) |p, i| {
            if (i > 0) stderrPrint(io, ", ", .{});
            stderrPrint(io, "{s}", .{p.pkgver});
        }
        stderrPrint(io, "\n", .{});
        stderrPrint(io, "dry-run: would remove {d} package{s}\n", .{
            pkg_metas.len, if (pkg_metas.len == 1) "" else "s",
        });
        return;
    }

    if (pkg_metas.len == 0) {
        stderrPrint(io, "nothing to remove\n", .{});
        return;
    }

    stderrPrint(io, "Packages to remove ({d}):\n", .{pkg_metas.len});
    for (pkg_metas) |p| {
        stderrPrint(io, "  {s}\n", .{p.pkgver});
    }

    if (!confirmProceed(io, yes)) {
        stderrPrint(io, "aborted.\n", .{});
        return;
    }

    try xbps.txCommit(xhp);

    for (pkg_metas) |p| {
        stderrPrint(io, "Removed {s}\n", .{p.pkgver});
    }

    try xbps.cfgPkgs(xhp);
    try xbps.pkgdbUpd(xhp, true, true);

    stderrPrint(io, "{d} package{s} removed.\n", .{
        pkg_metas.len, if (pkg_metas.len == 1) "" else "s",
    });
}
