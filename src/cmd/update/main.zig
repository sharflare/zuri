const std = @import("std");
const install = @import("../install/main.zig");
const install_plan = @import("../../shared/install_plan.zig");

// --- Types ---

pub const UpdatePlan = install_plan.Plan;

// --- Exec ---

pub fn exec(allocator: std.mem.Allocator, plan: UpdatePlan, environ_map: *const std.process.Environ.Map) !void {
    try install.exec(allocator, plan, environ_map);
}
