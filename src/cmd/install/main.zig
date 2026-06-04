const std = @import("std");
const install_plan = @import("../../shared/install_plan.zig");
const term = @import("../../shared/term.zig");

const stderrPrint = term.stderrPrint;

pub fn exec(allocator: std.mem.Allocator, plan: install_plan.Plan, environ_map: *const std.process.Environ.Map) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    if (plan.packages.len == 0) {
        stderrPrint(io, "nothing to install, all packages already installed\n", .{});
        return;
    }

    try install_plan.downloadAndCommit(allocator, &plan, environ_map);
}
