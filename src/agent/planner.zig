const std = @import("std");
const RLM = @import("omni-rlm").RLM;
const Log = @import("omni-rlm").RLMLogger;

const ModelHandler = @import("omni-rlm").ModelHandler;
const Message = @import("omni-rlm").Message;

pub const Plan = struct {
    tool: []const u8,
    argument: []const u8,
};

// Paths to tool documentation
const TOOLS_MD_PATH = "/Users/gabe/Desktop/HUAWEI/omni-claw/src/tools/tools.md";
const TOOLS_DOCS_DIR = "src/tools/docs/";

const STAGE1_SYSTEM_PROMPT =
    \\You are omniclaw, an AI agent assistant. Your task is to analyze user requests and select the appropriate tool to execute.
    \\
    \\Available tools:
    \\{s}
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

    return try std.fmt.allocPrint(allocator, STAGE1_SYSTEM_PROMPT, .{tools_md_buf});
}

pub const Planner = struct {
    allocator: std.mem.Allocator,
    rlm: ?RLM,
    model: ModelHandler,

    pub fn init(allocator: std.mem.Allocator) Planner {
        return .{
            .allocator = allocator,
            .rlm = null,
            .model = ModelHandler{},
        };
    }

    pub fn deinit(self: *Planner) void {
        if (self.rlm) |*rlm| rlm.deinit();
    }

    pub fn setConnectionConfig(self: *Planner, base_url: []const u8, api_key: ?[]const u8, model_name: ?[]const u8) !void {
        self.model = ModelHandler{
            .base_url = base_url,
            .api_key = api_key.?,
            .model_name = model_name.?,
        };
    }

    pub fn plan(self: *Planner, prompt: []const u8) !Plan {
        // TODO repeated code with executor - need to refactor to avoid duplication
        if (prompt.len == 0) {
            return Plan{ .tool = try self.allocator.dupe(u8, "exec"), .argument = try self.allocator.dupe(u8, "echo 'No command provided'") };
        }

        var messages: std.ArrayList(Message) = .empty;
        defer messages.deinit(self.allocator);
        try messages.append(self.allocator, Message{
            .role = "system",
            .content = try build_system_prompt(self.allocator),
        });
        try messages.append(self.allocator, Message{
            .role = "user",
            .content = prompt,
        });

        const response = try self.model.make_request(messages.items, self.allocator);
        // response = response[8 .. response.len - 4]; // Strip code block markdown

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
