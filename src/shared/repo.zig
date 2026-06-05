const std = @import("std");
const builtin = @import("builtin");

pub const RepoUrl = struct {
    host: []const u8,
    port: u16,
    path_prefix: []const u8,

    pub fn parse(url: []const u8) !RepoUrl {
        const after_scheme = url[std.mem.indexOf(u8, url, "://").? + 3 ..];
        const colon_or_slash = std.mem.indexOfAny(u8, after_scheme, ":/") orelse return error.InvalidRepoUrl;
        const host = after_scheme[0..colon_or_slash];
        const rest = after_scheme[colon_or_slash..];
        const result: RepoUrl = if (rest[0] == ':') blk: {
            const port_end = (std.mem.indexOfScalar(u8, rest[1..], '/') orelse rest.len - 1) + 1;
            const port = try std.fmt.parseInt(u16, rest[1..port_end], 10);
            break :blk .{
                .host = host,
                .port = port,
                .path_prefix = rest[port_end..],
            };
        } else .{
            .host = host,
            .port = 443,
            .path_prefix = rest,
        };
        return result;
    }
};

fn getRepoDir() ?[]const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => switch (builtin.abi) {
            .musl => "musl",
            .gnu => "",
            else => null,
        },
        else => null,
    };
}

pub fn parseRepoUrl(url: []const u8) !RepoUrl {
    return RepoUrl.parse(url);
}

pub const Repo = struct {
    url: [:0]const u8,
};

pub fn loadRepos(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stderr: anytype,
) ![]Repo {
    if (environ.getPosix("ZURI_REPO_URL")) |base| {
        return loadSingleRepo(allocator, base, stderr);
    }
    if (!hasConfigRepos(io)) {
        try stderr.print("error: no repositories found in /etc/xbps.d/ or ZURI_REPO_URL\n", .{});
        return error.NoReposConfigured;
    }
    return &.{};
}

fn hasConfigRepos(io: std.Io) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, "/etc/xbps.d", .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf"))
            return true;
    }
    return false;
}

fn loadSingleRepo(allocator: std.mem.Allocator, base: []const u8, stderr: anytype) ![]Repo {
    const repo_dir = getRepoDir() orelse {
        try stderr.print("error: unsupported architecture ({s}, {s})\n", .{
            @tagName(builtin.cpu.arch), @tagName(builtin.abi),
        });
        return error.UnsupportedArchitecture;
    };

    if (repo_dir.len == 0) {
        const result = try allocator.alloc(Repo, 1);
        result[0] = .{ .url = try ntDup(allocator, base) };
        return result;
    }

    const need_sep = base.len == 0 or base[base.len - 1] != '/';
    const sep_len: usize = if (need_sep) 1 else 0;
    const url_len = base.len + sep_len + repo_dir.len + 1;
    const buf = try allocator.alloc(u8, url_len + 1);
    @memcpy(buf[0..base.len], base);
    var pos = base.len;
    if (need_sep) {
        buf[pos] = '/';
        pos += 1;
    }
    @memcpy(buf[pos..][0..repo_dir.len], repo_dir);
    pos += repo_dir.len;
    buf[pos] = '/';
    pos += 1;
    buf[pos] = 0;

    const result = try allocator.alloc(Repo, 1);
    result[0] = .{ .url = buf[0..url_len :0] };
    return result;
}

fn ntDup(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const buf = try allocator.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}
