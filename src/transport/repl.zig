const std = @import("std");
const Agent = @import("../agent/mod.zig").Agent;

const MAX_HISTORY = 100;
const MAX_LINE_LEN = 2048;

pub const Repl = struct {
    allocator: std.mem.Allocator,
    agent: Agent,
    stdin: std.fs.File,
    stdout: std.fs.File,

    // Line editing state
    line_buf: [MAX_LINE_LEN]u8,
    line_len: usize,
    cursor_pos: usize,

    // Command history
    history: std.ArrayList([]const u8),
    history_pos: ?usize,

    pub fn init(allocator: std.mem.Allocator, agent: Agent) Repl {
        return .{
            .allocator = allocator,
            .agent = agent,
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
            .line_buf = undefined,
            .line_len = 0,
            .cursor_pos = 0,
            .history = .empty,
            .history_pos = null,
        };
    }

    pub fn deinit(self: *Repl) void {
        for (self.history.items) |item| {
            self.allocator.free(item);
        }
        self.history.deinit(self.allocator);
    }

    pub fn run(self: *Repl) !void {
        // Enable raw mode for terminal
        const original_termios = try enableRawMode(self.stdin);
        defer _ = disableRawMode(self.stdin, original_termios) catch {};

        while (true) {
            try self.stdout.writeAll("> ");
            self.resetLine();

            while (true) {
                var byte: [1]u8 = undefined;
                const n = try self.stdin.read(&byte);
                if (n == 0) return;

                const key = byte[0];

                // Handle escape sequences (arrow keys, etc.)
                if (key == '\x1b') {
                    const seq = try self.readEscapeSequence();
                    switch (seq) {
                        .up => try self.handleHistoryUp(),
                        .down => try self.handleHistoryDown(),
                        .left => try self.moveCursorLeft(),
                        .right => try self.moveCursorRight(),
                        .home => try self.moveCursorHome(),
                        .end => try self.moveCursorEnd(),
                        .delete => try self.deleteChar(),
                        .none => {},
                    }
                    continue;
                }

                // Handle control characters
                switch (key) {
                    '\n', '\r' => {
                        try self.stdout.writeAll("\n");
                        break;
                    },
                    '\x03' => return, // Ctrl+C
                    '\x04' => return, // Ctrl+D
                    '\x7f' => try self.backspace(), // Backspace
                    0x01 => try self.moveCursorHome(), // Ctrl+A
                    0x05 => try self.moveCursorEnd(), // Ctrl+E
                    0x0b => try self.clearToEnd(), // Ctrl+K
                    0x15 => try self.clearLine(), // Ctrl+U
                    else => {
                        if (key >= 32 and key <= 126) {
                            try self.insertChar(key);
                        }
                    },
                }
            }

            const line = std.mem.trim(u8, self.line_buf[0..self.line_len], " \t\r\n");
            if (line.len == 0) continue;

            // Save to history
            try self.addToHistory(line);

            // Handle built-in commands
            if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return;
            if (std.mem.eql(u8, line, "/config")) {
                try self.agent.printConfig();
                continue;
            }

            try self.agent.runPrompt(line);
        }
    }

    fn resetLine(self: *Repl) void {
        self.line_len = 0;
        self.cursor_pos = 0;
        self.history_pos = null;
    }

    fn addToHistory(self: *Repl, line: []const u8) !void {
        // Don't add duplicates of the most recent command
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }

        const copy = try self.allocator.dupe(u8, line);
        try self.history.append(self.allocator, copy);

        // Limit history size
        if (self.history.items.len > MAX_HISTORY) {
            const old = self.history.orderedRemove(0);
            self.allocator.free(old);
        }
    }

    fn readEscapeSequence(self: *Repl) !EscapeSequence {
        var buf: [4]u8 = undefined;

        // Read '[' or 'O'
        const n1 = try self.stdin.read(buf[0..1]);
        if (n1 == 0 or buf[0] != '[') return .none;

        // Read the command character
        const n2 = try self.stdin.read(buf[1..2]);
        if (n2 == 0) return .none;

        switch (buf[1]) {
            'A' => return .up,
            'B' => return .down,
            'C' => return .right,
            'D' => return .left,
            'H' => return .home,
            'F' => return .end,
            '3' => {
                // Check for ~ after 3 (Delete key)
                const n3 = try self.stdin.read(buf[2..3]);
                if (n3 > 0 and buf[2] == '~') return .delete;
                return .none;
            },
            else => return .none,
        }
    }

    fn insertChar(self: *Repl, c: u8) !void {
        if (self.line_len >= MAX_LINE_LEN) return;

        // Make room if inserting in the middle
        if (self.cursor_pos < self.line_len) {
            var i = self.line_len;
            while (i > self.cursor_pos) : (i -= 1) {
                self.line_buf[i] = self.line_buf[i - 1];
            }
        }

        self.line_buf[self.cursor_pos] = c;
        self.line_len += 1;

        // Echo the character to stdout (raw mode has echo disabled)
        try self.stdout.writeAll(&.{c});

        self.cursor_pos += 1;

        // If there are characters after cursor, redraw them and move cursor back
        if (self.cursor_pos < self.line_len) {
            try self.stdout.writeAll(self.line_buf[self.cursor_pos..self.line_len]);

            // Move cursor back to correct position
            const chars_after = self.line_len - self.cursor_pos;
            var buf: [32]u8 = undefined;
            const esc = try std.fmt.bufPrint(&buf, "\x1b[{}D", .{chars_after});
            try self.stdout.writeAll(esc);
        }
    }

    fn backspace(self: *Repl) !void {
        if (self.cursor_pos == 0) return;

        // Move cursor left first
        try self.stdout.writeAll("\x1b[D");
        self.cursor_pos -= 1;

        // Shift characters left
        var i = self.cursor_pos;
        while (i < self.line_len - 1) : (i += 1) {
            self.line_buf[i] = self.line_buf[i + 1];
        }

        self.line_len -= 1;

        // Redraw from cursor and clear the last character
        try self.redrawFromCursor();
        try self.stdout.writeAll(" ");

        // Move cursor back to the correct position
        if (self.cursor_pos < self.line_len) {
            const chars_after = self.line_len - self.cursor_pos + 1; // +1 for the space we just wrote
            var buf: [32]u8 = undefined;
            const esc = try std.fmt.bufPrint(&buf, "\x1b[{}D", .{chars_after});
            try self.stdout.writeAll(esc);
        } else {
            // At end of line, just move back one for the space
            try self.stdout.writeAll("\x1b[D");
        }
    }

    fn deleteChar(self: *Repl) !void {
        if (self.cursor_pos >= self.line_len) return;

        var i = self.cursor_pos;
        while (i < self.line_len - 1) : (i += 1) {
            self.line_buf[i] = self.line_buf[i + 1];
        }

        self.line_len -= 1;
        try self.redrawFromCursor();
        try self.stdout.writeAll(" ");

        // Move cursor back to the correct position
        if (self.cursor_pos < self.line_len) {
            const chars_after = self.line_len - self.cursor_pos + 1; // +1 for the space we just wrote
            var buf: [32]u8 = undefined;
            const esc = try std.fmt.bufPrint(&buf, "\x1b[{}D", .{chars_after});
            try self.stdout.writeAll(esc);
        } else {
            // At end of line, just move back one for the space
            try self.stdout.writeAll("\x1b[D");
        }
    }

    fn moveCursorLeft(self: *Repl) !void {
        if (self.cursor_pos == 0) return;
        self.cursor_pos -= 1;
        try self.stdout.writeAll("\x1b[D");
    }

    fn moveCursorRight(self: *Repl) !void {
        if (self.cursor_pos >= self.line_len) return;
        self.cursor_pos += 1;
        try self.stdout.writeAll("\x1b[C");
    }

    fn moveCursorHome(self: *Repl) !void {
        if (self.cursor_pos == 0) return;
        const move = self.cursor_pos;
        var buf: [32]u8 = undefined;
        const esc = try std.fmt.bufPrint(&buf, "\x1b[{}D", .{move});
        try self.stdout.writeAll(esc);
        self.cursor_pos = 0;
    }

    fn moveCursorEnd(self: *Repl) !void {
        if (self.cursor_pos >= self.line_len) return;
        const move = self.line_len - self.cursor_pos;
        var buf: [32]u8 = undefined;
        const esc = try std.fmt.bufPrint(&buf, "\x1b[{}C", .{move});
        try self.stdout.writeAll(esc);
        self.cursor_pos = self.line_len;
    }

    fn clearToEnd(self: *Repl) !void {
        self.line_len = self.cursor_pos;
        try self.stdout.writeAll("\x1b[K");
    }

    fn clearLine(self: *Repl) !void {
        try self.stdout.writeAll("\x1b[2K\r> ");
        self.line_len = 0;
        self.cursor_pos = 0;
    }

    fn redrawFromCursor(self: *Repl) !void {
        // Clear from cursor to end
        try self.stdout.writeAll("\x1b[K");
        // Write remaining characters
        if (self.cursor_pos < self.line_len) {
            try self.stdout.writeAll(self.line_buf[self.cursor_pos..self.line_len]);
        }
    }

    fn handleHistoryUp(self: *Repl) !void {
        if (self.history.items.len == 0) return;

        const new_pos: usize = if (self.history_pos) |pos|
            if (pos > 0) pos - 1 else 0
        else
            self.history.items.len - 1;

        if (self.history_pos == null or new_pos != self.history_pos.?) {
            self.history_pos = new_pos;
            try self.setLine(self.history.items[new_pos]);
        }
    }

    fn handleHistoryDown(self: *Repl) !void {
        if (self.history_pos == null) return;

        const current = self.history_pos.?;
        if (current + 1 >= self.history.items.len) {
            self.history_pos = null;
            try self.clearLine();
            return;
        }

        self.history_pos = current + 1;
        try self.setLine(self.history.items[self.history_pos.?]);
    }

    fn setLine(self: *Repl, line: []const u8) !void {
        // Clear current line
        try self.stdout.writeAll("\x1b[2K\r> ");

        // Copy new line
        const len = @min(line.len, MAX_LINE_LEN);
        @memcpy(self.line_buf[0..len], line[0..len]);
        self.line_len = len;
        self.cursor_pos = len;

        // Write new line
        try self.stdout.writeAll(self.line_buf[0..len]);
    }
};

const EscapeSequence = enum {
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    none,
};

// Terminal handling - use std.posix.termios for cross-platform compatibility
const Termios = std.posix.termios;

fn enableRawMode(stdin: std.fs.File) !Termios {
    const fd = stdin.handle;

    var termios = try std.posix.tcgetattr(fd);
    const original = termios;

    // Disable canonical mode and echo
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.lflag.ISIG = false;

    // Set minimum characters and timeout
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    try std.posix.tcsetattr(fd, .FLUSH, termios);

    return original;
}

fn disableRawMode(stdin: std.fs.File, original: Termios) !void {
    try std.posix.tcsetattr(stdin.handle, .FLUSH, original);
}

// Public API for backward compatibility
pub fn run(agent: Agent) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var repl = Repl.init(gpa.allocator(), agent);
    defer repl.deinit();

    try repl.run();
}
