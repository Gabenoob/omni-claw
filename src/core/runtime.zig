const std = @import("std");

const Agent = @import("../agent/mod.zig").Agent;
const Repl = @import("../channel/repl.zig");

// Configuration paths
const OMNICLAW_DIR = ".omniclaw";
const ENV_FILE_PATH = ".omniclaw/.env";
const OLD_ENV_FILE_PATH = ".env";

/// Configuration data structure
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
        try self.copyToolsDir();

        try std.process.changeCurDir(OMNICLAW_DIR);
        try Repl.run(&self.agent);
    }

    // =========================================================================
    // Configuration Handling
    // =========================================================================

    fn handleConfiguration(self: *Runtime) !void {
        const stdout_file = std.fs.File.stdout();

        // Check if .omniclaw/.env already exists
        if (self.configExists()) {
            try stdout_file.writeAll("Found existing configuration at .omniclaw/.env\n");
            const config = try self.loadConfig();
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
                const config = try self.loadConfig();
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

        if (use_hosted) {
            try stdout_file.writeAll("\nAPI key (required for hosted APIs): ");
            const api_key_input = try readLineAlloc(self.allocator, 1024);
            defer self.allocator.free(api_key_input);
            if (api_key_input.len == 0) {
                self.allocator.free(api_key_input);
                try stdout_file.writeAll("Warning: No API key provided.\n");
            } else {
                owned_api_key = api_key_input;
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

        // Create .omniclaw directory and save configuration
        try self.createOmniclawDir();
        try self.saveEnvFile(base_url, owned_api_key, model_name);

        try stdout_file.writeAll("\n✓ Configuration saved to .omniclaw/.env\n");
        try stdout_file.writeAll("\nYou can edit this file manually or run again to reconfigure.\n\n");

        // Build config (transfer ownership of allocated strings)
        return Config{
            .base_url = try self.allocator.dupe(u8, base_url),
            .api_key = if (owned_api_key) |key| key else null,
            .model_name = try self.allocator.dupe(u8, model_name),
        };
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
            }
        }

        return Config{
            .base_url = base_url orelse try self.allocator.dupe(u8, "http://127.0.0.1:11435"),
            .api_key = api_key,
            .model_name = model_name orelse try self.allocator.dupe(u8, "kimi-k2.5"),
        };
    }

    fn saveEnvFile(self: *Runtime, base_url: []const u8, api_key: ?[]const u8, model_name: []const u8) !void {
        _ = self;

        const file = try std.fs.cwd().createFile(ENV_FILE_PATH, .{});
        defer file.close();

        // Write header
        try file.writeAll("# Omni-RLM backend configuration\n");
        try file.writeAll("# Auto-generated by Omni-Claw runtime\n\n");

        // Write base URL
        try file.writeAll("OMNIRLM_BASE_URL=");
        try file.writeAll(base_url);
        try file.writeAll("\n\n");

        // Write API key
        if (api_key) |key| {
            try file.writeAll("OMNIRLM_API_KEY=");
            try file.writeAll(key);
            try file.writeAll("\n\n");
        } else {
            try file.writeAll("# OMNIRLM_API_KEY=your-api-key-here\n\n");
        }

        // Write model name
        try file.writeAll("# Model name served by your backend\n");
        try file.writeAll("OMNIRLM_MODEL_NAME=");
        try file.writeAll(model_name);
        try file.writeAll("\n\n");
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

    fn copyToolsDir(self: Runtime) !void {
        const src_dir_path = "src/tools";
        const dst_dir_path = ".omniclaw/tools";

        // Create destination directory if it doesn't exist
        std.fs.cwd().makeDir(dst_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        try self.copyDirRecursive(src_dir_path, dst_dir_path);
    }

    fn copyDirRecursive(self: Runtime, src_path: []const u8, dst_path: []const u8) !void {
        var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
        defer src_dir.close();

        var dst_dir = try std.fs.cwd().openDir(dst_path, .{});
        defer dst_dir.close();

        var iter = src_dir.iterate();
        while (try iter.next()) |entry| {
            const src_entry_path = try std.fs.path.join(self.allocator, &.{ src_path, entry.name });
            defer self.allocator.free(src_entry_path);
            const dst_entry_path = try std.fs.path.join(self.allocator, &.{ dst_path, entry.name });
            defer self.allocator.free(dst_entry_path);

            switch (entry.kind) {
                .file => {
                    try self.copyFile(src_entry_path, dst_entry_path);
                },
                .directory => {
                    dst_dir.makeDir(entry.name) catch |err| {
                        if (err != error.PathAlreadyExists) return err;
                    };
                    try self.copyDirRecursive(src_entry_path, dst_entry_path);
                },
                else => {},
            }
        }
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
