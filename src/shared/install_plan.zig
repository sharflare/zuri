const std = @import("std");
const dl = @import("download.zig");
const xbps = @import("xbps.zig");

// --- Types ---

pub const Mode = enum {
    install,
    update,
};

pub const Plan = struct {
    packages: []const dl.PackageDownload,
    repo_url: []const u8,
    rootdir: ?[]const u8 = null,
    cachedir: []const u8 = "/var/cache/xbps",
    dry_run: bool = false,
    yes: bool = false,
    xhp: *xbps.Handle,
    mode: Mode = .install,
};

// --- Cleanup ---

pub fn deinit(plan: *Plan, allocator: std.mem.Allocator) void {
    for (plan.packages) |p| {
        allocator.free(p.name);
        allocator.free(p.version);
        allocator.free(p.host);
        allocator.free(p.path);
        allocator.free(p.dest_path);
        if (p.sha256.len > 0) allocator.free(p.sha256);
    }
    allocator.free(plan.packages);
    allocator.free(plan.repo_url);
    xbps.end(plan.xhp);
}
