const std = @import("std");
const dl = @import("download.zig");
const repo = @import("repo.zig");
const PkgDownload = @import("xbps.zig").PkgDownload;

pub fn buildDls(allocator: std.mem.Allocator, io: std.Io, cachedir: []const u8, pkg_metas: []const PkgDownload) ![]dl.PkgDl {
    var downloads = try allocator.alloc(dl.PkgDl, pkg_metas.len);
    errdefer allocator.free(downloads);

    for (pkg_metas, 0..) |meta, i| {
        const dash_pos = std.mem.lastIndexOfScalar(u8, meta.pkgver, '-') orelse
            return error.InvalidPkgver;

        const local = meta.local_path.len > 0 or
            (meta.repo.len > 0 and meta.repo[0] == '/');

        if (local) {
            const base = if (meta.local_path.len > 0) meta.local_path else meta.repo;
            const lp = if (meta.local_path.len > 0) base else lp: {
                var buf: [4096]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ base, meta.filename });
                break :lp try allocator.dupe(u8, s);
            };
            defer if (meta.local_path.len == 0) allocator.free(lp);

            const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, lp, .{}) catch |err| {
                std.log.err("cannot open local package '{s}': {s}", .{ lp, @errorName(err) });
                return error.NotFound;
            };
            defer file.close(io);
            const st = try file.stat(io);
            downloads[i] = .{
                .name = try allocator.dupe(u8, meta.pkgver[0..dash_pos]),
                .version = try allocator.dupe(u8, meta.pkgver[dash_pos + 1 ..]),
                .host = try allocator.dupe(u8, ""),
                .port = 0,
                .path = try allocator.dupe(u8, ""),
                .size = st.size,
                .dest_path = try allocator.dupe(u8, lp),
                .sha256 = try allocator.dupe(u8, ""),
                .local_path = try allocator.dupe(u8, lp),
            };
        } else {
            const parsed = repo.parseRepoUrl(meta.repo) catch |err| {
                std.log.err("invalid repository URL '{s}' for {s}", .{ meta.repo, meta.pkgver });
                return err;
            };

            downloads[i] = .{
                .name = try allocator.dupe(u8, meta.pkgver[0..dash_pos]),
                .version = try allocator.dupe(u8, meta.pkgver[dash_pos + 1 ..]),
                .host = try allocator.dupe(u8, parsed.host),
                .port = parsed.port,
                .path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ parsed.path_prefix, meta.filename }),
                .size = meta.size,
                .dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cachedir, meta.filename }),
                .sha256 = try allocator.dupe(u8, meta.sha256),
                .local_path = try allocator.dupe(u8, ""),
            };
        }
    }
    return downloads;
}
