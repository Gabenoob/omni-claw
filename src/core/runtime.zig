const std = @import("std");

const Agent = @import("../agent/mod.zig").Agent;
const Repl = @import("../channel/repl.zig");
const CONVERSATION_LOG_PATH = @import("../agent/planner.zig").CONVERSATION_LOG_PATH;
const writeEmbeddedTools = @import("../tools/embedded.zig").writeEmbeddedTools;

// Configuration paths
const OMNICLAW_DIR = ".omniclaw";
const ENV_FILE_PATH = ".omniclaw/.env";
const OLD_ENV_FILE_PATH = ".env";

/// Configuration data structure
pub const Config = struct {
    base_url: []const u8,
    api_key: ?[]const u8,
    model_name: []const u8,
    enable_thinking: bool = false,

    pub fn print(self: Config, writer: anytype) !void {
        _ = try writer.write("LLM Provider: OpenAI-compatible API\n");
        _ = try writer.write("Base URL: ");
        _ = try writer.write(self.base_url);
        _ = try writer.write("\n");

        _ = try writer.write("API Key: ");
        if (self.api_key) |key| {
            // Mask the API key for security
            if (key.len > 8) {
                _ = try writer.write(key[0..4]);
                _ = try writer.write("...");
                _ = try writer.write(key[key.len - 4 ..]);
            } else {
                _ = try writer.write("(set)");
            }
        } else {
            _ = try writer.write("(not set)");
        }
        _ = try writer.write("\n");

        _ = try writer.write("Model: ");
        _ = try writer.write(self.model_name);
        _ = try writer.write("\n");

        _ = try writer.write("Thinking: ");
        _ = try writer.write(if (self.enable_thinking) "on" else "off");
        _ = try writer.write("\n");
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        // These slices are allocated with allocator.dupe in this module,
        // so we can safely free them here.
        allocator.free(@constCast(self.base_url));
        if (self.api_key) |key| {
            allocator.free(@constCast(key));
        }
        allocator.free(@constCast(self.model_name));
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    agent: Agent,

    pub fn init(allocator: std.mem.Allocator, max_iterations: usize) !Runtime {
        return Runtime{
            .allocator = allocator,
            .agent = try Agent.init(allocator, max_iterations),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.agent.deinit();
    }

    pub fn start(self: *Runtime) !void {
        std.debug.print("OmniClaw-Zig-RLM runtime started\n", .{});

        try self.handleConfiguration();
        try self.materializeEmbeddedTools();

        try std.process.changeCurDir(OMNICLAW_DIR);
        const load_conversation = try self.askLoadConversation();
        try self.prepareConversationLog(load_conversation);
        try Repl.run(&self.agent);
    }

    fn askLoadConversation(self: *Runtime) !bool {
        const stdout_file = std.fs.File.stdout();
        try stdout_file.writeAll("Load existing conversation? [y/N]: ");
        const input = try readLineAlloc(self.allocator, 32);
        defer self.allocator.free(input);

        return std.ascii.eqlIgnoreCase(input, "y") or std.ascii.eqlIgnoreCase(input, "yes");
    }

    fn prepareConversationLog(self: *Runtime, load_last_conversation: bool) !void {
        _ = self;
        if (!load_last_conversation) {
            std.fs.cwd().deleteFile(CONVERSATION_LOG_PATH) catch |err| {
                if (err != error.FileNotFound) return err;
            };
        }
    }

    // =========================================================================
    // Configuration Handling
    // =========================================================================

    fn handleConfiguration(self: *Runtime) !void {
        const stdout_file = std.fs.File.stdout();

        // Check if .omniclaw/.env already exists
        if (self.configExists()) {
            try stdout_file.writeAll("Found existing configuration at .omniclaw/.env\n");
            var config = try self.loadConfig();
            defer config.deinit(self.allocator);
            try self.applyConfig(config);
            return;
        }

        // No existing config in .omniclaw - ask user what to do
        try stdout_file.writeAll("No configuration found in .omniclaw/\n");
        try stdout_file.writeAll("Use existing .env file from current directory? [y/N]: ");
        const use_existing = try readLineAlloc(self.allocator, 256);
        defer self.allocator.free(use_existing);

        const should_use_existing = std.ascii.eqlIgnoreCase(use_existing, "y") or
            std.ascii.eqlIgnoreCase(use_existing, "yes");

        if (should_use_existing) {
            // Try to use existing .env file
            if (self.oldEnvExists()) {
                try self.createOmniclawDir();
                try self.copyFile(OLD_ENV_FILE_PATH, ENV_FILE_PATH);
                try stdout_file.writeAll("Copied existing .env to .omniclaw/.env\n");
                var config = try self.loadConfig();
                defer config.deinit(self.allocator);
                try self.applyConfig(config);
            } else {
                try stdout_file.writeAll("No .env file found in current directory.\n");
                const config = try self.configureInteractive();
                try self.applyConfig(config);
            }
        } else {
            // Create new configuration
            const config = try self.configureInteractive();
            try self.applyConfig(config);
        }
    }

    fn configureInteractive(self: *Runtime) !Config {
        const stdout_file = std.fs.File.stdout();

        try stdout_file.writeAll("\n=== LLM Configuration ===\n");
        try stdout_file.writeAll("Let's set up your LLM connection.\n\n");

        // Step 1: Choose provider type
        try stdout_file.writeAll("Select LLM provider type:\n");
        try stdout_file.writeAll("  1. Local/Ollama (default: http://127.0.0.1:11435)\n");
        try stdout_file.writeAll("  2. OpenAI-compatible API (OpenAI, Moonshot, etc.)\n");
        try stdout_file.writeAll("Choice [1/2]: ");
        const provider_choice = try readLineAlloc(self.allocator, 256);
        defer self.allocator.free(provider_choice);

        const use_hosted = std.mem.eql(u8, provider_choice, "2");

        // Step 2: Base URL
        const default_url = if (use_hosted) "https://api.openai.com/v1" else "http://127.0.0.1:11435";
        try stdout_file.writeAll("\nLLM base URL (without /chat/completions):\n");
        try stdout_file.writeAll("  Default: ");
        try stdout_file.writeAll(default_url);
        try stdout_file.writeAll("\n  Enter URL (or press Enter for default): ");
        const base_url_input = try readLineAlloc(self.allocator, 1024);
        defer self.allocator.free(base_url_input);
        const base_url = if (base_url_input.len == 0) default_url else base_url_input;

        // Step 3: API Key (for hosted APIs)
        var owned_api_key: ?[]u8 = null;
        var api_key_input: ?[]u8 = null;
        defer if (api_key_input) |key| self.allocator.free(key);

        if (use_hosted) {
            try stdout_file.writeAll("\nAPI key (required for hosted APIs): ");
            api_key_input = try readLineAlloc(self.allocator, 1024);
            if (api_key_input.?.len == 0) {
                try stdout_file.writeAll("Warning: No API key provided.\n");
            } else {
                owned_api_key = api_key_input.?;
                api_key_input = null; // 转移所有权，防止 defer 释放
            }
        }

        // Step 4: Model name
        const default_model = if (use_hosted) "gpt-4" else "llama2";
        try stdout_file.writeAll("\nModel name:\n");
        try stdout_file.writeAll("  Default: ");
        try stdout_file.writeAll(default_model);
        try stdout_file.writeAll("\n");
        try stdout_file.writeAll("  Enter model (or press Enter for default): ");
        const model_input = try readLineAlloc(self.allocator, 256);
        defer self.allocator.free(model_input);
        const model_name = if (model_input.len == 0) default_model else model_input;

        // Step 5: Thinking
        try stdout_file.writeAll("\nEnable thinking? [y/N]: ");
        const thinking_input = try readLineAlloc(self.allocator, 32);
        defer self.allocator.free(thinking_input);
        const enable_thinking = std.ascii.eqlIgnoreCase(thinking_input, "y") or std.ascii.eqlIgnoreCase(thinking_input, "yes");

        // Build config (transfer ownership of allocated strings)
        const config = Config{
            .base_url = try self.allocator.dupe(u8, base_url),
            .api_key = if (owned_api_key) |key| key else null,
            .model_name = try self.allocator.dupe(u8, model_name),
            .enable_thinking = enable_thinking,
        };

        // Create .omniclaw directory and save configuration
        try self.createOmniclawDir();
        try self.saveEnvFile(config);

        try stdout_file.writeAll("\n✓ Configuration saved to .omniclaw/.env\n");
        try stdout_file.writeAll("\nYou can edit this file manually or run again to reconfigure.\n\n");

        return config;
    }

    fn applyConfig(self: *Runtime, config: Config) !void {
        const stdout_file = std.fs.File.stdout();
        try self.agent.configureLlmConnection(config);
        try stdout_file.writeAll("Configuration loaded successfully.\n\n");
    }

    fn loadConfig(self: *Runtime) !Config {
        // Read and parse the .omniclaw/.env file
        const content = try std.fs.cwd().readFileAlloc(self.allocator, ENV_FILE_PATH, 4096);
        defer self.allocator.free(content);

        var base_url: ?[]u8 = null;
        var api_key: ?[]u8 = null;
        var model_name: ?[]u8 = null;
        var enable_thinking: bool = false;

        errdefer {
            if (base_url) |v| self.allocator.free(v);
            if (api_key) |v| self.allocator.free(v);
            if (model_name) |v| self.allocator.free(v);
        }

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "#")) continue;

            if (std.mem.startsWith(u8, trimmed, "OMNIRLM_BASE_URL=")) {
                const value = trimmed["OMNIRLM_BASE_URL=".len..];
                base_url = try self.allocator.dupe(u8, std.mem.trim(u8, value, " \""));
            } else if (std.mem.startsWith(u8, trimmed, "OMNIRLM_API_KEY=")) {
                const value = trimmed["OMNIRLM_API_KEY=".len..];
                const trimmed_value = std.mem.trim(u8, value, " \"");
                if (trimmed_value.len > 0) {
                    api_key = try self.allocator.dupe(u8, trimmed_value);
                }
            } else if (std.mem.startsWith(u8, trimmed, "OMNIRLM_MODEL_NAME=")) {
                const value = trimmed["OMNIRLM_MODEL_NAME=".len..];
                model_name = try self.allocator.dupe(u8, std.mem.trim(u8, value, " \""));
            } else if (std.mem.startsWith(u8, trimmed, "OMNIRLM_ENABLE_THINKING=")) {
                const value = std.mem.trim(u8, trimmed["OMNIRLM_ENABLE_THINKING=".len..], " \"");
                enable_thinking = std.ascii.eqlIgnoreCase(value, "true");
            }
        }

        return Config{
            .base_url = base_url orelse try self.allocator.dupe(u8, "http://127.0.0.1:11435"),
            .api_key = api_key,
            .model_name = model_name orelse try self.allocator.dupe(u8, "kimi-k2.5"),
            .enable_thinking = enable_thinking,
        };
    }

    fn saveEnvFile(self: *Runtime, config: Config) !void {
        _ = self;
        try saveConfig(ENV_FILE_PATH, config);
    }

    // =========================================================================
    // File System Utilities
    // =========================================================================

    fn configExists(self: Runtime) bool {
        _ = self;
        return fileExists(ENV_FILE_PATH);
    }

    fn oldEnvExists(self: Runtime) bool {
        _ = self;
        return fileExists(OLD_ENV_FILE_PATH);
    }

    fn createOmniclawDir(self: Runtime) !void {
        _ = self;
        std.fs.cwd().makeDir(OMNICLAW_DIR) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    fn copyFile(self: Runtime, source: []const u8, dest: []const u8) !void {
        const content = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(content);

        const src_file = try std.fs.cwd().openFile(source, .{});
        defer src_file.close();

        const dst_file = try std.fs.cwd().createFile(dest, .{});
        defer dst_file.close();

        while (true) {
            const bytes_read = try src_file.read(content);
            if (bytes_read == 0) break;
            try dst_file.writeAll(content[0..bytes_read]);
        }
    }

    fn materializeEmbeddedTools(self: Runtime) !void {
        try std.fs.cwd().makePath(".omniclaw/tools/docs");
        var omniclaw_dir = try std.fs.cwd().openDir(OMNICLAW_DIR, .{});
        defer omniclaw_dir.close();

        try writeEmbeddedTools(self.allocator, omniclaw_dir);
    }

    fn fileExists(path: []const u8) bool {
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        file.close();
        return true;
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

/// Write a Config to the given path, overwriting any existing file.
/// The path is resolved relative to the current working directory, so callers
/// must pass a path appropriate for their CWD (startup uses `.omniclaw/.env`
/// from the project root; the REPL uses `.env` since CWD is already `.omniclaw/`).
pub fn saveConfig(path: []const u8, config: Config) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll("# Omni-RLM backend configuration\n");
    try file.writeAll("# Auto-generated by Omni-Claw runtime\n\n");

    try file.writeAll("OMNIRLM_BASE_URL=");
    try file.writeAll(config.base_url);
    try file.writeAll("\n\n");

    if (config.api_key) |key| {
        try file.writeAll("OMNIRLM_API_KEY=");
        try file.writeAll(key);
        try file.writeAll("\n\n");
    } else {
        try file.writeAll("# OMNIRLM_API_KEY=your-api-key-here\n\n");
    }

    try file.writeAll("# Model name served by your backend\n");
    try file.writeAll("OMNIRLM_MODEL_NAME=");
    try file.writeAll(config.model_name);
    try file.writeAll("\n\n");

    try file.writeAll("OMNIRLM_ENABLE_THINKING=");
    try file.writeAll(if (config.enable_thinking) "true" else "false");
    try file.writeAll("\n");
}

/// Launch the interactive menu-picker editor for an existing Config. Returns a
/// new Config whose string fields are freshly allocated with `allocator`; the
/// caller must `deinit` it (or pass it to configureLlmConnection, which clones).
/// Stdin must be in canonical (non-raw) mode for readLineAlloc to behave; the
/// REPL handler toggles this.
pub fn editConfigInteractive(allocator: std.mem.Allocator, current: Config) !Config {
    var base_url: []const u8 = try allocator.dupe(u8, current.base_url);
    errdefer allocator.free(base_url);

    var api_key: ?[]const u8 = if (current.api_key) |k| try allocator.dupe(u8, k) else null;
    errdefer if (api_key) |k| allocator.free(k);

    var model_name: []const u8 = try allocator.dupe(u8, current.model_name);
    errdefer allocator.free(model_name);

    var enable_thinking = current.enable_thinking;

    const stdout = std.fs.File.stdout();

    while (true) {
        try stdout.writeAll("\n=== Edit Configuration ===\n");
        try stdout.writeAll("  1) Base URL         : ");
        try stdout.writeAll(base_url);
        try stdout.writeAll("\n  2) API key          : ");
        if (api_key) |k| {
            if (k.len > 8) {
                try stdout.writeAll(k[0..4]);
                try stdout.writeAll("...");
                try stdout.writeAll(k[k.len - 4 ..]);
            } else {
                try stdout.writeAll("(set)");
            }
        } else {
            try stdout.writeAll("(not set)");
        }
        try stdout.writeAll("\n  3) Model name       : ");
        try stdout.writeAll(model_name);
        try stdout.writeAll("\n  4) Thinking         : ");
        try stdout.writeAll(if (enable_thinking) "on" else "off");
        try stdout.writeAll("\n  0) Save & exit\n");
        try stdout.writeAll("Choice [0-4]: ");

        const choice = try Runtime.readLineAlloc(allocator, 16);
        defer allocator.free(choice);

        if (choice.len == 0 or std.mem.eql(u8, choice, "0")) break;

        if (std.mem.eql(u8, choice, "1")) {
            try stdout.writeAll("New base URL: ");
            const input = try Runtime.readLineAlloc(allocator, 1024);
            if (input.len == 0) {
                allocator.free(input);
                continue;
            }
            allocator.free(base_url);
            base_url = input;
        } else if (std.mem.eql(u8, choice, "2")) {
            try stdout.writeAll("New API key (empty to clear): ");
            const input = try Runtime.readLineAlloc(allocator, 1024);
            if (api_key) |k| allocator.free(k);
            if (input.len == 0) {
                allocator.free(input);
                api_key = null;
            } else {
                api_key = input;
            }
        } else if (std.mem.eql(u8, choice, "3")) {
            try stdout.writeAll("New model name: ");
            const input = try Runtime.readLineAlloc(allocator, 256);
            if (input.len == 0) {
                allocator.free(input);
                continue;
            }
            allocator.free(model_name);
            model_name = input;
        } else if (std.mem.eql(u8, choice, "4")) {
            enable_thinking = !enable_thinking;
        } else {
            try stdout.writeAll("Invalid choice.\n");
        }
    }

    return Config{
        .base_url = base_url,
        .api_key = api_key,
        .model_name = model_name,
        .enable_thinking = enable_thinking,
    };
}

test "show_config" {
    const config = Config{
        .base_url = "http://example.com",
        .api_key = "my-secret-api-key",
        .model_name = "my_model",
    };
    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try config.print(fbs.writer());
    const output = fbs.getWritten();
    try std.testing.expectEqualStrings(
        \\LLM Provider: OpenAI-compatible API
        \\Base URL: http://example.com
        \\API Key: my-s...-key
        \\Model: my_model
        \\Thinking: off
        \\
    ,
        output,
    );
}
