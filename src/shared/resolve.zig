const std = @import("std");
const dl = @import("download.zig");
const repo = @import("repo.zig");

// --- Build ---

pub fn buildDls(allocator: std.mem.Allocator, io: std.Io, parsed: repo.RepoUrl, cachedir: []const u8, pkg_metas: []const @import("xbps.zig").PkgDownload) ![]dl.PackageDownload {
    var downloads = try allocator.alloc(dl.PackageDownload, pkg_metas.len);
    errdefer allocator.free(downloads);

    for (pkg_metas, 0..) |meta, i| {
        const dash_pos = std.mem.lastIndexOfScalar(u8, meta.pkgver, '-') orelse
            return error.InvalidPkgver;

        if (meta.local_path.len > 0) {
            const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, meta.local_path, .{}) catch |err| {
                std.log.err("cannot open local package '{s}': {s}", .{ meta.local_path, @errorName(err) });
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
                .dest_path = try allocator.dupe(u8, meta.local_path),
                .sha256 = try allocator.dupe(u8, ""),
                .local_path = try allocator.dupe(u8, meta.local_path),
            };
        } else {
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
