const std = @import("std");

/// Tool execution result
pub const ToolResult = struct {
    output: []const u8,
    success: bool,
};

/// Tool definition structure
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    executor: ToolExecutor,
};

/// Tool executor function type - returns output as string
pub const ToolExecutor = *const fn (allocator: std.mem.Allocator, argument: []const u8) anyerror!ToolResult;

/// Tool registry - stores all available tools
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(Tool),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(Tool).init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
    }

    /// Register a new tool
    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Get a tool by name
    pub fn get(self: *ToolRegistry, name: []const u8) ?Tool {
        return self.tools.get(name);
    }

    /// Check if a tool exists
    pub fn has(self: *ToolRegistry, name: []const u8) bool {
        return self.tools.contains(name);
    }

    /// Get list of all tools formatted as "name - description" strings
    /// Caller owns the returned array and strings, must call deinit() and free items
    pub fn listTool(self: *ToolRegistry) !std.ArrayList([]const u8) {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| {
                self.allocator.free(item);
            }
            result.deinit(self.allocator);
        }

        var it = self.tools.iterator();
        while (it.next()) |entry| {
            const tool = entry.value_ptr;
            const formatted = try std.fmt.allocPrint(self.allocator, "  • {s} - {s}", .{ tool.name, tool.description });
            try result.append(self.allocator, formatted);
        }

        return result;
    }
};

/// Default tool registry with all built-in tools
pub fn createDefaultRegistry(allocator: std.mem.Allocator) !ToolRegistry {
    var registry = ToolRegistry.init(allocator);
    errdefer registry.deinit();

    // Register exec tool for bash execution
    try registry.register(.{
        .name = "exec",
        .description = "Execute bash commands in the current environment",
        .executor = execBash,
    });

    // Register finish tool for providing final answers
    try registry.register(.{
        .name = "finish",
        .description = "Provide final answer and complete the task",
        .executor = finishTask,
    });

    return registry;
}

/// Execute bash command and return output
fn execBash(allocator: std.mem.Allocator, argument: []const u8) !ToolResult {
    if (argument.len == 0) {
        return ToolResult{
            .output = try allocator.dupe(u8, "Error: No command provided"),
            .success = false,
        };
    }

    std.debug.print("$ {s}\n", .{argument});

    const max_output_bytes: usize = 1024 * 1024;
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-c", argument },
        .max_output_bytes = max_output_bytes,
    });

    const stdout = result.stdout;
    const stderr = result.stderr;
    const term = result.term;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    if (stdout.len > 0) {
        try output.appendSlice(allocator, stdout);
    }
    if (stderr.len > 0) {
        if (output.items.len > 0) try output.appendSlice(allocator, "\n");
        try output.appendSlice(allocator, "stderr: ");
        try output.appendSlice(allocator, stderr);
    }

    const success = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };

    if (!success) {
        try std.fmt.format(output.writer(allocator), "\n[Process exited with error]", .{});
    }

    return ToolResult{
        .output = try allocator.dupe(u8, output.items),
        .success = success,
    };
}

/// Finish task with final response
fn finishTask(allocator: std.mem.Allocator, argument: []const u8) !ToolResult {
    // Print the final response
    std.debug.print("{s}\n", .{argument});

    return ToolResult{
        .output = try allocator.dupe(u8, argument),
        .success = true,
    };
}
