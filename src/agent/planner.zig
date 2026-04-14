const std = @import("std");
const Config = @import("../omniclaw.zig").Config;

const ModelHandler = @import("omni-rlm").ModelHandler;
const Message = @import("omni-rlm").Message;

pub const Plan = struct {
    tool: []const u8,
    arguments: std.ArrayList([]const u8),

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.arguments.items) |arg| {
            allocator.free(arg);
        }
        self.arguments.deinit(allocator);
        allocator.free(self.tool);
    }
};

pub const ToolCallRecord = struct {
    tool: []const u8,
    arguments: std.ArrayList([]const u8),
    result: []const u8,
    success: bool,

    pub fn deinit(self: *ToolCallRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
        for (self.arguments.items) |arg| {
            allocator.free(arg);
        }
        self.arguments.deinit(allocator);
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

const ParsedPlanResponse = struct {
    plan: Plan,
    sanitized_response: []const u8,

    pub fn deinit(self: *ParsedPlanResponse, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        allocator.free(self.sanitized_response);
    }
};

// Paths to tool documentation
const TOOLS_MD_PATH = "tools/TOOLS.md";
const TOOLS_DOCS_DIR = "tools/docs/";

// Conversation log path
pub const CONVERSATION_LOG_PATH = "logs/conversation.jsonl";

const SYSTEM_PROMPT =
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
    \\    "arguments": ["<arg1>", "<arg2>", "..."]
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
    \\    "arguments": ["A brief summary of the findings and the complete answer to the user's request. Please reply in the same language as the user's original request."]
    \\}}
    \\
    \\Important: 
    \\* Only use the "finish" tool when you are confident the user's request has been fully addressed with sufficient information.
    \\* YOU MUST RETURN A TOOL CALL IN EVERY RESPONSE, EVEN IF YOU THINK THE REQUEST IS COMPLETE. DO NOT OMIT TOOL CALLS.
    \\
;

const JSON_REPAIR_SYSTEM_PROMPT =
    \\You are a strict JSON repair assistant for Omni-Claw plan outputs.
    \\Your job is to repair malformed JSON into a valid JSON object for tool execution.
    \\
    \\Output requirements:
    \\1. Return ONLY one JSON object, no markdown, no explanation.
    \\2. The JSON schema must be:
    \\{
    \\  "tool": "<tool_name>",
    \\  "arguments": ["<arg1>", "<arg2>"]
    \\}
    \\3. "tool" must be a string.
    \\4. "arguments" must be an array of strings. If missing, use [].
    \\5. Preserve the original intent as much as possible.
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

    return try std.fmt.allocPrint(allocator, SYSTEM_PROMPT, .{ tools_md_buf, TOOLS_DOCS_DIR, TOOLS_DOCS_DIR });
}

pub const Planner = struct {
    allocator: std.mem.Allocator,
    model: ModelHandler,
    messages: std.ArrayList(Message),
    max_iterations: usize,
    conversation_log_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, max_iterations: usize) Planner {
        return .{
            .allocator = allocator,
            .model = ModelHandler{},
            .messages = std.ArrayList(Message).empty,
            .max_iterations = max_iterations,
            .conversation_log_path = CONVERSATION_LOG_PATH,
        };
    }

    pub fn deinit(self: *Planner) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
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
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
        self.messages = std.ArrayList(Message).empty;

        // Add system prompt
        const system_prompt = try build_system_prompt(self.allocator);
        errdefer self.allocator.free(system_prompt);
        const role = try self.allocator.dupe(u8, "system");
        errdefer self.allocator.free(role);
        try self.messages.append(self.allocator, Message{
            .role = role,
            .content = system_prompt,
        });

        // Load previous conversation history from log
        try self.loadConversationLog();

        // Add user prompt
        const user_role = try self.allocator.dupe(u8, "user");
        errdefer self.allocator.free(user_role);
        const user_content = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(user_content);
        try self.messages.append(self.allocator, Message{
            .role = user_role,
            .content = user_content,
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
                        const escaped = try std.fmt.allocPrint(allocator, "\\u{X:0>4}", .{c});
                        defer allocator.free(escaped);
                        try result.appendSlice(allocator, escaped);
                    } else {
                        try result.append(allocator, c);
                    }
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn stripThinkTags(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var index: usize = 0;
        while (index < response.len) {
            if (std.mem.startsWith(u8, response[index..], "<think>")) {
                const content_start = index + "<think>".len;
                if (std.mem.indexOfPos(u8, response, content_start, "</think>")) |close_index| {
                    index = close_index + "</think>".len;
                    continue;
                }

                index = content_start;
                continue;
            }

            try result.append(allocator, response[index]);
            index += 1;
        }

        return result.toOwnedSlice(allocator);
    }

    fn extractFirstJsonObject(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
        var start_index: usize = 0;
        while (start_index < response.len) : (start_index += 1) {
            if (response[start_index] != '{') continue;

            var depth: usize = 0;
            var index = start_index;
            var in_string = false;
            var escaped = false;

            while (index < response.len) : (index += 1) {
                const char = response[index];

                if (in_string) {
                    if (escaped) {
                        escaped = false;
                        continue;
                    }

                    if (char == '\\') {
                        escaped = true;
                    } else if (char == '"') {
                        in_string = false;
                    }
                    continue;
                }

                switch (char) {
                    '"' => in_string = true,
                    '{' => depth += 1,
                    '}' => {
                        if (depth == 0) break;
                        depth -= 1;
                        if (depth == 0) {
                            return try allocator.dupe(u8, response[start_index .. index + 1]);
                        }
                    },
                    else => {},
                }
            }
        }

        return error.InvalidModelResponse;
    }

    fn sanitizePlanResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
        const without_think = try stripThinkTags(allocator, response);
        defer allocator.free(without_think);

        const trimmed = std.mem.trim(u8, without_think, " \t\r\n");
        return try extractFirstJsonObject(allocator, trimmed);
    }

    fn repairMalformedPlanJson(self: *Planner, malformed_json: []const u8, parse_error: anyerror) ![]const u8 {
        var repair_messages = std.ArrayList(Message).empty;
        defer {
            for (repair_messages.items) |msg| {
                self.allocator.free(msg.role);
                self.allocator.free(msg.content);
            }
            repair_messages.deinit(self.allocator);
        }

        const system_role = try self.allocator.dupe(u8, "system");
        errdefer self.allocator.free(system_role);
        const system_content = try self.allocator.dupe(u8, JSON_REPAIR_SYSTEM_PROMPT);
        errdefer self.allocator.free(system_content);
        try repair_messages.append(self.allocator, .{
            .role = system_role,
            .content = system_content,
        });

        const user_role = try self.allocator.dupe(u8, "user");
        errdefer self.allocator.free(user_role);
        const user_content = try std.fmt.allocPrint(
            self.allocator,
            "The following JSON is invalid. Parse error: {any}\n\nInvalid JSON:\n{s}",
            .{ parse_error, malformed_json },
        );
        errdefer self.allocator.free(user_content);
        try repair_messages.append(self.allocator, .{
            .role = user_role,
            .content = user_content,
        });

        const repair_response = try self.model.make_request(repair_messages, self.allocator, .{
            .enable_thinking = false,
            .stream = false,
        });
        defer self.allocator.free(repair_response);

        return try sanitizePlanResponse(self.allocator, repair_response);
    }

    // JSON structure for parsing plan response
    const JsonPlan = struct {
        tool: []const u8,
        arguments: [][]const u8,
    };

    fn parsePlanResponse(self: *Planner, response: []const u8) !ParsedPlanResponse {
        var sanitized_response = try sanitizePlanResponse(self.allocator, response);
        errdefer self.allocator.free(sanitized_response);

        const parsed: std.json.Parsed(JsonPlan) = std.json.parseFromSlice(
            JsonPlan,
            self.allocator,
            sanitized_response,
            .{},
        ) catch |parse_err| blk: {
            const repaired_response = try self.repairMalformedPlanJson(sanitized_response, parse_err);
            self.allocator.free(sanitized_response);
            sanitized_response = repaired_response;

            break :blk try std.json.parseFromSlice(
                JsonPlan,
                self.allocator,
                sanitized_response,
                .{},
            );
        };
        defer parsed.deinit();

        const tool = try self.allocator.dupe(u8, parsed.value.tool);
        errdefer self.allocator.free(tool);

        // Convert arguments array to ArrayList
        var arguments = std.ArrayList([]const u8).empty;
        errdefer {
            for (arguments.items) |arg| {
                self.allocator.free(arg);
            }
            arguments.deinit(self.allocator);
        }

        for (parsed.value.arguments) |arg| {
            const arg_copy = try self.allocator.dupe(u8, arg);
            errdefer self.allocator.free(arg_copy);
            try arguments.append(self.allocator, arg_copy);
        }

        return ParsedPlanResponse{
            .plan = .{
                .tool = tool,
                .arguments = arguments,
            },
            .sanitized_response = sanitized_response,
        };
    }

    /// Deep clone an ArrayList of strings (duplicates both the list and each string)
    pub fn cloneStringList(allocator: std.mem.Allocator, list: std.ArrayList([]const u8)) !std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item);
            }
            result.deinit(allocator);
        }

        for (list.items) |item| {
            const item_copy = try allocator.dupe(u8, item);
            errdefer allocator.free(item_copy);
            try result.append(allocator, item_copy);
        }

        return result;
    }

    /// Get next plan from LLM (single iteration)
    pub fn getNextPlan(self: *Planner) !Plan {
        const response = try self.model.make_request(self.messages, self.allocator, .{
            .enable_thinking = false,
            .stream = false,
        });
        defer self.allocator.free(response);

        var parsed_response = try self.parsePlanResponse(response);
        defer parsed_response.deinit(self.allocator);

        // Store assistant's response in message history
        const assistant_role = try self.allocator.dupe(u8, "assistant");
        errdefer self.allocator.free(assistant_role);
        // Clone sanitized_response since we need to keep it for both messages and log
        const content_copy = try self.allocator.dupe(u8, parsed_response.sanitized_response);
        errdefer self.allocator.free(content_copy);

        try self.messages.append(self.allocator, Message{
            .role = assistant_role,
            .content = content_copy,
        });
        // Save to conversation log
        try self.appendMessageToLog("assistant", parsed_response.sanitized_response);

        // Return a deep copy of the plan
        const tool_copy = try self.allocator.dupe(u8, parsed_response.plan.tool);
        errdefer self.allocator.free(tool_copy);
        const args_copy = try cloneStringList(self.allocator, parsed_response.plan.arguments);

        return Plan{
            .tool = tool_copy,
            .arguments = args_copy,
        };
    }

    /// Add tool result to message history
    pub fn addToolResult(self: *Planner, tool_name: []const u8, result_output: []const u8, success: bool) !void {
        const content = try std.fmt.allocPrint(
            self.allocator,
            "Tool '{s}' executed. Success: {}. Result: {s}",
            .{ tool_name, success, result_output },
        );
        errdefer self.allocator.free(content);

        const role = try self.allocator.dupe(u8, "user");
        errdefer self.allocator.free(role);

        try self.messages.append(self.allocator, Message{
            .role = role,
            .content = content,
        });

        // Save to conversation log
        try self.appendMessageToLog("user", content);
    }
};
