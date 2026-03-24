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

    pub fn init(allocator: std.mem.Allocator, max_iterations: usize) !Agent {
        return Agent{
            .allocator = allocator,
            .planner = Planner.init(allocator, max_iterations),
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

        const base_url = try self.allocator.dupe(u8, config.base_url);
        errdefer self.allocator.free(base_url);
        
        const api_key = if (config.api_key) |key| try self.allocator.dupe(u8, key) else null;
        errdefer if (api_key) |key| self.allocator.free(key);
        
        const model_name = try self.allocator.dupe(u8, config.model_name);
        errdefer self.allocator.free(model_name);

        self.config = Config{
            .base_url = base_url,
            .api_key = api_key,
            .model_name = model_name,
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
            // Join arguments for display
            const arg_str = try std.mem.join(self.allocator, " ", call.arguments.items);
            defer self.allocator.free(arg_str);
            std.debug.print("  {d}. {s} -> {s} ({s})\n", .{
                i + 1,
                call.tool,
                if (call.success) "success" else "failed",
                arg_str,
            });
        }
    }

    /// Execute tool using the registry
    fn executeToolWithRegistry(self: *Agent, tool_name: []const u8, arguments: std.ArrayList([]const u8)) !ToolResult {
        const tool_def = self.registry.get(tool_name) orelse {
            return ToolResult{
                .output = try std.fmt.allocPrint(self.allocator, "Error: Unknown tool '{s}'", .{tool_name}),
                .success = false,
            };
        };

        return try tool_def.executor(self.allocator, arguments);
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
            var plan = try self.planner.getNextPlan();
            defer plan.deinit(self.allocator);

            // Check if this is the finish tool
            if (std.mem.eql(u8, plan.tool, "finish")) {
                // Join arguments for final output
                const final_output = try std.mem.join(self.allocator, " ", plan.arguments.items);
                defer self.allocator.free(final_output);
                return PlanResult{
                    .final_output = try self.allocator.dupe(u8, final_output),
                    .tool_calls = tool_calls,
                };
            }

            // Execute the tool
            const tool_result = try self.executeToolWithRegistry(plan.tool, plan.arguments);
            defer self.allocator.free(tool_result.output);

            // Record the tool call
            const tool_copy = try self.allocator.dupe(u8, plan.tool);
            errdefer self.allocator.free(tool_copy);
            
            var arguments_copy = try @import("planner.zig").Planner.cloneStringList(self.allocator, plan.arguments);
            errdefer {
                for (arguments_copy.items) |item| {
                    self.allocator.free(item);
                }
                arguments_copy.deinit(self.allocator);
            }
            
            const result_copy = try self.allocator.dupe(u8, tool_result.output);
            errdefer self.allocator.free(result_copy);
            
            try tool_calls.append(self.allocator, .{
                .tool = tool_copy,
                .arguments = arguments_copy,
                .result = result_copy,
                .success = tool_result.success,
            });

            // Add result to message history for next iteration
            try self.planner.addToolResult(plan.tool, tool_result.output, tool_result.success);
        }

        // Max iterations reached - errdefer handles cleanup
        return error.MaxIterationsReached;
    }
};
