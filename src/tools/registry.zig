const std = @import("std");
const RLM = @import("omni-rlm").RLM;
const RLMLogger = @import("omni-rlm").RLMLogger;
const config_env = @import("omni-rlm").config_env;

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
/// arguments is an ArrayList of string arguments
pub const ToolExecutor = *const fn (allocator: std.mem.Allocator, arguments: std.ArrayList([]const u8)) anyerror!ToolResult;

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

    // Register rlm tool for grounded reasoning over long materials
    try registry.register(.{
        .name = "rlm",
        .description = "Process ultra-long material with grounded reasoning",
        .executor = runRlm,
    });

    return registry;
}

/// Execute bash command and return output
fn execBash(allocator: std.mem.Allocator, arguments: std.ArrayList([]const u8)) !ToolResult {
    if (arguments.items.len == 0) {
        return ToolResult{
            .output = try allocator.dupe(u8, "Error: No command provided"),
            .success = false,
        };
    }

    // Join all arguments into a single command string
    const cmd_line = try std.mem.join(allocator, " ", arguments.items);
    defer allocator.free(cmd_line);

    std.debug.print("$ {s}\n", .{cmd_line});

    const max_output_bytes: usize = 1024 * 1024;
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-c", cmd_line },
        .max_output_bytes = max_output_bytes,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

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
fn finishTask(allocator: std.mem.Allocator, arguments: std.ArrayList([]const u8)) !ToolResult {
    const output = try std.mem.join(allocator, " ", arguments.items);
    defer allocator.free(output);
    // Print the final response
    std.debug.print("{s}\n", .{output});

    return ToolResult{
        .output = try allocator.dupe(u8, output),
        .success = true,
    };
}

/// Run Omni-RLM completion with root question + material path
fn runRlm(allocator: std.mem.Allocator, arguments: std.ArrayList([]const u8)) !ToolResult {
    if (arguments.items.len < 2) {
        return ToolResult{
            .output = try allocator.dupe(u8, "Error: rlm requires 2 arguments: <root_question> <material_path>"),
            .success = false,
        };
    }

    const root_question = arguments.items[0];
    const material_path = arguments.items[1];

    var backend_cfg = config_env.load_backend_env_config(allocator, ".env") catch |err| {
        return ToolResult{
            .output = try std.fmt.allocPrint(allocator, "Error loading .env for rlm tool: {any}", .{err}),
            .success = false,
        };
    };
    defer backend_cfg.deinit(allocator);

    const logger = RLMLogger.init("./logs", "rlm_tool", allocator) catch |err| {
        return ToolResult{
            .output = try std.fmt.allocPrint(allocator, "Error initializing rlm logger: {any}", .{err}),
            .success = false,
        };
    };

    var rlm: RLM = .{
        .backend = "openai",
        .backend_kwargs = backend_cfg,
        .environment = "local",
        .environment_kwargs = "{}",
        .max_depth = 1,
        .material_chunk_size = 8 * 1024,
        .logger = logger,
        .allocator = allocator,
        .max_iterations = 5,
    };

    rlm.init() catch |err| {
        return ToolResult{
            .output = try std.fmt.allocPrint(allocator, "Error initializing rlm runtime: {any}", .{err}),
            .success = false,
        };
    };
    defer rlm.deinit();

    const completion = rlm.completion(root_question, material_path) catch |err| {
        return ToolResult{
            .output = try std.fmt.allocPrint(allocator, "Error running rlm completion: {any}", .{err}),
            .success = false,
        };
    };
    defer allocator.free(completion.response);

    const output = try std.fmt.allocPrint(allocator, "total time: {d}ms\n{s}", .{
        completion.execution_time,
        completion.response,
    });

    return ToolResult{
        .output = output,
        .success = true,
    };
}
