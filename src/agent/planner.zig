const std = @import("std");
const Config = @import("../omniclaw.zig").Config;
const RLM = @import("omni-rlm").RLM;
const Log = @import("omni-rlm").RLMLogger;

const ModelHandler = @import("omni-rlm").ModelHandler;
const Message = @import("omni-rlm").Message;

pub const Plan = struct {
    tool: []const u8,
    argument: []const u8,
};

pub const ToolCallRecord = struct {
    tool: []const u8,
    argument: []const u8,
    result: []const u8,
    success: bool,

    pub fn deinit(self: *ToolCallRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
        allocator.free(self.argument);
        allocator.free(self.result);
    }
};

pub const PlanResult = struct {
    final_output: []const u8,
    tool_calls: std.ArrayList(ToolCallRecord),

    pub fn deinit(self: *PlanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.final_output);
        for (self.tool_calls.items) |*call| {
            call.deinit(allocator);
        }
        self.tool_calls.deinit(allocator);
    }
};

// Paths to tool documentation
const TOOLS_MD_PATH = "tools/tools.md";
const TOOLS_DOCS_DIR = "tools/docs/";

// Conversation log path
const CONVERSATION_LOG_PATH = "logs/conversation.jsonl";

const STAGE1_SYSTEM_PROMPT =
    \\You are omniclaw, an AI agent assistant. Your task is to analyze user requests and select the appropriate tool to execute.
    \\
    \\Available tools:
    \\{s}
    \\
    \\Tool Documentation:
    \\You can check detailed tool usage by reading the file at: {s}<tool_name>.md
    \\For example, to check the "exec" tool documentation, read: {s}exec.md
    \\
    \\Instructions:
    \\1. Analyze the user's request carefully
    \\2. Select the most appropriate tool from the available tools
    \\3. Return your response in this JSON format:
    \\{{
    \\    "tool": "<tool_name>",
    \\    "argument": "<arg1> <arg2> ..."
    \\}}
    \\
    \\After you execute a tool and receive results, continue planning if more information is needed.
    \\
    \\When the user's request is fully satisfied and you have collected sufficient information to provide a complete answer:
    \\- Verify that you have all necessary data to answer the original request
    \\- Ensure the information is accurate and complete
    \\- Provide your final response using the "finish" tool:
    \\{{
    \\    "tool": "finish",
    \\    "argument": "A brief summary of the findings and the complete answer to the user's request"
    \\}}
    \\
    \\Important: 
    \\* Only use the "finish" tool when you are confident the user's request has been fully addressed with sufficient information.
    \\* YOU MUST RETURN A TOOL CALL IN EVERY RESPONSE, EVEN IF YOU THINK THE REQUEST IS COMPLETE. DO NOT OMIT TOOL CALLS.
    \\
;
fn build_system_prompt(allocator: std.mem.Allocator) ![]const u8 {
    const tools_md = std.fs.cwd().openFile(TOOLS_MD_PATH, .{}) catch |err| {
        return try std.fmt.allocPrint(allocator, "Error loading tools documentation: {any}", .{err});
    };
    defer tools_md.close();

    const tools_md_size = try tools_md.getEndPos();
    const tools_md_buf = try allocator.alloc(u8, tools_md_size);
    defer allocator.free(tools_md_buf);
    _ = try tools_md.readAll(tools_md_buf);

    return try std.fmt.allocPrint(allocator, STAGE1_SYSTEM_PROMPT, .{ tools_md_buf, TOOLS_DOCS_DIR, TOOLS_DOCS_DIR });
}

pub const Planner = struct {
    allocator: std.mem.Allocator,
    rlm: ?RLM,
    model: ModelHandler,
    messages: std.ArrayList(Message),
    max_iterations: usize,
    conversation_log_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) Planner {
        return .{
            .allocator = allocator,
            .rlm = null,
            .model = ModelHandler{},
            .messages = std.ArrayList(Message).empty,
            .max_iterations = 10,
            .conversation_log_path = CONVERSATION_LOG_PATH,
        };
    }

    pub fn deinit(self: *Planner) void {
        if (self.rlm) |*rlm| rlm.deinit();
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
    }

    pub fn setConnectionConfig(self: *Planner, config: Config) !void {
        self.model = ModelHandler{
            .base_url = config.base_url,
            .api_key = config.api_key orelse "",
            .model_name = config.model_name,
        };
    }

    /// Initialize the conversation with system prompt and user input
    /// Loads previous conversation log if exists
    pub fn initializeConversation(self: *Planner, prompt: []const u8) !void {
        // Clear any existing messages
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
        self.messages = std.ArrayList(Message).empty;

        // Add system prompt
        const system_prompt = try build_system_prompt(self.allocator);
        try self.messages.append(self.allocator, Message{
            .role = try self.allocator.dupe(u8, "system"),
            .content = system_prompt,
        });

        // Load previous conversation history from log
        try self.loadConversationLog();

        // Add user prompt
        try self.messages.append(self.allocator, Message{
            .role = try self.allocator.dupe(u8, "user"),
            .content = try self.allocator.dupe(u8, prompt),
        });

        // Save the new user message to log
        try self.appendMessageToLog("user", prompt);
    }

    /// Load conversation log from file and add to messages
    fn loadConversationLog(self: *Planner) !void {
        const file = std.fs.cwd().openFile(self.conversation_log_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No existing log, that's ok
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 10); // Max 10MB
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            // Parse JSON line: {"role": "...", "content": "..."}
            const parsed = std.json.parseFromSlice(struct {
                role: []const u8,
                content: []const u8,
            }, self.allocator, trimmed, .{}) catch continue; // Skip invalid lines
            defer parsed.deinit();

            // Skip system messages from log (we already added it)
            if (std.mem.eql(u8, parsed.value.role, "system")) continue;

            try self.messages.append(self.allocator, Message{
                .role = try self.allocator.dupe(u8, parsed.value.role),
                .content = try self.allocator.dupe(u8, parsed.value.content),
            });
        }
    }

    /// Append a single message to the log file
    fn appendMessageToLog(self: *Planner, role: []const u8, content: []const u8) !void {
        // Ensure logs directory exists
        std.fs.cwd().makeDir("logs") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Open file for appending (create if doesn't exist)
        const file = std.fs.cwd().openFile(self.conversation_log_path, .{ .mode = .write_only, .lock = .none }) catch |err| {
            if (err == error.FileNotFound) {
                // Create new file
                const new_file = try std.fs.cwd().createFile(self.conversation_log_path, .{});
                defer new_file.close();

                // Escape content for JSON
                const escaped_content = try escapeJsonString(self.allocator, content);
                defer self.allocator.free(escaped_content);

                const line = try std.fmt.allocPrint(self.allocator, "{{\"role\":\"{s}\",\"content\":\"{s}\"}}\n", .{ role, escaped_content });
                defer self.allocator.free(line);

                try new_file.writeAll(line);
                return;
            }
            return err;
        };
        defer file.close();

        // Seek to end for appending
        try file.seekFromEnd(0);

        // Escape content for JSON
        const escaped_content = try escapeJsonString(self.allocator, content);
        defer self.allocator.free(escaped_content);

        const line = try std.fmt.allocPrint(self.allocator, "{{\"role\":\"{s}\",\"content\":\"{s}\"}}\n", .{ role, escaped_content });
        defer self.allocator.free(line);

        try file.writeAll(line);
    }

    /// Save all messages to conversation log (overwrites existing)
    pub fn saveConversationLog(self: *Planner) !void {
        // Ensure logs directory exists
        std.fs.cwd().makeDir("logs") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const file = try std.fs.cwd().createFile(self.conversation_log_path, .{});
        defer file.close();

        for (self.messages.items) |msg| {
            // Skip system messages in log
            if (std.mem.eql(u8, msg.role, "system")) continue;

            const escaped_content = try escapeJsonString(self.allocator, msg.content);
            defer self.allocator.free(escaped_content);

            const line = try std.fmt.allocPrint(self.allocator, "{{\"role\":\"{s}\",\"content\":\"{s}\"}}\n", .{ msg.role, escaped_content });
            defer self.allocator.free(line);

            try file.writeAll(line);
        }
    }

    /// Escape special characters in a string for JSON
    fn escapeJsonString(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        for (str) |c| {
            switch (c) {
                '"' => try result.appendSlice(allocator, "\\\""),
                '\\' => try result.appendSlice(allocator, "\\\\"),
                '\n' => try result.appendSlice(allocator, "\\n"),
                '\r' => try result.appendSlice(allocator, "\\r"),
                '\t' => try result.appendSlice(allocator, "\\t"),
                0x08 => try result.appendSlice(allocator, "\\b"), // backspace
                0x0C => try result.appendSlice(allocator, "\\f"), // form feed
                else => {
                    if (c < 0x20) {
                        // Control characters
                        try result.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\u{X:0>4}", .{c}));
                    } else {
                        try result.append(allocator, c);
                    }
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get next plan from LLM (single iteration)
    pub fn getNextPlan(self: *Planner) !Plan {
        const response = try self.model.make_request(self.messages.items, self.allocator);
        defer self.allocator.free(response);

        const parsed: std.json.Parsed(Plan) = try std.json.parseFromSlice(
            Plan,
            self.allocator,
            response,
            .{},
        );
        defer parsed.deinit();

        // Store assistant's response in message history
        const assistant_content = try self.allocator.dupe(u8, response);
        try self.messages.append(self.allocator, Message{
            .role = "assistant",
            .content = assistant_content,
        });

        // Save to conversation log
        try self.appendMessageToLog("assistant", response);

        return Plan{
            .tool = try self.allocator.dupe(u8, parsed.value.tool),
            .argument = try self.allocator.dupe(u8, parsed.value.argument),
        };
    }

    /// Add tool result to message history
    pub fn addToolResult(self: *Planner, tool_name: []const u8, result_output: []const u8, success: bool) !void {
        const content = try std.fmt.allocPrint(
            self.allocator,
            "Tool '{s}' executed. Success: {}. Result: {s}",
            .{ tool_name, success, result_output },
        );

        try self.messages.append(self.allocator, Message{
            .role = "user",
            .content = content,
        });

        // Save to conversation log
        try self.appendMessageToLog("user", content);
    }

    /// Execute plan recursively until finish tool is called or max iterations reached
    pub fn executeRecursive(self: *Planner, execute_tool: *const fn (allocator: std.mem.Allocator, tool: []const u8, argument: []const u8) anyerror!@import("../tools/registry.zig").ToolResult) !PlanResult {
        const ToolResult = @import("../tools/registry.zig").ToolResult;
        var tool_calls: std.ArrayList(ToolCallRecord) = .empty;
        errdefer {
            for (tool_calls.items) |*call| {
                call.deinit(self.allocator);
            }
            tool_calls.deinit(self.allocator);
        }

        var iteration: usize = 0;
        while (iteration < self.max_iterations) : (iteration += 1) {
            // Get next plan from LLM
            const current_plan = try self.getNextPlan();

            // Check if this is the finish tool
            if (std.mem.eql(u8, current_plan.tool, "finish")) {
                const result = PlanResult{
                    .final_output = try self.allocator.dupe(u8, current_plan.argument),
                    .tool_calls = tool_calls,
                };
                self.allocator.free(current_plan.tool);
                self.allocator.free(current_plan.argument);
                return result;
            }

            // Execute the tool
            const tool_result: ToolResult = try execute_tool(self.allocator, current_plan.tool, current_plan.argument);
            defer self.allocator.free(tool_result.output);

            // Record the tool call
            try tool_calls.append(self.allocator, .{
                .tool = try self.allocator.dupe(u8, current_plan.tool),
                .argument = try self.allocator.dupe(u8, current_plan.argument),
                .result = try self.allocator.dupe(u8, tool_result.output),
                .success = tool_result.success,
            });

            // Add result to message history for next iteration
            try self.addToolResult(current_plan.tool, tool_result.output, tool_result.success);

            // Clean up plan
            self.allocator.free(current_plan.tool);
            self.allocator.free(current_plan.argument);
        }

        // Max iterations reached
        return error.MaxIterationsReached;
    }

    /// Legacy plan function - single iteration
    pub fn plan(self: *Planner, prompt: []const u8) !Plan {
        try self.initializeConversation(prompt);

        const response = try self.model.make_request(self.messages.items, self.allocator);
        defer self.allocator.free(response);

        const parsed: std.json.Parsed(Plan) = try std.json.parseFromSlice(
            Plan,
            self.allocator,
            response,
            .{},
        );
        defer parsed.deinit();

        return Plan{
            .tool = try self.allocator.dupe(u8, parsed.value.tool),
            .argument = try self.allocator.dupe(u8, parsed.value.argument),
        };
    }
};
