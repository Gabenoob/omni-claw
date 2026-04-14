const std = @import("std");

pub const EmbeddedToolFile = struct {
    relative_path: []const u8,
    content: []const u8,
};

pub const embedded_tool_files = [_]EmbeddedToolFile{
    .{
        .relative_path = "TOOLS.md",
        .content = @embedFile("TOOLS.md"),
    },
    .{
        .relative_path = "docs/exec.md",
        .content = @embedFile("docs/exec.md"),
    },
    .{
        .relative_path = "docs/finish.md",
        .content = @embedFile("docs/finish.md"),
    },
};

pub fn writeEmbeddedTools(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !void {
    try base_dir.makePath("tools/docs");

    for (embedded_tool_files) |file| {
        const output_path = try std.fs.path.join(allocator, &.{ "tools", file.relative_path });
        defer allocator.free(output_path);

        var output = try base_dir.createFile(output_path, .{});
        defer output.close();
        try output.writeAll(file.content);
    }
}
