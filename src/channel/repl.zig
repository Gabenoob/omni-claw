const std = @import("std");
const Agent = @import("../agent/mod.zig").Agent;

const MAX_HISTORY = 100;
const MAX_LINE_LEN = 2048;
const CONVERSATION_LOG_PATH = @import("../agent/planner.zig").CONVERSATION_LOG_PATH;

// UTF-8 character state for multi-byte character handling
const Utf8State = struct {
    buf: [4]u8 = undefined,
    len: u3 = 0, // expected total bytes
    count: u3 = 0, // current bytes received

    fn reset(self: *Utf8State) void {
        self.len = 0;
        self.count = 0;
    }

    fn isComplete(self: Utf8State) bool {
        return self.len > 0 and self.count == self.len;
    }

    fn feed(self: *Utf8State, byte: u8) ?[]const u8 {
        // Start of a new UTF-8 sequence
        if (self.count == 0) {
            if (byte < 0x80) {
                // ASCII - single byte
                self.buf[0] = byte;
                return self.buf[0..1];
            } else if ((byte & 0xE0) == 0xC0) {
                // 2-byte sequence: 110xxxxx
                self.len = 2;
            } else if ((byte & 0xF0) == 0xE0) {
                // 3-byte sequence: 1110xxxx (Chinese usually here)
                self.len = 3;
            } else if ((byte & 0xF8) == 0xF0) {
                // 4-byte sequence: 11110xxx
                self.len = 4;
            } else {
                // Invalid start byte, treat as single byte
                self.buf[0] = byte;
                return self.buf[0..1];
            }
            self.buf[0] = byte;
            self.count = 1;
            return null; // Need more bytes
        } else {
            // Continuation byte: 10xxxxxx
            if ((byte & 0xC0) != 0x80) {
                // Invalid continuation, reset and treat as new start
                self.reset();
                return self.feed(byte);
            }
            self.buf[self.count] = byte;
            self.count += 1;
            if (self.count == self.len) {
                const result = self.buf[0..self.len];
                self.reset();
                return result;
            }
            return null; // Need more bytes
        }
    }
};

pub const Repl = struct {
    allocator: std.mem.Allocator,
    agent: *Agent,
    stdin: std.fs.File,
    stdout: std.fs.File,

    // Line editing state
    line_buf: [MAX_LINE_LEN]u8,
    line_len: usize,
    cursor_pos: usize,

    // Command history
    history: std.ArrayList([]const u8),
    history_pos: ?usize,

    pub fn init(allocator: std.mem.Allocator, agent: *Agent) Repl {
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
            var utf8_state = Utf8State{};

            while (true) {
                var byte: [1]u8 = undefined;
                const n = try self.stdin.read(&byte);
                if (n == 0) return;

                const key = byte[0];

                // Handle escape sequences (arrow keys, etc.)
                if (key == '\x1b') {
                    // Cancel any pending UTF-8 sequence when ESC is pressed
                    utf8_state.reset();
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
                        utf8_state.reset();
                        try self.stdout.writeAll("\n");
                        break;
                    },
                    '\x03' => return, // Ctrl+C
                    '\x04' => return, // Ctrl+D
                    '\x7f' => {
                        utf8_state.reset();
                        try self.backspace();
                    }, // Backspace
                    0x01 => {
                        utf8_state.reset();
                        try self.moveCursorHome();
                    }, // Ctrl+A
                    0x05 => {
                        utf8_state.reset();
                        try self.moveCursorEnd();
                    }, // Ctrl+E
                    0x0b => {
                        utf8_state.reset();
                        try self.clearToEnd();
                    }, // Ctrl+K
                    0x15 => {
                        utf8_state.reset();
                        try self.clearLine();
                    }, // Ctrl+U
                    else => {
                        // Accept all non-control characters (>= 32) as potential UTF-8
                        if (key >= 32) {
                            if (utf8_state.feed(key)) |utf8_char| {
                                try self.insertUtf8Char(utf8_char);
                            }
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
            if (std.mem.eql(u8, line, "/tools")) {
                try self.agent.printTools();
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

    fn insertUtf8Char(self: *Repl, utf8_char: []const u8) !void {
        if (self.line_len + utf8_char.len > MAX_LINE_LEN) return;
        const char_len = utf8_char.len;

        // Make room if inserting in the middle
        if (self.cursor_pos < self.line_len) {
            var i = self.line_len;
            while (i > self.cursor_pos) : (i -= 1) {
                self.line_buf[i + char_len - 1] = self.line_buf[i - 1];
            }
        }

        // Insert the UTF-8 character
        @memcpy(self.line_buf[self.cursor_pos..][0..char_len], utf8_char);
        self.line_len += char_len;
        self.cursor_pos += char_len;

        // Redraw entire line to handle display width correctly
        try self.redrawLine();
    }

    // Redraw the entire current line with cursor at correct position
    fn redrawLine(self: *Repl) !void {
        // Move to start of line and clear it, then redraw prompt
        try self.stdout.writeAll("\r\x1b[K> ");
        // Write the entire line content
        try self.stdout.writeAll(self.line_buf[0..self.line_len]);

        // Now position cursor correctly - go to end then move back
        // We need to calculate display width of characters after cursor
        const bytes_after = self.line_len - self.cursor_pos;
        if (bytes_after > 0) {
            // To position cursor correctly without knowing display widths,
            // we use a different approach: go to start and move forward
            // But that's complex with variable-width characters.
            // Instead: clear and redraw with cursor at end of visible portion

            // Actually, simpler approach: go to start of line (\r),
            // write prompt + content up to cursor, then we're done
            try self.stdout.writeAll("\r> ");
            try self.stdout.writeAll(self.line_buf[0..self.cursor_pos]);
        }
    }

    // Get the byte length of the UTF-8 character ending at position 'pos'
    fn getPrevUtf8CharLen(self: *Repl, pos: usize) usize {
        if (pos == 0) return 0;
        // Scan backwards to find the start of the UTF-8 character
        var i: usize = pos - 1;
        // Look for a start byte (not 10xxxxxx pattern)
        while (i > 0 and (self.line_buf[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        // Check if it's a valid start byte
        if ((self.line_buf[i] & 0xC0) == 0x80) {
            // Invalid - should not happen in valid UTF-8, but handle gracefully
            return pos - i;
        }
        return pos - i;
    }

    fn backspace(self: *Repl) !void {
        if (self.cursor_pos == 0) return;

        // Find the start of the previous UTF-8 character
        const char_len = self.getPrevUtf8CharLen(self.cursor_pos);
        if (char_len == 0) return;

        self.cursor_pos -= char_len;

        // Shift remaining characters left
        var i = self.cursor_pos;
        while (i < self.line_len - char_len) : (i += 1) {
            self.line_buf[i] = self.line_buf[i + char_len];
        }

        self.line_len -= char_len;

        // Redraw entire line
        try self.redrawLine();
    }

    // Get the byte length of the UTF-8 character starting at position 'pos'
    fn getUtf8CharLen(self: *Repl, pos: usize) usize {
        if (pos >= self.line_len) return 0;
        const first_byte = self.line_buf[pos];
        if (first_byte < 0x80) return 1;
        if ((first_byte & 0xE0) == 0xC0) return 2;
        if ((first_byte & 0xF0) == 0xE0) return 3;
        if ((first_byte & 0xF8) == 0xF0) return 4;
        return 1; // Invalid, treat as single byte
    }

    fn deleteChar(self: *Repl) !void {
        if (self.cursor_pos >= self.line_len) return;

        // Find the byte length of the character at cursor
        const char_len = self.getUtf8CharLen(self.cursor_pos);
        if (char_len == 0) return;

        // Shift remaining characters left
        var i = self.cursor_pos;
        while (i < self.line_len - char_len) : (i += 1) {
            self.line_buf[i] = self.line_buf[i + char_len];
        }

        self.line_len -= char_len;

        // Redraw entire line
        try self.redrawLine();
    }

    fn moveCursorLeft(self: *Repl) !void {
        if (self.cursor_pos == 0) return;
        // Move by one UTF-8 character (may be multiple bytes)
        const char_len = self.getPrevUtf8CharLen(self.cursor_pos);
        if (char_len == 0) return;
        self.cursor_pos -= char_len;
        try self.redrawLine();
    }

    fn moveCursorRight(self: *Repl) !void {
        if (self.cursor_pos >= self.line_len) return;
        // Move by one UTF-8 character (may be multiple bytes)
        const char_len = self.getUtf8CharLen(self.cursor_pos);
        if (char_len == 0) return;
        self.cursor_pos += char_len;
        try self.redrawLine();
    }

    fn moveCursorHome(self: *Repl) !void {
        if (self.cursor_pos == 0) return;
        self.cursor_pos = 0;
        try self.redrawLine();
    }

    fn moveCursorEnd(self: *Repl) !void {
        if (self.cursor_pos >= self.line_len) return;
        self.cursor_pos = self.line_len;
        try self.redrawLine();
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

fn deleteConversationLog() !void {
    std.fs.cwd().deleteFile(CONVERSATION_LOG_PATH) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

// Public API for backward compatibility
pub fn run(agent: *Agent) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    defer deleteConversationLog() catch |err| {
        std.debug.print("Warning: failed to delete {s}: {any}\n", .{ CONVERSATION_LOG_PATH, err });
    };

    var repl = Repl.init(gpa.allocator(), agent);
    defer repl.deinit();

    try repl.run();
}
