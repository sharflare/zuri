const std = @import("std");

// --- CLI ---

const cli = @import("clingy");
const spec = @import("spec.zig");

// --- Shared Utils ---

const repo = @import("shared/repo.zig");
const plan = @import("shared/install_plan.zig");
const shutdown = @import("shared/shutdown.zig");
const xbps = @import("shared/xbps.zig");

// --- Commands ---

const install_exec = @import("cmd/install/main.zig");
const install_rslv = @import("cmd/install/resolve.zig");
const remove_exec = @import("cmd/remove/main.zig");
const update_exec = @import("cmd/update/main.zig");
const update_rslv = @import("cmd/update/resolve.zig");

// --- Aliases ---

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    shutdown.setup();

    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stderr_writer = Io.File.stderr().writer(init.io, &.{});
    const stderr = &stderr_writer.interface;

    var result = cli.parse(spec.root, args[1..], gpa) catch |err| {
        try spec.formatZuriError(stderr, spec.root, err, args[1..]);
        return;
    };
    defer cli.deinit(spec.root, &result, gpa);

    var repo_buf: [256]u8 = undefined;

    switch (result.active) {
        .install => |inst| {
            if (inst.positionals.len == 0) {
                try stderr.print("install: no packages specified\n", .{});
                return;
            }
            if (!result.flags.@"dry-run" and std.os.linux.geteuid() != 0) {
                try stderr.print("error: install requires root (try 'sudo zuri install')\n", .{});
                return;
            }

            const repo_url: [:0]const u8 = try repo.getRepoUrl(init.minimal.environ, stderr, &repo_buf);

            try stderr.print("Resolving dependencies... ", .{});
            var p = install_rslv.rslvInstall(gpa, init.io, repo_url, inst.positionals) catch |err| switch (err) {
                error.NotFound => {
                    try stderr.print("failed\n", .{});
                    return;
                },
                else => |e| return e,
            };
            try stderr.print("done\n", .{});
            defer plan.deinit(&p, gpa);
            p.dry_run = result.flags.@"dry-run";
            p.yes = inst.flags.yes;
            if (result.flags.root) |root| p.rootdir = root;
            try install_exec.exec(gpa, p, init.environ_map);
        },
        .remove => |rm| {
            if (!result.flags.@"dry-run" and std.os.linux.geteuid() != 0) {
                try stderr.print("error: remove requires root (try 'sudo zuri remove')\n", .{});
                return;
            }
            try remove_exec.exec(gpa, init.io, rm.positionals, rm.flags.@"keep-deps", result.flags.@"dry-run", rm.flags.yes, result.flags.root);
        },
        .update => |up| {
            if (!result.flags.@"dry-run" and std.os.linux.geteuid() != 0) {
                try stderr.print("error: update requires root (try 'sudo zuri update')\n", .{});
                return;
            }

            const repo_url: [:0]const u8 = try repo.getRepoUrl(init.minimal.environ, stderr, &repo_buf);

            try stderr.print("Resolving dependencies... ", .{});
            var p = update_rslv.rslvUpdate(gpa, init.io, repo_url) catch |err| switch (err) {
                error.NotFound => {
                    try stderr.print("failed\n", .{});
                    return;
                },
                else => |e| return e,
            };
            try stderr.print("done\n", .{});
            defer plan.deinit(&p, gpa);
            p.dry_run = result.flags.@"dry-run";
            p.yes = up.flags.yes;
            if (result.flags.root) |root| p.rootdir = root;
            try update_exec.exec(gpa, p, init.environ_map);
        },
        .search => |se| {
            for (se.positionals) |q| _ = q;
        },
        .info => |inf| {
            for (inf.positionals) |p| _ = p;
        },
        .build => |b| {
            _ = b.flags.force;
            for (b.positionals) |t| _ = t;
        },
        .clean => |cl| _ = cl.flags.all,
        .root => {
            var buf: [8192]u8 = undefined;
            try stderr.writeAll(cli.renderHelp(spec.root, &buf));
        },
    }
}
