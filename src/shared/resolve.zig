const std = @import("std");
const dl = @import("download.zig");
const repo = @import("repo.zig");

// --- Build ---

pub fn buildDls(allocator: std.mem.Allocator, parsed: repo.RepoUrl, cachedir: []const u8, pkg_metas: []const @import("xbps.zig").PkgDownload) ![]dl.PackageDownload {
    var downloads = try allocator.alloc(dl.PackageDownload, pkg_metas.len);
    errdefer allocator.free(downloads);

    for (pkg_metas, 0..) |meta, i| {
        const dash_pos = std.mem.lastIndexOfScalar(u8, meta.pkgver, '-') orelse
            return error.InvalidPkgver;

        downloads[i] = .{
            .name = try allocator.dupe(u8, meta.pkgver[0..dash_pos]),
            .version = try allocator.dupe(u8, meta.pkgver[dash_pos + 1 ..]),
            .host = try allocator.dupe(u8, parsed.host),
            .port = parsed.port,
            .path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ parsed.path_prefix, meta.filename }),
            .size = meta.size,
            .dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cachedir, meta.filename }),
            .sha256 = try allocator.dupe(u8, meta.sha256),
        };
    }
    return downloads;
}
