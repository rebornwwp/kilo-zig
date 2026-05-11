// Kilo text editor - Zig port (Refactored to be more idiomatic Zig)
// A port of kilo.c to Zig 0.16.0
// Original C version by Salvatore Sanfilippo <antirez at gmail dot com>

const std = @import("std");
const posix = std.posix;

// Constants
const KILO_VERSION = "0.0.1";
const KILO_QUERY_LEN = 256;
const KILO_QUIT_TIMES = 3;
const KILO_TAB_STOP = 8;
const SEPARATOR_CHARS = ",.()+-/*=~%[];";
const STATUS_BUF_SIZE = 80;

// VMIN and VTIME indices into termios cc array (macOS/BSD values)
const VMIN_IDX: usize = 16;
const VTIME_IDX: usize = 17;

// Highlight flags
const HL_HIGHLIGHT_STRINGS: u32 = 1 << 0;
const HL_HIGHLIGHT_NUMBERS: u32 = 1 << 1;

// Syntax highlight types
pub const Highlight = enum(u8) {
    normal,
    nonprint,
    comment,
    mlcomment,
    keyword1,
    keyword2,
    string,
    number,
    match,

    pub fn toColor(self: Highlight) u8 {
        return switch (self) {
            .comment, .mlcomment => 36, // cyan
            .keyword1 => 33, // yellow
            .keyword2 => 32, // green
            .string => 35, // magenta
            .number => 31, // red
            .match => 34, // blue
            else => 37, // white
        };
    }
};

// Key actions for terminal input
pub const KeyAction = enum(u16) {
    null = 0,
    ctrl_c = 3,
    ctrl_d = 4,
    ctrl_f = 6,
    ctrl_h = 8,
    tab = 9,
    ctrl_l = 12,
    enter = 13,
    ctrl_q = 17,
    ctrl_s = 19,
    ctrl_u = 21,
    escape = 27,
    backspace = 127,
    arrow_left = 1000,
    arrow_right = 1001,
    arrow_up = 1002,
    arrow_down = 1003,
    del_key = 1004,
    home_key = 1005,
    end_key = 1006,
    page_up = 1007,
    page_down = 1008,
    _,

    pub fn isPrintable(self: KeyAction) bool {
        const k = @intFromEnum(self);
        return k < 128 and std.ascii.isPrint(@as(u8, @truncate(k)));
    }

    pub fn toChar(self: KeyAction) ?u8 {
        const k = @intFromEnum(self);
        if (k < 128) return @as(u8, @truncate(k));
        return null;
    }
};

// Syntax definition for highlighting
pub const SyntaxDef = struct {
    filematch: []const []const u8,
    keywords: []const []const u8,
    singleline_comment_start: []const u8,
    multiline_comment_start: []const u8,
    multiline_comment_end: []const u8,
    flags: u32,
};

// C/C++ syntax highlight database
const C_HL_EXTENSIONS = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc" };
const C_HL_KEYWORDS = [_][]const u8{
    // C Keywords
    "auto",             "break",         "case",        "continue",   "default",
    "do",               "else",          "enum",        "extern",     "for",
    "goto",             "if",            "register",    "return",     "sizeof",
    "static",           "struct",        "switch",      "typedef",    "union",
    "volatile",         "while",         "NULL",
    // C++ Keywords
           "alignas",    "alignof",
    "and",              "and_eq",        "asm",         "bitand",     "bitor",
    "class",            "compl",         "constexpr",   "const_cast", "deltype",
    "delete",           "dynamic_cast",  "explicit",    "export",     "false",
    "friend",           "inline",        "mutable",     "namespace",  "new",
    "noexcept",         "not",           "not_eq",      "nullptr",    "operator",
    "or",               "or_eq",         "private",     "protected",  "public",
    "reinterpret_cast", "static_assert", "static_cast", "template",   "this",
    "thread_local",     "throw",         "true",        "try",        "typeid",
    "typename",         "virtual",       "xor",         "xor_eq",
    // C types (with | suffix for keyword2)
        "int|",
    "long|",            "double|",       "float|",      "char|",      "unsigned|",
    "signed|",          "void|",         "short|",      "auto|",      "const|",
    "bool|",
};

const HLDB = [_]SyntaxDef{
    SyntaxDef{
        .filematch = &C_HL_EXTENSIONS,
        .keywords = &C_HL_KEYWORDS,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = HL_HIGHLIGHT_STRINGS | HL_HIGHLIGHT_NUMBERS,
    },
};

// Editor row representing a single line of text
pub const Row = struct {
    idx: usize,
    chars: std.ArrayList(u8),
    render: std.ArrayList(u8),
    hl: std.ArrayList(Highlight),
    has_open_comment: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, idx: usize) Row {
        return Row{
            .idx = idx,
            .chars = std.ArrayList(u8).empty,
            .render = std.ArrayList(u8).empty,
            .hl = std.ArrayList(Highlight).empty,
            .has_open_comment = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Row) void {
        self.chars.deinit();
        self.render.deinit();
        self.hl.deinit();
    }

    pub fn update(self: *Row, syntax: ?*const SyntaxDef) void {
        // Count tabs for expansion
        var tabs: usize = 0;
        for (self.chars.items) |ch| {
            if (ch == '\t') tabs += 1;
        }

        self.render.clearRetainingCapacity();
        self.render.ensureTotalCapacity(self.chars.items.len + tabs * 7 + 1) catch return;

        // Expand tabs to spaces
        var screen_col: usize = 0;
        for (self.chars.items) |ch| {
            if (ch == '\t') {
                while (screen_col % KILO_TAB_STOP != 0) {
                    self.render.append(' ') catch return;
                    screen_col += 1;
                }
            } else {
                self.render.append(ch) catch return;
                screen_col += 1;
            }
        }

        self.updateSyntax(syntax);
    }

    pub fn insertChar(self: *Row, at: usize, ch: u8) void {
        const size = self.chars.items.len;
        if (at > size) {
            // Pad with spaces if inserting beyond current length
            const padlen = at - size;
            self.chars.appendNTimes(' ', padlen) catch return;
            self.chars.append(ch) catch return;
        } else {
            self.chars.insert(at, ch) catch return;
        }
    }

    pub fn deleteChar(self: *Row, at: usize) void {
        if (at >= self.chars.items.len) return;
        _ = self.chars.orderedRemove(at);
    }

    pub fn appendString(self: *Row, s: []const u8) void {
        self.chars.appendSlice(s) catch return;
    }

    pub fn hasOpenComment(self: *const Row) bool {
        const rsize = self.render.items.len;
        if (rsize == 0 or self.hl.items.len == 0) return false;
        if (self.hl.items[rsize - 1] != .mlcomment) return false;
        if (rsize < 2) return true;
        // Check if comment ends at the last two characters
        return !(self.render.items[rsize - 2] == '*' and self.render.items[rsize - 1] == '/');
    }

    fn updateSyntax(self: *Row, syntax: ?*const SyntaxDef) void {
        const rsize = self.render.items.len;

        // Resize hl to match render size
        self.hl.clearRetainingCapacity();
        self.hl.ensureTotalCapacity(rsize) catch return;
        self.hl.items.len = rsize;
        @memset(self.hl.items, .normal);

        const syn = syntax orelse return;

        var i: usize = 0;
        var prev_sep: bool = true;
        var in_string: u8 = 0;
        var in_comment: bool = false;

        // If previous line has an open comment, start with that state
        if (self.idx > 0) {
            // This will be set by the editor before calling update
            in_comment = self.has_open_comment;
        }

        while (i < rsize) {
            const ch = self.render.items[i];

            // Handle single-line comments
            if (prev_sep and syn.singleline_comment_start.len >= 2 and
                i + 1 < rsize and
                self.render.items[i] == syn.singleline_comment_start[0] and
                self.render.items[i + 1] == syn.singleline_comment_start[1])
            {
                @memset(self.hl.items[i..], .comment);
                break;
            }

            // Handle multi-line comments
            if (in_comment) {
                self.hl.items[i] = .mlcomment;
                if (syn.multiline_comment_end.len >= 2 and
                    i + 1 < rsize and
                    ch == syn.multiline_comment_end[0] and
                    self.render.items[i + 1] == syn.multiline_comment_end[1])
                {
                    self.hl.items[i + 1] = .mlcomment;
                    i += 2;
                    in_comment = false;
                    prev_sep = true;
                    continue;
                } else {
                    prev_sep = false;
                    i += 1;
                    continue;
                }
            } else if (syn.multiline_comment_start.len >= 2 and
                i + 1 < rsize and
                ch == syn.multiline_comment_start[0] and
                self.render.items[i + 1] == syn.multiline_comment_start[1])
            {
                self.hl.items[i] = .mlcomment;
                self.hl.items[i + 1] = .mlcomment;
                i += 2;
                in_comment = true;
                prev_sep = false;
                continue;
            }

            // Handle strings
            if (syn.flags & HL_HIGHLIGHT_STRINGS != 0) {
                if (in_string != 0) {
                    self.hl.items[i] = .string;
                    if (ch == '\\' and i + 1 < rsize) {
                        self.hl.items[i + 1] = .string;
                        i += 2;
                        prev_sep = false;
                        continue;
                    }
                    if (ch == in_string) in_string = 0;
                    i += 1;
                    prev_sep = false;
                    continue;
                } else if (ch == '"' or ch == '\'') {
                    in_string = ch;
                    self.hl.items[i] = .string;
                    i += 1;
                    prev_sep = false;
                    continue;
                }
            }

            // Handle non-printable chars
            if (!std.ascii.isPrint(ch)) {
                self.hl.items[i] = .nonprint;
                i += 1;
                prev_sep = false;
                continue;
            }

            // Handle numbers
            if (syn.flags & HL_HIGHLIGHT_NUMBERS != 0) {
                if ((std.ascii.isDigit(ch) and (prev_sep or (i > 0 and self.hl.items[i - 1] == .number))) or
                    (ch == '.' and i > 0 and self.hl.items[i - 1] == .number))
                {
                    self.hl.items[i] = .number;
                    i += 1;
                    prev_sep = false;
                    continue;
                }
            }

            // Handle keywords
            if (prev_sep) {
                for (syn.keywords) |kw| {
                    var klen = kw.len;
                    const kw2 = klen > 0 and kw[klen - 1] == '|';
                    if (kw2) klen -= 1;

                    if (i + klen <= rsize and
                        std.mem.eql(u8, self.render.items[i .. i + klen], kw[0..klen]) and
                        (i + klen >= rsize or isSeparator(self.render.items[i + klen])))
                    {
                        const hl_type: Highlight = if (kw2) .keyword2 else .keyword1;
                        @memset(self.hl.items[i .. i + klen], hl_type);
                        i += klen;
                        prev_sep = false;
                        break;
                    }
                }
                // If we matched a keyword, continue to next char
                // (check if any keyword was matched by seeing if i advanced)
            }

            // Regular character
            prev_sep = isSeparator(ch);
            i += 1;
        }

        // Propagate syntax change if open comment state changed
        const oc = self.hasOpenComment();
        if (self.has_open_comment != oc) {
            self.has_open_comment = oc;
        }
    }

    fn isSeparator(ch: u8) bool {
        return ch == 0 or std.ascii.isWhitespace(ch) or
            std.mem.indexOfScalar(u8, SEPARATOR_CHARS, ch) != null;
    }
};

// Editor state - encapsulates all editor configuration
pub const Editor = struct {
    allocator: std.mem.Allocator,
    cx: usize,
    cy: usize,
    rowoff: usize,
    coloff: usize,
    screenrows: usize,
    screencols: usize,
    rows: std.ArrayList(Row),
    dirty: usize,
    filename: ?[]u8,
    status_msg: [STATUS_BUF_SIZE]u8,
    status_msg_len: usize,
    status_msg_time: i64,
    syntax: ?*const SyntaxDef,
    rawmode: bool,
    orig_termios: posix.termios,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .cx = 0,
            .cy = 0,
            .rowoff = 0,
            .coloff = 0,
            .screenrows = 0,
            .screencols = 0,
            .rows = std.ArrayList(Row).empty,
            .dirty = 0,
            .filename = null,
            .status_msg = undefined,
            .status_msg_len = 0,
            .status_msg_time = 0,
            .syntax = null,
            .rawmode = false,
            .orig_termios = undefined,
            .stdin_fd = posix.STDIN_FILENO,
            .stdout_fd = posix.STDOUT_FILENO,
        };
        @memset(&editor.status_msg, 0);

        try editor.updateWindowSize();
        try editor.installSigWinChHandler();

        return editor;
    }

    pub fn deinit(self: *Editor) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();

        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
    }

    fn getWindowSize(self: *Editor) !struct { usize, usize } {
        var ws: posix.winsize = undefined;
        const ret = posix.system.ioctl(self.stdout_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (ret != 0 or ws.col == 0) {
            // ioctl failed - try cursor position query
            var orig_row: usize = 0;
            var orig_col: usize = 0;

            try self.getCursorPosition(&orig_row, &orig_col);

            // Go to right/bottom margin
            try self.writeAll("\x1b[999C\x1b[999B");

            var rows: usize = 0;
            var cols: usize = 0;
            try self.getCursorPosition(&rows, &cols);

            // Restore position
            var buf: [32]u8 = undefined;
            const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ orig_row, orig_col }) catch return error.BufferTooSmall;
            try self.writeAll(seq);

            return .{ rows, cols };
        } else {
            return .{ ws.row, ws.col };
        }
    }

    fn getCursorPosition(self: *Editor, rows: *usize, cols: *usize) !void {
        // Report cursor location
        try self.writeAll("\x1b[6n");

        // Read the response: ESC [ rows ; cols R
        var buf: [32]u8 = undefined;
        var i: usize = 0;

        while (i < buf.len - 1) {
            const n = posix.read(self.stdin_fd, buf[i .. i + 1]) catch break;
            if (n != 1) break;
            if (buf[i] == 'R') break;
            i += 1;
        }

        // Parse it
        if (i < 2 or buf[0] != 0x1b or buf[1] != '[') {
            return error.ParseError;
        }

        const response = buf[2..i];
        const semi = std.mem.indexOfScalar(u8, response, ';') orelse return error.ParseError;
        rows.* = try std.fmt.parseInt(usize, response[0..semi], 10);
        cols.* = try std.fmt.parseInt(usize, response[semi + 1 ..], 10);
    }

    fn writeAll(self: *Editor, data: []const u8) !void {
        var pos: usize = 0;
        while (pos < data.len) {
            const n = posix.system.write(self.stdout_fd, data.ptr + pos, data.len - pos);
            if (n < 0) {
                return switch (posix.errno(n)) {
                    .INTR => continue,
                    else => error.WriteFailed,
                };
            }
            pos += @as(usize, @intCast(n));
        }
    }

    fn updateWindowSize(self: *Editor) !void {
        const size = try self.getWindowSize();
        self.screenrows = size[0];
        self.screencols = size[1];
        if (self.screenrows >= 2) self.screenrows -= 2; // Room for status bar
    }

    fn installSigWinChHandler(self: *Editor) !void {
        _ = self; // Signal handlers are global, can't use self
        // Note: In a real implementation, we'd need a global reference to the editor
        // or use a different approach for handling SIGWINCH
    }

    fn enableRawMode(self: *Editor) !void {
        if (self.rawmode) return;

        if (posix.isatty(self.stdin_fd) == 0) {
            return error.NotATty;
        }

        self.orig_termios = try posix.tcgetattr(self.stdin_fd);

        var raw = self.orig_termios;

        // Input modes: no break, no CR to NL, no parity check, no strip char,
        // no start/stop output control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output modes - disable post processing
        raw.oflag.OPOST = false;

        // Control modes - set 8 bit chars
        raw.cflag.CSIZE = .CS8;

        // Local modes - echoing off, canonical off, no extended functions,
        // no signal chars (^Z,^C)
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control chars - set return condition: min number of bytes and timer
        raw.cc[VMIN_IDX] = 0; // Return each byte, or zero for timeout
        raw.cc[VTIME_IDX] = 1; // 100 ms timeout (unit is tens of second)

        try posix.tcsetattr(self.stdin_fd, .FLUSH, raw);
        self.rawmode = true;
    }

    fn disableRawMode(self: *Editor) void {
        if (self.rawmode) {
            posix.tcsetattr(self.stdin_fd, .FLUSH, self.orig_termios) catch {};
            self.rawmode = false;
        }
    }

    fn readKey(self: *Editor) KeyAction {
        var buf: [1]u8 = undefined;

        // Wait for a byte
        while (true) {
            const nread = posix.read(self.stdin_fd, &buf) catch {
                std.process.exit(1);
            };
            if (nread == 1) break;
            // nread == 0 means timeout, keep trying
        }

        const c_byte = buf[0];

        // 27 is the ASCII code for ESC (escape key)
        if (c_byte == 27) {
            var seq: [3]u8 = undefined;

            // Try to read more of escape sequence
            const n1 = posix.read(self.stdin_fd, seq[0..1]) catch return .escape;
            if (n1 == 0) return .escape;

            const n2 = posix.read(self.stdin_fd, seq[1..2]) catch return .escape;
            if (n2 == 0) return .escape;

            // ESC [ sequences
            if (seq[0] == '[') {
                if (seq[1] >= '0' and seq[1] <= '9') {
                    // Extended escape, read additional byte
                    const n3 = posix.read(self.stdin_fd, seq[2..3]) catch return .escape;
                    if (n3 == 0) return .escape;
                    if (seq[2] == '~') {
                        switch (seq[1]) {
                            '3' => return .del_key,
                            '5' => return .page_up,
                            '6' => return .page_down,
                            else => {},
                        }
                    }
                } else {
                    switch (seq[1]) {
                        'A' => return .arrow_up,
                        'B' => return .arrow_down,
                        'C' => return .arrow_right,
                        'D' => return .arrow_left,
                        'H' => return .home_key,
                        'F' => return .end_key,
                        else => {},
                    }
                }
            }
            // ESC O sequences
            else if (seq[0] == 'O') {
                switch (seq[1]) {
                    'H' => return .home_key,
                    'F' => return .end_key,
                    else => {},
                }
            }

            return .escape;
        }

        return @enumFromInt(c_byte);
    }

    fn getTimestamp() i64 {
        var ts: posix.timespec = undefined;
        posix.clock_gettime(posix.CLOCK.REALTIME, &ts) catch return 0;
        return ts.sec;
    }

    fn selectSyntaxHighlight(self: *Editor, filename: []const u8) void {
        self.syntax = null;
        for (&HLDB) |*s| {
            for (s.filematch) |pat| {
                if (std.mem.indexOf(u8, filename, pat)) |pos| {
                    if (pat[0] != '.' or pos + pat.len == filename.len) {
                        self.syntax = s;
                        return;
                    }
                }
            }
        }
    }

    fn insertRow(self: *Editor, at: usize, s: []const u8) void {
        if (at > self.rows.items.len) return;

        var new_row = Row.init(self.allocator, at);
        new_row.chars.appendSlice(s) catch return;
        new_row.update(self.syntax);

        self.rows.insert(at, new_row) catch return;

        // Update idx for rows after 'at'
        var j: usize = at + 1;
        while (j < self.rows.items.len) : (j += 1) {
            self.rows.items[j].idx = j;
        }

        self.dirty += 1;
    }

    fn deleteRow(self: *Editor, at: usize) void {
        if (at >= self.rows.items.len) return;

        self.rows.items[at].deinit();
        _ = self.rows.orderedRemove(at);

        // Update idx for rows from 'at' onwards
        var j: usize = at;
        while (j < self.rows.items.len) : (j += 1) {
            self.rows.items[j].idx = j;
        }

        self.dirty += 1;
    }

    fn open(self: *Editor, filename: []const u8, io: std.Io) !void {
        self.dirty = 0;

        // Store filename
        if (self.filename) |old| {
            self.allocator.free(old);
        }
        self.filename = try self.allocator.dupe(u8, filename);

        // Read file content
        const content = std.Io.Dir.cwd().readFileAlloc(io, filename, self.allocator, .unlimited) catch |err| {
            if (err == error.FileNotFound) {
                // New file - no error, just empty
                return;
            }
            return err;
        };
        defer self.allocator.free(content);

        // Split by lines
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            // Strip trailing \r
            var ln = line;
            if (ln.len > 0 and ln[ln.len - 1] == '\r') {
                ln = ln[0 .. ln.len - 1];
            }
            self.insertRow(self.rows.items.len, ln);
        }

        // Remove last empty row if file ends with newline
        if (self.rows.items.len > 1) {
            const last_idx = self.rows.items.len - 1;
            const last = &self.rows.items[last_idx];
            if (last.chars.items.len == 0) {
                self.deleteRow(last_idx);
            }
        }

        self.dirty = 0;
    }

    fn save(self: *Editor, io: std.Io) void {
        const filename = self.filename orelse {
            self.setStatusMessage("No filename");
            return;
        };

        // Build file content
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit();

        for (self.rows.items) |row| {
            buf.appendSlice(row.chars.items) catch {
                self.setStatusMessage("Can't save! Memory error");
                return;
            };
            buf.append('\n') catch {
                self.setStatusMessage("Can't save! Memory error");
                return;
            };
        }

        // Write to file
        const file = std.Io.Dir.cwd().createFile(io, filename, .{ .truncate = true }) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "Can't save! I/O error: {s}", .{@errorName(err)}) catch "Can't save!";
            self.setStatusMessage(msg);
            return;
        };
        defer file.close();

        file.writeAll(buf.items) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "Can't save! I/O error: {s}", .{@errorName(err)}) catch "Can't save!";
            self.setStatusMessage(msg);
            return;
        };

        self.dirty = 0;
        var msgbuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msgbuf, "{d} bytes written on disk", .{buf.items.len}) catch "Saved";
        self.setStatusMessage(msg);
    }

    fn rowsToString(self: *Editor) ![]u8 {
        var totlen: usize = 0;
        for (self.rows.items) |row| {
            totlen += row.chars.items.len + 1; // +1 for newline
        }

        var buf = try self.allocator.alloc(u8, totlen);
        var pos: usize = 0;
        for (self.rows.items) |row| {
            @memcpy(buf[pos .. pos + row.chars.items.len], row.chars.items);
            pos += row.chars.items.len;
            buf[pos] = '\n';
            pos += 1;
        }
        return buf;
    }

    fn insertChar(self: *Editor, ch: u8) void {
        const filerow = self.rowoff + self.cy;
        const filecol = self.coloff + self.cx;

        // If the row doesn't exist, add empty rows
        while (self.rows.items.len <= filerow) {
            self.insertRow(self.rows.items.len, "");
        }

        const row = &self.rows.items[filerow];
        row.insertChar(filecol, ch);
        row.update(self.syntax);

        if (self.cx == self.screencols - 1) {
            self.coloff += 1;
        } else {
            self.cx += 1;
        }
        self.dirty += 1;
    }

    fn insertNewline(self: *Editor) void {
        const filerow = self.rowoff + self.cy;
        var filecol = self.coloff + self.cx;

        if (filerow >= self.rows.items.len) {
            if (filerow == self.rows.items.len) {
                self.insertRow(filerow, "");
                self.fixCursorAfterNewline();
            }
            return;
        }

        const row = &self.rows.items[filerow];
        if (filecol >= row.chars.items.len) filecol = row.chars.items.len;

        if (filecol == 0) {
            self.insertRow(filerow, "");
        } else {
            // Split row at filecol
            const rest = row.chars.items[filecol..];
            self.insertRow(filerow + 1, rest);
            // Truncate current row
            const cur_row = &self.rows.items[filerow];
            cur_row.chars.items.len = filecol;
            cur_row.update(self.syntax);
        }

        self.fixCursorAfterNewline();
    }

    fn fixCursorAfterNewline(self: *Editor) void {
        if (self.cy == self.screenrows - 1) {
            self.rowoff += 1;
        } else {
            self.cy += 1;
        }
        self.cx = 0;
        self.coloff = 0;
    }

    fn deleteChar(self: *Editor) void {
        const filerow = self.rowoff + self.cy;
        const filecol = self.coloff + self.cx;

        if (filerow >= self.rows.items.len) return;
        if (filecol == 0 and filerow == 0) return;

        const row = &self.rows.items[filerow];

        if (filecol == 0) {
            // Handle column 0: merge with previous row
            const prev_row = &self.rows.items[filerow - 1];
            const prev_size = prev_row.chars.items.len;
            prev_row.appendString(row.chars.items);
            prev_row.update(self.syntax);
            self.deleteRow(filerow);

            if (self.cy == 0) {
                if (self.rowoff > 0) self.rowoff -= 1;
            } else {
                self.cy -= 1;
            }
            self.cx = prev_size;
            if (self.cx >= self.screencols) {
                self.coloff = self.cx - self.screencols + 1;
                self.cx = self.screencols - 1;
            }
        } else {
            row.deleteChar(filecol - 1);
            row.update(self.syntax);
            if (self.cx == 0 and self.coloff > 0) {
                self.coloff -= 1;
            } else if (self.cx > 0) {
                self.cx -= 1;
            }
        }
        self.dirty += 1;
    }

    fn moveCursor(self: *Editor, key: KeyAction) void {
        const filerow = self.rowoff + self.cy;
        const filecol = self.coloff + self.cx;
        const row = if (filerow < self.rows.items.len) &self.rows.items[filerow] else null;

        switch (key) {
            .arrow_left => {
                if (self.cx == 0) {
                    if (self.coloff > 0) {
                        self.coloff -= 1;
                    } else if (filerow > 0) {
                        self.cy -= 1;
                        const prev_row = &self.rows.items[filerow - 1];
                        self.cx = prev_row.chars.items.len;
                        if (self.cx > self.screencols - 1) {
                            self.coloff = self.cx - self.screencols + 1;
                            self.cx = self.screencols - 1;
                        }
                    }
                } else {
                    self.cx -= 1;
                }
            },
            .arrow_right => {
                if (row) |r| {
                    if (filecol < r.chars.items.len) {
                        if (self.cx == self.screencols - 1) {
                            self.coloff += 1;
                        } else {
                            self.cx += 1;
                        }
                    } else if (filecol == r.chars.items.len) {
                        self.cx = 0;
                        self.coloff = 0;
                        if (self.cy == self.screenrows - 1) {
                            self.rowoff += 1;
                        } else {
                            self.cy += 1;
                        }
                    }
                }
            },
            .arrow_up => {
                if (self.cy == 0) {
                    if (self.rowoff > 0) self.rowoff -= 1;
                } else {
                    self.cy -= 1;
                }
            },
            .arrow_down => {
                if (filerow < self.rows.items.len) {
                    if (self.cy == self.screenrows - 1) {
                        self.rowoff += 1;
                    } else {
                        self.cy += 1;
                    }
                }
            },
            else => {},
        }

        // Fix cx if the current line has not enough chars
        const new_filerow = self.rowoff + self.cy;
        const new_filecol = self.coloff + self.cx;
        const new_row = if (new_filerow < self.rows.items.len) &self.rows.items[new_filerow] else null;
        const rowlen: usize = if (new_row) |r| r.chars.items.len else 0;
        if (new_filecol > rowlen) {
            const excess = new_filecol - rowlen;
            if (self.cx >= excess) {
                self.cx -= excess;
            } else {
                self.coloff -= excess - self.cx;
                self.cx = 0;
            }
        }
    }

    fn refreshScreen(self: *Editor) void {
        var ab = std.ArrayList(u8).empty;
        defer ab.deinit();

        // Hide cursor
        ab.appendSlice("\x1b[?25l") catch return;
        // Go home
        ab.appendSlice("\x1b[H") catch return;

        // Render rows
        var y: usize = 0;
        while (y < self.screenrows) : (y += 1) {
            const filerow = self.rowoff + y;

            if (filerow >= self.rows.items.len) {
                if (self.rows.items.len == 0 and y == self.screenrows / 3) {
                    var welcome: [80]u8 = undefined;
                    const welcome_str = std.fmt.bufPrint(&welcome, "Kilo editor -- version {s}\x1b[0K\r\n", .{KILO_VERSION}) catch "Kilo\r\n";
                    const padding = if (self.screencols > welcome_str.len) (self.screencols - welcome_str.len) / 2 else 0;
                    if (padding > 0) {
                        ab.append('~') catch return;
                        var p: usize = 1;
                        while (p < padding) : (p += 1) {
                            ab.append(' ') catch return;
                        }
                    }
                    ab.appendSlice(welcome_str) catch return;
                } else {
                    ab.appendSlice("~\x1b[0K\r\n") catch return;
                }
                continue;
            }

            const r = &self.rows.items[filerow];
            const rlen = r.render.items.len;
            const len: usize = if (rlen > self.coloff) blk: {
                const visible = rlen - self.coloff;
                break :blk if (visible > self.screencols) self.screencols else visible;
            } else 0;

            var current_color: u8 = 37; // white

            if (len > 0) {
                const render_slice = r.render.items[self.coloff .. self.coloff + len];
                const hl_slice = if (r.hl.items.len > self.coloff)
                    r.hl.items[self.coloff..@min(self.coloff + len, r.hl.items.len)]
                else
                    &[_]Highlight{};

                for (render_slice, 0..) |ch, j| {
                    const hl: Highlight = if (j < hl_slice.len) hl_slice[j] else .normal;

                    if (hl == .nonprint) {
                        ab.appendSlice("\x1b[7m") catch return;
                        const sym: u8 = if (ch <= 26) '@' + ch else '?';
                        ab.append(sym) catch return;
                        ab.appendSlice("\x1b[0m") catch return;
                        current_color = 37;
                    } else if (hl == .normal) {
                        if (current_color != 37) {
                            ab.appendSlice("\x1b[39m") catch return;
                            current_color = 37;
                        }
                        ab.append(ch) catch return;
                    } else {
                        const color = hl.toColor();
                        if (color != current_color) {
                            var cbuf: [16]u8 = undefined;
                            const cseq = std.fmt.bufPrint(&cbuf, "\x1b[{d}m", .{color}) catch "\x1b[37m";
                            ab.appendSlice(cseq) catch return;
                            current_color = color;
                        }
                        ab.append(ch) catch return;
                    }
                }
            }

            ab.appendSlice("\x1b[39m") catch return;
            ab.appendSlice("\x1b[0K") catch return;
            ab.appendSlice("\r\n") catch return;
        }

        // Status bar
        ab.appendSlice("\x1b[0K") catch return;
        ab.appendSlice("\x1b[7m") catch return;

        var status: [STATUS_BUF_SIZE]u8 = undefined;
        const fname = self.filename orelse "[No Name]";
        const fname_trunc = if (fname.len > 20) fname[0..20] else fname;
        const status_str = std.fmt.bufPrint(&status, "{s} - {d} lines {s}", .{
            fname_trunc,
            self.rows.items.len,
            if (self.dirty > 0) "(modified)" else "",
        }) catch "status error";
        var slen = status_str.len;
        if (slen > self.screencols) slen = self.screencols;

        var rstatus: [STATUS_BUF_SIZE]u8 = undefined;
        const rstatus_str = std.fmt.bufPrint(&rstatus, "{d}/{d}", .{
            self.rowoff + self.cy + 1,
            self.rows.items.len,
        }) catch "?/?";
        const rlen = rstatus_str.len;

        ab.appendSlice(status_str[0..slen]) catch return;

        var len: usize = slen;
        while (len < self.screencols) : (len += 1) {
            if (self.screencols - len == rlen) {
                ab.appendSlice(rstatus_str) catch return;
                break;
            } else {
                ab.append(' ') catch return;
            }
        }

        ab.appendSlice("\x1b[0m\r\n") catch return;

        // Message bar
        ab.appendSlice("\x1b[0K") catch return;
        const msglen = self.status_msg_len;
        if (msglen > 0 and Editor.getTimestamp() - self.status_msg_time < 5) {
            const show_len = if (msglen <= self.screencols) msglen else self.screencols;
            ab.appendSlice(self.status_msg[0..show_len]) catch return;
        }

        // Position cursor
        const filerow = self.rowoff + self.cy;
        const row = if (filerow < self.rows.items.len) &self.rows.items[filerow] else null;
        var cx: usize = 1;
        if (row) |r| {
            var j: usize = self.coloff;
            while (j < self.cx + self.coloff) : (j += 1) {
                if (j < r.chars.items.len and r.chars.items[j] == '\t') {
                    cx += 7 - (cx % 8);
                }
                cx += 1;
            }
        }

        var posbuf: [32]u8 = undefined;
        const posseq = std.fmt.bufPrint(&posbuf, "\x1b[{d};{d}H", .{ self.cy + 1, cx }) catch "\x1b[1;1H";
        ab.appendSlice(posseq) catch return;

        // Show cursor
        ab.appendSlice("\x1b[?25h") catch return;

        // Write to screen
        self.writeAll(ab.items) catch {};
    }

    fn setStatusMessage(self: *Editor, msg: []const u8) void {
        const len = if (msg.len < self.status_msg.len) msg.len else self.status_msg.len;
        @memcpy(self.status_msg[0..len], msg[0..len]);
        self.status_msg_len = len;
        self.status_msg_time = Editor.getTimestamp();
    }

    fn find(self: *Editor) void {
        var query: [KILO_QUERY_LEN + 1]u8 = @splat(0);
        var qlen: usize = 0;
        var last_match: i64 = -1;
        var find_next: i32 = 0;

        var saved_hl_line: i64 = -1;
        var saved_hl: ?[]Highlight = null;

        const saved_cx = self.cx;
        const saved_cy = self.cy;
        const saved_coloff = self.coloff;
        const saved_rowoff = self.rowoff;

        defer {
            // Restore saved highlight
            if (saved_hl) |hl| {
                if (saved_hl_line >= 0 and @as(usize, @intCast(saved_hl_line)) < self.rows.items.len) {
                    const row = &self.rows.items[@intCast(saved_hl_line)];
                    const copy_len = if (hl.len < row.hl.items.len) hl.len else row.hl.items.len;
                    @memcpy(row.hl.items[0..copy_len], hl[0..copy_len]);
                }
                self.allocator.free(hl);
            }
        }

        while (true) {
            var msgbuf: [STATUS_BUF_SIZE]u8 = undefined;
            const msg = std.fmt.bufPrint(&msgbuf, "Search: {s} (Use ESC/Arrows/Enter)", .{query[0..qlen]}) catch "Search:";
            self.setStatusMessage(msg);
            self.refreshScreen();

            const key = self.readKey();

            if (key == .del_key or key == .ctrl_h or key == .backspace) {
                if (qlen > 0) {
                    qlen -= 1;
                    query[qlen] = 0;
                }
                last_match = -1;
            } else if (key == .escape or key == .enter) {
                if (key == .escape) {
                    self.cx = saved_cx;
                    self.cy = saved_cy;
                    self.coloff = saved_coloff;
                    self.rowoff = saved_rowoff;
                }
                self.setStatusMessage("");
                return;
            } else if (key == .arrow_right or key == .arrow_down) {
                find_next = 1;
            } else if (key == .arrow_left or key == .arrow_up) {
                find_next = -1;
            } else {
                if (key.isPrintable()) {
                    if (qlen < KILO_QUERY_LEN) {
                        if (key.toChar()) |ch| {
                            query[qlen] = ch;
                            qlen += 1;
                            query[qlen] = 0;
                            last_match = -1;
                        }
                    }
                }
            }

            // Search occurrence
            if (last_match == -1) find_next = 1;
            if (find_next != 0) {
                var current: i64 = last_match;
                var matched_row: ?usize = null;
                var match_offset: usize = 0;

                var i: usize = 0;
                while (i < self.rows.items.len) : (i += 1) {
                    current += find_next;
                    if (current < 0) current = @intCast(self.rows.items.len - 1);
                    if (@as(usize, @intCast(current)) >= self.rows.items.len) current = 0;

                    const row = &self.rows.items[@intCast(current)];
                    const q = query[0..qlen];
                    if (std.mem.indexOf(u8, row.render.items, q)) |offset| {
                        matched_row = @intCast(current);
                        match_offset = offset;
                        break;
                    }
                }
                find_next = 0;

                // Restore previous highlight
                if (saved_hl) |hl| {
                    if (saved_hl_line >= 0 and @as(usize, @intCast(saved_hl_line)) < self.rows.items.len) {
                        const prev = &self.rows.items[@intCast(saved_hl_line)];
                        const copy_len = if (hl.len < prev.hl.items.len) hl.len else prev.hl.items.len;
                        @memcpy(prev.hl.items[0..copy_len], hl[0..copy_len]);
                    }
                    self.allocator.free(hl);
                    saved_hl = null;
                }

                if (matched_row) |row_idx| {
                    last_match = @intCast(row_idx);
                    const row = &self.rows.items[row_idx];

                    // Save and apply match highlight
                    if (row.hl.items.len > 0) {
                        saved_hl_line = @intCast(row_idx);
                        saved_hl = self.allocator.dupe(Highlight, row.hl.items) catch null;
                        const end = @min(match_offset + qlen, row.hl.items.len);
                        @memset(row.hl.items[match_offset..end], .match);
                    }

                    self.cy = 0;
                    self.cx = match_offset;
                    self.rowoff = row_idx;
                    self.coloff = 0;
                    if (self.cx >= self.screencols) {
                        const diff = self.cx - self.screencols + 1;
                        self.cx -= diff;
                        self.coloff += diff;
                    }
                }
            }
        }
    }

    fn processKeypress(self: *Editor, quit_times: *usize, io: std.Io) void {
        const key = self.readKey();

        switch (key) {
            .enter => self.insertNewline(),
            .ctrl_c => {}, // Ignore Ctrl-C
            .ctrl_q => {
                if (self.dirty > 0 and quit_times.* > 0) {
                    var buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{quit_times.*}) catch "WARNING! Unsaved changes.";
                    self.setStatusMessage(msg);
                    quit_times.* -= 1;
                    return;
                }
                self.disableRawMode();
                std.process.exit(0);
            },
            .ctrl_s => self.save(io),
            .ctrl_f => self.find(),
            .backspace, .ctrl_h, .del_key => {
                if (key == .del_key) {
                    self.moveCursor(.arrow_right);
                }
                self.deleteChar();
            },
            .page_up, .page_down => {
                if (key == .page_up and self.cy != 0) {
                    self.cy = 0;
                } else if (key == .page_down and self.cy != self.screenrows - 1) {
                    self.cy = self.screenrows - 1;
                }
                for (0..self.screenrows) |_| {
                    self.moveCursor(if (key == .page_up) .arrow_up else .arrow_down);
                }
            },
            .arrow_up, .arrow_down, .arrow_left, .arrow_right => {
                self.moveCursor(key);
            },
            .ctrl_l, .escape => {}, // Nothing to do
            else => {
                if (key.isPrintable()) {
                    if (key.toChar()) |ch| {
                        self.insertChar(ch);
                    }
                }
            },
        }

        quit_times.* = KILO_QUIT_TIMES;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "Usage: kilo <filename>\n");
        std.process.exit(1);
    }

    const filename = args[1];

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    editor.selectSyntaxHighlight(filename);
    try editor.open(filename, init.io);

    try editor.enableRawMode();
    defer editor.disableRawMode();

    editor.setStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find");

    var quit_times: usize = KILO_QUIT_TIMES;

    while (true) {
        editor.refreshScreen();
        editor.processKeypress(&quit_times, init.io);
    }
}
