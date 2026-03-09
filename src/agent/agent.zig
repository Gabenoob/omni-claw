const std = @import("std");

const Planner = @import("planner_rlm.zig").Planner;
const Executor = @import("executor.zig").Executor;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    planner: Planner,
    executor: Executor,

    pub fn init(allocator: std.mem.Allocator) !Agent {
        return Agent{
            .allocator = allocator,
            .planner = Planner.init(allocator),
            .executor = Executor.init(),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.planner.deinit();
    }

    pub fn runPrompt(self: *Agent, prompt: []const u8) !void {
        const plan = try self.planner.plan(prompt);
        defer self.allocator.free(plan.tool);

        try self.executor.execute(plan.tool, plan.argument);
    }
};
