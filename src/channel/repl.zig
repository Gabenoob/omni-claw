const std = @import("std");
const Agent = @import("../agent/mod.zig").Agent;
const display_width = @import("display_width.zig");
const runtime = @import("../core/runtime.zig");

const MAX_HISTORY = 100;
const MAX_LINE_LEN = 2048;
const CONVERSATION_LOG_PATH = @import("../agent/planner.zig").CONVERSATION_LOG_PATH;
const PROMPT = "> ";
const DEFAULT_TERMINAL_COLS: usize = 80;
const ScreenPosition = struct {
    row: usize,
    col: usize,
};

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
    terminal_cols: usize,
    rendered_rows: usize,
    rendered_cursor_row: usize,

    // Command history
    history: std.ArrayList([]const u8),
    history_pos: ?usize,

    // Saved pre-raw termios so handlers can temporarily restore canonical mode.
    original_termios: std.posix.termios,

    pub fn init(allocator: std.mem.Allocator, agent: *Agent) Repl {
        return .{
            .allocator = allocator,
            .agent = agent,
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
            .line_buf = undefined,
            .line_len = 0,
            .cursor_pos = 0,
            .terminal_cols = DEFAULT_TERMINAL_COLS,
            .rendered_rows = 1,
            .rendered_cursor_row = 0,
            .history = .empty,
            .history_pos = null,
            .original_termios = undefined,
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
        self.original_termios = original_termios;
        defer _ = disableRawMode(self.stdin, original_termios) catch {};
        self.updateTerminalSize();

        while (true) {
            try self.stdout.writeAll(PROMPT);
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
                try self.handleConfigCommand();
                continue;
            }
            if (std.mem.eql(u8, line, "/tools")) {
                try self.agent.printTools();
                continue;
            }
            if (std.mem.eql(u8, line, "/compact")) {
                try self.agent.compactHistory();
                continue;
            }
            if (std.mem.eql(u8, line, "/context")) {
                try self.agent.printContextUsage();
                continue;
            }
            if (std.mem.eql(u8, line, "/help")) {
                try self.printHelp();
                continue;
            }

            try self.agent.runPrompt(line);
        }
    }

    fn printHelp(self: *Repl) !void {
        const help_text =
            "\n=== Available Commands ===\n" ++
            "  /help      Show this list of commands\n" ++
            "  /config    Show or modify the current LLM configuration\n" ++
            "  /tools     List registered tools\n" ++
            "  /context   Show current conversation context usage\n" ++
            "  /compact   Summarize older messages to shrink context\n" ++
            "  /exit, /quit  Quit the REPL\n" ++
            "Any other input is sent to the agent as a prompt.\n" ++
            "==========================\n\n";
        try self.stdout.writeAll(help_text);
    }

    fn handleConfigCommand(self: *Repl) !void {
        try self.agent.printConfig();

        const current = self.agent.config orelse {
            try self.stdout.writeAll("Configuration not loaded; cannot edit.\n\n");
            return;
        };

        // editConfigInteractive uses readLineAlloc, which needs canonical mode.
        try disableRawMode(self.stdin, self.original_termios);
        var new_cfg = runtime.editConfigInteractive(self.allocator, current) catch |err| {
            _ = enableRawMode(self.stdin) catch {};
            return err;
        };
        _ = enableRawMode(self.stdin) catch {};
        defer new_cfg.deinit(self.allocator);

        // CWD is already `.omniclaw/` inside the REPL (see Runtime.start), so
        // the .env lives in the current directory.
        try runtime.saveConfig(".env", new_cfg);
        try self.agent.configureLlmConnection(new_cfg);
        try self.stdout.writeAll("\n✓ Configuration updated.\n\n");
    }

    fn resetLine(self: *Repl) void {
        self.line_len = 0;
        self.cursor_pos = 0;
        self.rendered_rows = 1;
        self.rendered_cursor_row = 0;
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
        self.updateTerminalSize();
        try self.clearRenderedInput();
        try self.stdout.writeAll(PROMPT);
        try self.stdout.writeAll(self.line_buf[0..self.line_len]);

        const end_position = self.getScreenPosition(self.line_len);
        const cursor_position = self.getCursorPosition();

        if (end_position.row > cursor_position.row) {
            try self.moveCursorUp(end_position.row - cursor_position.row);
        }
        if (self.cursor_pos < self.line_len) {
            try self.moveCursorToColumn(cursor_position.col);
        }

        self.rendered_rows = self.getRenderedRows(self.line_len);
        self.rendered_cursor_row = cursor_position.row;
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
        try self.redrawLine();
    }

    fn clearLine(self: *Repl) !void {
        self.line_len = 0;
        self.cursor_pos = 0;
        try self.redrawLine();
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
        const len = @min(line.len, MAX_LINE_LEN);
        @memcpy(self.line_buf[0..len], line[0..len]);
        self.line_len = len;
        self.cursor_pos = len;
        try self.redrawLine();
    }

    fn clearRenderedInput(self: *Repl) !void {
        if (self.rendered_cursor_row > 0) {
            try self.moveCursorUp(self.rendered_cursor_row);
        }
        try self.stdout.writeAll("\r");

        var row: usize = 0;
        while (row < self.rendered_rows) : (row += 1) {
            try self.stdout.writeAll("\x1b[2K");
            if (row + 1 < self.rendered_rows) {
                try self.stdout.writeAll("\x1b[1B\r");
            }
        }

        if (self.rendered_rows > 1) {
            try self.moveCursorUp(self.rendered_rows - 1);
        }
        try self.stdout.writeAll("\r");
    }

    fn getRenderedRows(self: *Repl, line_len: usize) usize {
        const total_cols = self.getDisplayColumns(line_len);
        return @max(1, (total_cols + self.terminal_cols - 1) / self.terminal_cols);
    }

    fn getScreenPosition(self: *Repl, cursor_pos: usize) ScreenPosition {
        const total_cols = self.getDisplayColumns(cursor_pos);
        return .{
            .row = (total_cols - 1) / self.terminal_cols,
            .col = ((total_cols - 1) % self.terminal_cols) + 1,
        };
    }

    fn getCursorPosition(self: *Repl) ScreenPosition {
        if (self.cursor_pos >= self.line_len) {
            return self.getScreenPosition(self.line_len);
        }

        const next_cell = self.getDisplayColumns(self.cursor_pos) + 1;
        return .{
            .row = (next_cell - 1) / self.terminal_cols,
            .col = ((next_cell - 1) % self.terminal_cols) + 1,
        };
    }

    fn getDisplayColumns(self: *Repl, byte_len: usize) usize {
        var cols: usize = PROMPT.len;
        var i: usize = 0;
        const end = @min(byte_len, self.line_len);

        while (i < end) {
            const char_len = self.getUtf8CharLen(i);
            const next = @min(i + char_len, end);
            cols += self.getCodepointDisplayWidth(self.line_buf[i..next]);
            i = next;
        }

        return cols;
    }

    fn getCodepointDisplayWidth(self: *Repl, utf8_char: []const u8) usize {
        _ = self;
        return display_width.codepointDisplayWidth(utf8_char);
    }

    fn moveCursorUp(self: *Repl, rows: usize) !void {
        if (rows == 0) return;
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{d}A", .{rows});
        try self.stdout.writeAll(seq);
    }

    fn moveCursorToColumn(self: *Repl, col: usize) !void {
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{d}G", .{col});
        try self.stdout.writeAll(seq);
    }

    fn updateTerminalSize(self: *Repl) void {
        var winsize: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };

        const rc = std.posix.system.ioctl(self.stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (std.posix.errno(rc) == .SUCCESS and winsize.col > 0) {
            self.terminal_cols = winsize.col;
        } else {
            self.terminal_cols = DEFAULT_TERMINAL_COLS;
        }
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

    var repl = Repl.init(gpa.allocator(), agent);
    defer repl.deinit();

    try repl.run();
}

fn initTestRepl() Repl {
    var dummy_agent: Agent = undefined;
    var repl = Repl.init(std.testing.allocator, &dummy_agent);
    repl.terminal_cols = 10;
    repl.rendered_rows = 1;
    repl.rendered_cursor_row = 0;
    return repl;
}

fn setTestLine(repl: *Repl, line: []const u8, cursor_pos: usize) void {
    @memcpy(repl.line_buf[0..line.len], line);
    repl.line_len = line.len;
    repl.cursor_pos = cursor_pos;
}

test "repl display columns account for prompt and chinese width" {
    var repl = initTestRepl();
    setTestLine(&repl, "ab你", "ab".len);

    try std.testing.expectEqual(@as(usize, PROMPT.len + 2), repl.getDisplayColumns("ab".len));
    try std.testing.expectEqual(@as(usize, PROMPT.len + 4), repl.getDisplayColumns(repl.line_len));
}

test "repl rendered rows wrap on display columns instead of utf8 bytes" {
    var repl = initTestRepl();
    repl.terminal_cols = 6;
    setTestLine(&repl, "你好", "你好".len);

    try std.testing.expectEqual(@as(usize, 1), repl.getRenderedRows("你".len));
    try std.testing.expectEqual(@as(usize, 1), repl.getRenderedRows(repl.line_len));

    setTestLine(&repl, "你好a", "你好a".len);
    try std.testing.expectEqual(@as(usize, 2), repl.getRenderedRows(repl.line_len));
}

test "repl cursor position points at next character and line end stays at trailing cell" {
    var repl = initTestRepl();
    setTestLine(&repl, "abc", 1);

    const middle_cursor = repl.getCursorPosition();
    try std.testing.expectEqual(@as(usize, 0), middle_cursor.row);
    try std.testing.expectEqual(@as(usize, 4), middle_cursor.col);

    repl.cursor_pos = repl.line_len;
    const end_cursor = repl.getCursorPosition();
    const end_position = repl.getScreenPosition(repl.line_len);
    try std.testing.expectEqual(end_position.row, end_cursor.row);
    try std.testing.expectEqual(end_position.col, end_cursor.col);
}

test "repl cursor and screen position stay stable around wrapped chinese boundary" {
    var repl = initTestRepl();
    repl.terminal_cols = 4;
    setTestLine(&repl, "你a", "你".len);

    const screen_position = repl.getScreenPosition(repl.cursor_pos);
    try std.testing.expectEqual(@as(usize, 0), screen_position.row);
    try std.testing.expectEqual(@as(usize, 4), screen_position.col);

    const cursor_position = repl.getCursorPosition();
    try std.testing.expectEqual(@as(usize, 1), cursor_position.row);
    try std.testing.expectEqual(@as(usize, 1), cursor_position.col);

    repl.cursor_pos = repl.line_len;
    const end_cursor = repl.getCursorPosition();
    try std.testing.expectEqual(@as(usize, 1), end_cursor.row);
    try std.testing.expectEqual(@as(usize, 1), end_cursor.col);
}
