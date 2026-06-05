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
const installRslv = @import("cmd/install/resolve.zig");
const remove_exec = @import("cmd/remove/main.zig");
const update_exec = @import("cmd/update/main.zig");
const updateRslv = @import("cmd/update/resolve.zig");
const search_exec = @import("cmd/search/main.zig");
const info_exec = @import("cmd/info/main.zig");
const clean_exec = @import("cmd/clean/main.zig");

// --- Aliases ---

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    shutdown.setup();

    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stderr_writer = Io.File.stderr().writer(init.io, &.{});
    const stderr = &stderr_writer.interface;

    var result = cli.parse(spec.root, args[1..], gpa) catch |err| {
        try spec.formatZuriErr(stderr, spec.root, err, args[1..]);
        return;
    };
    defer cli.deinit(spec.root, &result, gpa);

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

            const repos = try repo.loadRepos(gpa, init.io, init.minimal.environ, stderr);
            defer {
                for (repos) |r| gpa.free(r.url);
                gpa.free(repos);
            }

            try stderr.print("Resolving dependencies... ", .{});
            var p = installRslv.rslvInstall(gpa, init.io, repos, inst.positionals, inst.flags.@"force") catch |err| switch (err) {
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

            const repos = try repo.loadRepos(gpa, init.io, init.minimal.environ, stderr);
            defer {
                for (repos) |r| gpa.free(r.url);
                gpa.free(repos);
            }

            try stderr.print("Resolving dependencies... ", .{});
            var p = updateRslv.rslvUpdate(gpa, init.io, repos) catch |err| switch (err) {
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
            const repos = try repo.loadRepos(gpa, init.io, init.minimal.environ, stderr);
            defer {
                for (repos) |r| gpa.free(r.url);
                gpa.free(repos);
            }
            for (se.positionals) |q| {
                try search_exec.exec(gpa, init.io, repos, q);
            }
        },
        .info => |inf| {
            for (inf.positionals) |p| {
                try info_exec.exec(gpa, init.io, p);
            }
        },
        .build => |b| {
            _ = b.flags.force;
            for (b.positionals) |t| _ = t;
        },
        .clean => |cl| {
            try clean_exec.exec(gpa, init.io, cl.flags.all, cl.flags.@"orphans", result.flags.@"dry-run");
        },
        .root => {
            var buf: [8192]u8 = undefined;
            try stderr.writeAll(cli.renderHelp(spec.root, &buf));
        },
    }
}
