const std = @import("std");

pub const Plan = struct {
    tool: []const u8,
    argument: []const u8,
};

pub const Planner = struct {
    allocator: std.mem.Allocator,
    configured_base_url: ?[]u8,
    configured_api_key: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) Planner {
        return .{ .allocator = allocator, .configured_base_url = null, .configured_api_key = null };
    }

    pub fn deinit(self: *Planner) void {
        if (self.configured_base_url) |base_url| self.allocator.free(base_url);
        if (self.configured_api_key) |api_key| self.allocator.free(api_key);
    }

    pub fn setConnectionConfig(self: *Planner, base_url: []const u8, api_key: ?[]const u8) !void {
        if (self.configured_base_url) |existing| self.allocator.free(existing);
        self.configured_base_url = try self.allocator.dupe(u8, base_url);

        if (self.configured_api_key) |existing| self.allocator.free(existing);
        if (api_key) |key| {
            self.configured_api_key = try self.allocator.dupe(u8, key);
        } else {
            self.configured_api_key = null;
        }
    }

    pub fn plan(self: *Planner, prompt: []const u8) !Plan {
        if (prompt.len == 0) return Plan{ .tool = try self.allocator.dupe(u8, "echo"), .argument = "" };

        if (self.queryOmniRlm(prompt)) |tool| {
            return Plan{ .tool = tool, .argument = prompt };
        } else |_| {}

        const lowered = try std.ascii.allocLowerString(self.allocator, prompt);
        defer self.allocator.free(lowered);

        if (std.mem.indexOf(u8, lowered, "search") != null or std.mem.indexOf(u8, lowered, "find") != null) {
            if (toolExists("web_search"))
                return Plan{ .tool = try self.allocator.dupe(u8, "web_search"), .argument = prompt };

            return Plan{ .tool = try self.allocator.dupe(u8, "echo"), .argument = prompt };
        }

        return Plan{ .tool = try self.allocator.dupe(u8, "echo"), .argument = prompt };
    }

    fn toolExists(tool: []const u8) bool {
        const manifest_path = std.fmt.allocPrint(std.heap.page_allocator, "plugins/{s}/manifest.json", .{tool}) catch {
            return false;
        };
        defer std.heap.page_allocator.free(manifest_path);

        std.fs.cwd().access(manifest_path, .{}) catch {
            return false;
        };

        return true;
    }

    fn queryOmniRlm(self: *Planner, prompt: []const u8) ![]const u8 {
        const base_url = if (self.configured_base_url) |configured| configured else blk: {
            const env_base_url = std.process.getEnvVarOwned(self.allocator, "OMNI_RLM_URL") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => try self.allocator.dupe(u8, "http://127.0.0.1:11435"),
                else => return err,
            };
            defer self.allocator.free(env_base_url);
            break :blk try self.allocator.dupe(u8, env_base_url);
        };
        defer if (self.configured_base_url == null) self.allocator.free(base_url);

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/plan", .{base_url});
        defer self.allocator.free(endpoint);

        const payload = try std.fmt.allocPrint(self.allocator, "{{\"prompt\":{f}}}", .{std.json.fmt(prompt, .{})});
        defer self.allocator.free(payload);

        var args = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        defer args.deinit(self.allocator);

        try args.appendSlice(self.allocator, &.{
            "curl",
            "--silent",
            "--show-error",
            "--fail",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
        });

        const api_key = if (self.configured_api_key) |key| key else std.process.getEnvVarOwned(self.allocator, "OMNI_RLM_API_KEY") catch null;
        defer if (self.configured_api_key == null and api_key != null) self.allocator.free(api_key.?);

        var auth_header: ?[]u8 = null;
        defer if (auth_header) |header| self.allocator.free(header);

        if (api_key) |key| {
            auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{key});
            try args.appendSlice(self.allocator, &.{ "-H", auth_header.? });
        }

        try args.appendSlice(self.allocator, &.{
            "--data",
            payload,
            endpoint,
        });

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const response = try child.stdout.?.readToEndAlloc(self.allocator, 32 * 1024);
        defer self.allocator.free(response);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return error.InvalidOmniRlmResponse,
            else => return error.InvalidOmniRlmResponse,
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidOmniRlmResponse;

        const obj = parsed.value.object;
        const tool_value = obj.get("tool") orelse return error.InvalidOmniRlmResponse;
        if (tool_value != .string) return error.InvalidOmniRlmResponse;

        return self.allocator.dupe(u8, tool_value.string);
    }
};
