const std = @import("std");
const Wasm = @import("../sandbox/wasmtime_runtime.zig");

pub const Executor = struct {
    pub fn init() Executor {
        return .{};
    }

    pub fn execute(self: *Executor, tool: []const u8, argument: []const u8) !void {
        _ = self;

        if (std.mem.eql(u8, tool, "echo")) {
            std.debug.print("{s}\n", .{argument});
            return;
        }

        try Wasm.run(tool, argument);
    }
};
