const std = @import("std");
const dl = @import("../../shared/download.zig");
const shutdown = @import("../../shared/shutdown.zig");
const xbps = @import("../../shared/xbps.zig");
const progress = @import("../../shared/progress.zig");
const install_plan = @import("../../shared/install_plan.zig");

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.flush() catch {};
}

fn confirmProceed(io: std.Io, yes: bool) bool {
    if (yes) return true;
    var ebuf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &ebuf);
    _ = w.interface.write("Proceed? [Y/n] ") catch {};
    w.flush() catch {};
    var input: [8]u8 = undefined;
    var rbuf: [256]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &rbuf);
    var read_bufs: [1][]u8 = .{input[0..]};
    const n = r.interface.readVec(&read_bufs) catch return true;
    return !(n > 0 and (input[0] == 'n' or input[0] == 'N'));
}

fn printSummary(io: std.Io, packages: []const dl.PackageDownload, mode: install_plan.PlanMode) void {
    var name_width: usize = 0;
    var total_size: u64 = 0;
    for (packages) |pkg| {
        const label_len = pkg.name.len + 1 + pkg.version.len;
        if (label_len > name_width) name_width = label_len;
        total_size += pkg.size;
    }
    name_width += 3;

    var size_width: usize = 0;
    for (packages) |pkg| {
        var buf: [32]u8 = undefined;
        const s = progress.humanSize(&buf, pkg.size);
        if (s.len > size_width) size_width = s.len;
    }

    var total_size_buf: [32]u8 = undefined;
    const total_size_str = progress.humanSize(&total_size_buf, total_size);
    if (total_size_str.len > size_width) size_width = total_size_str.len;

    const header = switch (mode) {
        .install => "Packages to install",
        .update => "Packages to update",
    };
    stderrPrint(io, "{s} ({d}): ", .{ header, packages.len });
    for (packages, 0..) |pkg, i| {
        if (i > 0) stderrPrint(io, ", ", .{});
        stderrPrint(io, "{s}", .{pkg.name});
    }
    stderrPrint(io, "\n\n", .{});

    for (packages) |pkg| {
        var pkg_buf: [256]u8 = undefined;
        const pkg_label = std.fmt.bufPrint(&pkg_buf, "{s}-{s}", .{ pkg.name, pkg.version }) catch return;
        var size_buf: [32]u8 = undefined;
        const size_str = progress.humanSize(&size_buf, pkg.size);

        var line_buf: [512]u8 = undefined;
        @memset(&line_buf, ' ');
        @memcpy(line_buf[0..pkg_label.len], pkg_label);
        const offset = name_width + (size_width - size_str.len);
        @memcpy(line_buf[offset..][0..size_str.len], size_str);
        stderrPrint(io, "{s}\n", .{line_buf[0 .. name_width + size_width]});
    }

    {
        var sep_buf: [256]u8 = undefined;
        @memset(sep_buf[0..name_width], ' ');
        @memset(sep_buf[name_width..][0..size_width], '-');
        stderrPrint(io, "{s}\n", .{sep_buf[0 .. name_width + size_width]});
    }

    {
        var total_line_buf: [256]u8 = undefined;
        @memset(&total_line_buf, ' ');
        @memcpy(total_line_buf[0.."Total".len], "Total");
        const offset = name_width + (size_width - total_size_str.len);
        @memcpy(total_line_buf[offset..][0..total_size_str.len], total_size_str);
        stderrPrint(io, "{s}\n\n", .{total_line_buf[0 .. name_width + size_width]});
    }
}

pub fn exec(allocator: std.mem.Allocator, plan: install_plan.InstallPlan, environ_map: *const std.process.Environ.Map) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const count = plan.packages.len;

    if (count == 0) {
        switch (plan.mode) {
            .install => stderrPrint(io, "nothing to install, all packages already installed\n", .{}),
            .update => stderrPrint(io, "everything already up to date\n", .{}),
        }
        return;
    }

    if (plan.dry_run) {
        printSummary(io, plan.packages, plan.mode);
        const verb = switch (plan.mode) {
            .install => "install",
            .update => "update",
        };
        stderrPrint(io, "dry-run: would {s} {d} package{s}\n", .{
            verb, count, if (count == 1) "" else "s",
        });
        return;
    }

    if (std.os.linux.geteuid() != 0) {
        stderrPrint(io, "install requires root (try 'sudo zuri install')\n", .{});
        return error.AccessDenied;
    }

    std.Io.Dir.createDirAbsolute(io, plan.cachedir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            stderrPrint(io, "cannot create cache directory: {s}\n", .{plan.cachedir});
            return err;
        },
    };

    printSummary(io, plan.packages, plan.mode);

    if (!confirmProceed(io, plan.yes)) {
        stderrPrint(io, "aborted.\n", .{});
        return;
    }

    const config = dl.DownloadConfig{
        .max_concurrent = 8,
        .retry_count = 3,
        .initial_retry_delay_ms = 1000,
    };

    const labels = try allocator.alloc([]const u8, count);
    defer {
        for (labels) |l| allocator.free(l);
        allocator.free(labels);
    }
    for (plan.packages, labels) |pkg, *label| {
        label.* = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ pkg.name, pkg.version });
    }

    var mp = try progress.MultiProgress.init(allocator, io, labels);
    defer mp.deinit();
    try mp.start();
    errdefer mp.stop();
    try dl.fetchAll(allocator, plan.packages, config, &mp, environ_map);
    mp.stop();

    if (shutdown.isCancelled()) {
        for (plan.packages) |pkg| {
            std.Io.Dir.deleteFileAbsolute(io, pkg.dest_path) catch {};
        }
        stderrPrint(io, "\nInterrupted — partial downloads cleaned up.\n", .{});
        return error.Interrupted;
    }

    if (mp.anyFailed()) {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\TIP: If you are behind a proxy, set https_proxy (or all_proxy) and re-run:
            \\  export https_proxy=http://proxy.example.com:8080
            \\  sudo -E zuri install {s}
            \\Or check your internet connection and DNS settings.
            \\
        , .{if (plan.packages.len > 0) plan.packages[0].name else ""}) catch "";
        var ebuf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &ebuf);
        _ = w.interface.write(msg) catch {};
        w.flush() catch {};
        return error.DownloadFailed;
    }

    if (shutdown.isCancelled()) {
        stderrPrint(io, "Interrupted before commit — no changes made.\n", .{});
        return error.Interrupted;
    }

    for (plan.packages) |pkg| {
        if (!dl.destPathIsCached(pkg, io)) {
            stderrPrint(io, "{s}: cache corrupted — re-run to re-download\n", .{pkg.name});
            return error.CacheCorrupted;
        }
    }

    try commitViaXbps(io, plan);
}

fn commitViaXbps(io: std.Io, plan: install_plan.InstallPlan) !void {
    const xhp = plan.xhp;

    try xbps.transactionCommit(xhp);

    const verb = switch (plan.mode) {
        .install => "Installing",
        .update => "Updating",
    };
    const done_verb = switch (plan.mode) {
        .install => "installed",
        .update => "updated",
    };

    for (plan.packages) |pkg| {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}-{s}... done", .{ verb, pkg.name, pkg.version }) catch return;
        stderrPrint(io, "{s}\n", .{line});
    }

    stderrPrint(io, "{d} package{s} {s}.\n", .{
        plan.packages.len,
        if (plan.packages.len == 1) "" else "s",
        done_verb,
    });

    try xbps.configurePackages(xhp);
    try xbps.pkgdbUpdate(xhp, true, false);
}
