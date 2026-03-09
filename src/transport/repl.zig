const std = @import("std");
const Agent = @import("../agent/agent.zig").Agent;

pub fn run(agent: *Agent) !void {
    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    var line_buf: [2048]u8 = undefined;

    while (true) {
        try stdout_file.writeAll("> ");

        var i: usize = 0;
        while (true) {
            var byte: [1]u8 = undefined;
            const n = try stdin_file.read(&byte);

            if (n == 0) return;
            if (byte[0] == '\n') break;

            if (i < line_buf.len) {
                line_buf[i] = byte[0];
                i += 1;
            }
        }

        const line = std.mem.trim(u8, line_buf[0..i], " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) return;

        try agent.runPrompt(line);
    }
}
