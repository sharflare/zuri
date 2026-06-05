const std = @import("std");
const xbps = @import("../../shared/xbps.zig");
const stderrPrint = @import("../../shared/term.zig").stderrPrint;

fn printSize(io: std.Io, bytes: u64) void {
    const units = &[_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var val: f64 = @floatFromInt(bytes);
    var idx: usize = 0;
    while (val >= 1024.0 and idx < units.len - 1) {
        val /= 1024.0;
        idx += 1;
    }
    if (idx == 0) {
        stderrPrint(io, "{d} {s}", .{ bytes, units[idx] });
    } else {
        stderrPrint(io, "{d:.1} {s}", .{ val, units[idx] });
    }
}

fn cleanCache(io: std.Io, cachedir: []const u8, all: bool) !struct { count: usize, bytes: u64 } {
    var dir = try std.Io.Dir.openDirAbsolute(io, cachedir, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    var count: usize = 0;
    var bytes: u64 = 0;

    while (iter.next(io) catch null) |entry| {
        const name = entry.name;
        const is_xbps = std.mem.endsWith(u8, name, ".xbps");
        if (!is_xbps and !(all and std.mem.endsWith(u8, name, ".xbps.part"))) continue;

        if (dir.statFile(io, name, .{ .follow_symlinks = false }) catch null) |stat| {
            bytes += stat.size;
        }
        dir.deleteFile(io, name) catch {};
        count += 1;
    }

    return .{ .count = count, .bytes = bytes };
}

pub fn exec(allocator: std.mem.Allocator, io: std.Io, all_flag: bool, orphans: bool, dry_run: bool) !void {
    const cachedir = "/var/cache/xbps";

    if (orphans) {
        if (!dry_run and std.os.linux.geteuid() != 0) {
            stderrPrint(io, "error: orphan removal requires root (try 'sudo zuri clean --orphans')\n", .{});
            return;
        }

        const xhp = try xbps.init(null, cachedir, xbps.Flag.disable_syslog);
        defer xbps.end(xhp);

        try xbps.autoRemovePkgs(xhp);
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

        if (pkg_metas.len == 0) {
            stderrPrint(io, "no orphaned packages found\n", .{});
        } else {
            if (dry_run) {
                stderrPrint(io, "Orphaned packages ({d}): ", .{pkg_metas.len});
                for (pkg_metas, 0..) |p, i| {
                    if (i > 0) stderrPrint(io, ", ", .{});
                    stderrPrint(io, "{s}", .{p.pkgver});
                }
                stderrPrint(io, "\n", .{});
                stderrPrint(io, "dry-run: would remove {d} orphaned package{s}\n", .{
                    pkg_metas.len, if (pkg_metas.len == 1) "" else "s",
                });
            } else {
                stderrPrint(io, "Orphaned packages ({d}):\n", .{pkg_metas.len});
                for (pkg_metas) |p| {
                    stderrPrint(io, "  {s}\n", .{p.pkgver});
                }

                try xbps.txCommit(xhp);
                for (pkg_metas) |p| {
                    stderrPrint(io, "Removed {s}\n", .{p.pkgver});
                }
                try xbps.cfgPkgs(xhp);
                try xbps.pkgdbUpd(xhp, true, true);
                stderrPrint(io, "{d} orphaned package{s} removed.\n", .{
                    pkg_metas.len, if (pkg_metas.len == 1) "" else "s",
                });
            }
        }
    }

    if (dry_run) {
        stderrPrint(io, "dry-run: would clean cached packages from {s}\n", .{cachedir});
        if (all_flag) stderrPrint(io, "  (including partial downloads)\n", .{});
    } else {
        const result = cleanCache(io, cachedir, all_flag) catch |err| {
            stderrPrint(io, "error cleaning cache: {s}\n", .{@errorName(err)});
            return;
        };
        if (result.count > 0) {
            stderrPrint(io, "cleaned {d} cached package{s} (", .{ result.count, if (result.count == 1) "" else "s" });
            printSize(io, result.bytes);
            stderrPrint(io, ")\n", .{});
        } else {
            stderrPrint(io, "no cached packages to clean\n", .{});
        }
    }
}
