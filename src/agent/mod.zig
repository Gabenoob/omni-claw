const std = @import("std");

const Planner = @import("planner.zig").Planner;
const ToolRegistry = @import("../tools/registry.zig").ToolRegistry;
const createDefaultRegistry = @import("../tools/registry.zig").createDefaultRegistry;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    planner: Planner,
    registry: ToolRegistry,
    config: ?Config,

    pub const Config = struct {
        base_url: []const u8,
        api_key: ?[]const u8,
        model_name: []const u8,

        pub fn print(self: Config, writer: anytype) !void {
            try writer.writeAll("LLM Provider: OpenAI-compatible API\n");
            try writer.writeAll("Base URL: ");
            try writer.writeAll(self.base_url);
            try writer.writeAll("\n");

            try writer.writeAll("API Key: ");
            if (self.api_key) |key| {
                // Mask the API key for security
                if (key.len > 8) {
                    try writer.writeAll(key[0..4]);
                    try writer.writeAll("...");
                    try writer.writeAll(key[key.len - 4 ..]);
                } else {
                    try writer.writeAll("(set)");
                }
            } else {
                try writer.writeAll("(not set)");
            }
            try writer.writeAll("\n");

            try writer.writeAll("Model: ");
            try writer.writeAll(self.model_name);
            try writer.writeAll("\n");
        }
    };

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

    pub fn configureLlmConnection(self: *Agent, base_url: []const u8, api_key: ?[]const u8, model_name: ?[]const u8) !void {
        // Store config for later display
        if (self.config) |*cfg| {
            self.allocator.free(cfg.base_url);
            if (cfg.api_key) |key| self.allocator.free(key);
            self.allocator.free(cfg.model_name);
        }

        self.config = Config{
            .base_url = try self.allocator.dupe(u8, base_url),
            .api_key = if (api_key) |key| try self.allocator.dupe(u8, key) else null,
            .model_name = try self.allocator.dupe(u8, model_name orelse "kimi-k2.5"),
        };

        try self.planner.setConnectionConfig(base_url, api_key, model_name);
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
        const plan = try self.planner.plan(prompt);
        defer self.allocator.free(plan.tool);

        // Execute the tool directly using registry
        const tool_def = self.registry.get(plan.tool) orelse {
            std.debug.print("Error: Unknown tool '{s}'\n", .{plan.tool});
            std.debug.print("Available tools: ", .{});

            var it = self.registry.tools.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) std.debug.print(", ", .{});
                first = false;
                std.debug.print("{s}", .{entry.value_ptr.name});
            }
            std.debug.print("\n", .{});
            return error.UnknownTool;
        };

        try tool_def.executor(self.allocator, plan.argument);
    }
};
