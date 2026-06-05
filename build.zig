const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const static = b.option(bool, "static", "Use static linking for system libraries (default: dynamic)") orelse false;
    const link_mode: std.builtin.LinkMode = if (static) .static else .dynamic;

    const exe = b.addExecutable(.{
        .name = "zuri",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const clingy_dep = b.dependency("clingy", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("clingy", clingy_dep.module("clingy"));

    exe.root_module.link_libc = true;

    exe.root_module.linkSystemLibrary("xbps", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("ssl", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("crypto", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("archive", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("z", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("zstd", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("bz2", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("lzma", .{ .preferred_link_mode = link_mode });

    if (native_has_libacl(b)) {
        exe.root_module.linkSystemLibrary("acl", .{ .preferred_link_mode = link_mode });
        exe.root_module.linkSystemLibrary("attr", .{ .preferred_link_mode = link_mode });
    }

    exe.root_module.linkSystemLibrary("lz4", .{ .preferred_link_mode = link_mode });
    exe.root_module.linkSystemLibrary("atomic", .{ .preferred_link_mode = link_mode });
    if (target.result.cpu.arch == .aarch64) linkLibGcc(b, exe, target);

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    exe.root_module.addImport("bzon", options.createModule());

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn native_has_libacl(b: *std.Build) bool {
    const io = b.graph.io;
    std.Io.Dir.accessAbsolute(io, "/usr/lib/libacl.a", .{}) catch return false;
    return true;
}

fn linkLibGcc(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const io = b.graph.io;
    const triple = std.Target.linuxTriple(&target.result, b.allocator) catch return;
    defer b.allocator.free(triple);

    const gcc_dir_path = std.fs.path.join(b.allocator, &.{ "/usr/lib/gcc", triple }) catch return;
    defer b.allocator.free(gcc_dir_path);

    var gcc_dir = std.Io.Dir.openDirAbsolute(io, gcc_dir_path, .{ .iterate = true }) catch return;

    var iter = gcc_dir.iterate();
    while (iter.next(io) catch return) |entry| {
        if (entry.kind != .directory) continue;
        const lib_path = std.fs.path.join(b.allocator, &.{ gcc_dir_path, entry.name, "libgcc.a" }) catch continue;
        defer b.allocator.free(lib_path);
        if (std.Io.Dir.accessAbsolute(io, lib_path, .{})) {
            exe.root_module.addObjectFile(.{ .cwd_relative = lib_path });
            gcc_dir.close(io);
            return;
        } else |_| {}
    }
    gcc_dir.close(io);
}
