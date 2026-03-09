const std = @import("std");

const Agent = @import("agent/agent.zig").Agent;
const Repl = @import("transport/repl.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    agent: Agent,

    pub fn init(allocator: std.mem.Allocator) !Runtime {
        return Runtime{
            .allocator = allocator,
            .agent = try Agent.init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.agent.deinit();
    }

    pub fn start(self: *Runtime) !void {
        std.debug.print("OmniClaw-Zig-RLM runtime started\n", .{});

        try self.promptLlmConfiguration();
        try Repl.run(&self.agent);
    }

    fn promptLlmConfiguration(self: *Runtime) !void {
        const stdout_file = std.fs.File.stdout();

        try stdout_file.writeAll("Configure LLM connection now? [y/N]: ");
        const should_configure = try readLineAlloc(self.allocator, 256);
        defer self.allocator.free(should_configure);
        if (!std.ascii.eqlIgnoreCase(should_configure, "y") and !std.ascii.eqlIgnoreCase(should_configure, "yes")) return;

        try stdout_file.writeAll("Use hosted LLM API? [y/N] (No = local endpoint): ");
        const hosted_answer = try readLineAlloc(self.allocator, 256);
        defer self.allocator.free(hosted_answer);
        const use_hosted = std.ascii.eqlIgnoreCase(hosted_answer, "y") or std.ascii.eqlIgnoreCase(hosted_answer, "yes");

        const default_url = if (use_hosted) "https://api.openai.com/v1" else "http://127.0.0.1:11435";
        try stdout_file.writeAll("LLM planner base URL (without /plan): ");
        const base_url_input = try readLineAlloc(self.allocator, 1024);
        defer self.allocator.free(base_url_input);
        const base_url = if (base_url_input.len == 0) default_url else base_url_input;

        var owned_api_key: ?[]u8 = null;
        defer if (owned_api_key) |key| self.allocator.free(key);

        if (use_hosted) {
            try stdout_file.writeAll("Hosted API key (leave empty to skip): ");
            const api_key_input = try readLineAlloc(self.allocator, 1024);
            if (api_key_input.len == 0) {
                self.allocator.free(api_key_input);
            } else {
                owned_api_key = api_key_input;
            }
        }

        try self.agent.configureLlmConnection(base_url, if (owned_api_key) |key| key else null);
        try stdout_file.writeAll("LLM connection configured.\n");
    }

    fn readLineAlloc(allocator: std.mem.Allocator, max_len: usize) ![]u8 {
        const stdin_file = std.fs.File.stdin();

        const raw_line = try allocator.alloc(u8, max_len);
        defer allocator.free(raw_line);

        var len: usize = 0;
        while (len < max_len) {
            var byte: [1]u8 = undefined;
            const n = try stdin_file.read(&byte);
            if (n == 0) break;
            if (byte[0] == '\n') break;
            raw_line[len] = byte[0];
            len += 1;
        }

        return allocator.dupe(u8, std.mem.trim(u8, raw_line[0..len], " \t\r\n"));
    }
};
