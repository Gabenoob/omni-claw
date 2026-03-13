const std = @import("std");

const Planner = @import("planner.zig").Planner;
const PlanResult = @import("planner.zig").PlanResult;
const ToolRegistry = @import("../tools/registry.zig").ToolRegistry;
const ToolResult = @import("../tools/registry.zig").ToolResult;
const createDefaultRegistry = @import("../tools/registry.zig").createDefaultRegistry;

const Config = @import("../omniclaw.zig").Config;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    planner: Planner,
    registry: ToolRegistry,
    config: ?Config,

    pub fn init(allocator: std.mem.Allocator) !Agent {
        return Agent{
            .allocator = allocator,
            .planner = Planner.init(allocator),
            .registry = try createDefaultRegistry(allocator),
            .config = null,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.planner.deinit();
        self.registry.deinit();
        if (self.config) |*cfg| {
            self.allocator.free(cfg.base_url);
            if (cfg.api_key) |key| self.allocator.free(key);
            self.allocator.free(cfg.model_name);
        }
    }

    pub fn configureLlmConnection(self: *Agent, config: Config) !void {
        // Store config for later display
        if (self.config) |*cfg| {
            self.allocator.free(cfg.base_url);
            if (cfg.api_key) |key| self.allocator.free(key);
            self.allocator.free(cfg.model_name);
        }

        self.config = Config{
            .base_url = try self.allocator.dupe(u8, config.base_url),
            .api_key = if (config.api_key) |key| try self.allocator.dupe(u8, key) else null,
            .model_name = try self.allocator.dupe(u8, config.model_name),
        };

        try self.planner.setConnectionConfig(self.config.?);
    }

    pub fn printConfig(self: *Agent) !void {
        const stdout_file = std.fs.File.stdout();

        try stdout_file.writeAll("\n=== Current Configuration ===\n");

        if (self.config) |cfg| {
            try cfg.print(stdout_file);
        } else {
            try stdout_file.writeAll("No configuration loaded.\n");
        }

        try stdout_file.writeAll("=============================\n\n");
    }

    pub fn printTools(self: *Agent) !void {
        const stdout_file = std.fs.File.stdout();

        try stdout_file.writeAll("\n=== Available Tools ===\n\n");

        var tool_list = try self.registry.listTool();
        defer {
            for (tool_list.items) |item| {
                self.allocator.free(item);
            }
            tool_list.deinit(self.allocator);
        }

        if (tool_list.items.len == 0) {
            try stdout_file.writeAll("No tools available.\n");
        } else {
            for (tool_list.items) |line| {
                try stdout_file.writeAll(line);
                try stdout_file.writeAll("\n");
            }
        }

        try stdout_file.writeAll("\n=======================\n\n");
    }

    pub fn runPrompt(self: *Agent, prompt: []const u8) !void {
        // Initialize conversation
        try self.planner.initializeConversation(prompt);

        // Execute recursively until finish
        var result = try self.executeRecursive();
        defer result.deinit(self.allocator);

        // Print final result summary
        std.debug.print("\n=== Task Completed ===\n", .{});
        std.debug.print("Final answer: {s}\n", .{result.final_output});
        std.debug.print("Total tool calls: {d}\n", .{result.tool_calls.items.len});
        for (result.tool_calls.items, 0..) |call, i| {
            std.debug.print("  {d}. {s} -> {s} ({s})\n", .{
                i + 1,
                call.tool,
                if (call.success) "success" else "failed",
                call.argument,
            });
        }
    }

    /// Execute tool using the registry
    fn executeToolWithRegistry(self: *Agent, tool_name: []const u8, argument: []const u8) !ToolResult {
        const tool_def = self.registry.get(tool_name) orelse {
            return ToolResult{
                .output = try std.fmt.allocPrint(self.allocator, "Error: Unknown tool '{s}'", .{tool_name}),
                .success = false,
            };
        };

        return try tool_def.executor(self.allocator, argument);
    }

    /// Execute plans recursively until finish tool is called
    fn executeRecursive(self: *Agent) !PlanResult {
        var tool_calls: std.ArrayList(@import("planner.zig").ToolCallRecord) = .empty;
        errdefer {
            for (tool_calls.items) |*call| {
                call.deinit(self.allocator);
            }
            tool_calls.deinit(self.allocator);
        }

        var iteration: usize = 0;
        const max_iterations = self.planner.max_iterations;

        while (iteration < max_iterations) : (iteration += 1) {
            // Get next plan from LLM
            const plan = try self.planner.getNextPlan();
            defer self.allocator.free(plan.tool);
            defer self.allocator.free(plan.argument);

            // Check if this is the finish tool
            if (std.mem.eql(u8, plan.tool, "finish")) {
                return PlanResult{
                    .final_output = try self.allocator.dupe(u8, plan.argument),
                    .tool_calls = tool_calls,
                };
            }

            // Execute the tool
            const tool_result = try self.executeToolWithRegistry(plan.tool, plan.argument);
            defer self.allocator.free(tool_result.output);

            // Record the tool call
            try tool_calls.append(self.allocator, .{
                .tool = try self.allocator.dupe(u8, plan.tool),
                .argument = try self.allocator.dupe(u8, plan.argument),
                .result = try self.allocator.dupe(u8, tool_result.output),
                .success = tool_result.success,
            });

            // Add result to message history for next iteration
            try self.planner.addToolResult(plan.tool, tool_result.output, tool_result.success);
        }

        // Max iterations reached
        return error.MaxIterationsReached;
    }
};
