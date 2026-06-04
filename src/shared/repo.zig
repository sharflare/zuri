const std = @import("std");
const builtin = @import("builtin");

// --- Repo URL ---

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

// --- Repo Dir ---

const default_repo_prefix = "https://repo-default.voidlinux.org/current/";

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

pub fn getRepoUrl(env: std.process.Environ, stderr: anytype, buf: *[256]u8) ![:0]const u8 {
    if (env.getPosix("ZURI_REPO_URL")) |env_val| return env_val;

    const repo_dir = getRepoDir() orelse {
        try stderr.print("error: unsupported architecture ({s}, {s})\n", .{
            @tagName(builtin.cpu.arch), @tagName(builtin.abi),
        });
        return error.UnsupportedArchitecture;
    };

    const repo_slice = if (repo_dir.len == 0)
        try std.fmt.bufPrint(buf, "{s}", .{default_repo_prefix})
    else
        try std.fmt.bufPrint(buf, "{s}{s}/", .{ default_repo_prefix, repo_dir });
    buf.*[repo_slice.len] = 0;
    return buf[0..repo_slice.len :0];
}
