// Kilo text editor - Zig port
// A port of kilo.c to Zig 0.15.2
// Original C version by Salvatore Sanfilippo <antirez at gmail dot com>

const std = @import("std");
const posix = std.posix;
const c = std.c;

const KILO_VERSION = "0.0.1";
const KILO_QUERY_LEN = 256;
const KILO_QUIT_TIMES = 3;

// Tab stop size
const KILO_TAB_STOP = 8;

// VMIN and VTIME indices into termios cc array (macOS/BSD values)
const VMIN: usize = 16;
const VTIME: usize = 17;

// HL flags
const HL_HIGHLIGHT_STRINGS: u32 = 1 << 0;
const HL_HIGHLIGHT_NUMBERS: u32 = 1 << 1;

const allocator = std.heap.page_allocator;

// Syntax highlight types
const Highlight = enum(u8) {
    normal = 0,
    nonprint = 1,
    comment = 2,
    mlcomment = 3,
    keyword1 = 4,
    keyword2 = 5,
    string = 6,
    number = 7,
    match = 8,
};

const EditorSyntax = struct {
    filematch: []const []const u8,
    keywords: []const []const u8,
    singleline_comment_start: []const u8,
    multiline_comment_start: []const u8,
    multiline_comment_end: []const u8,
    flags: u32,
};

const EditorRow = struct {
    idx: usize,
    chars: std.ArrayList(u8),
    render: std.ArrayList(u8),
    hl: std.ArrayList(Highlight),
    hl_oc: bool,
};

const KeyAction = enum(u16) {
    key_null = 0,
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
    esc = 27,
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
};

// C / C++ syntax highlight database
const C_HL_extensions = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc" };
const C_HL_keywords = [_][]const u8{
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

const HLDB = [_]EditorSyntax{
    EditorSyntax{
        .filematch = &C_HL_extensions,
        .keywords = &C_HL_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = HL_HIGHLIGHT_STRINGS | HL_HIGHLIGHT_NUMBERS,
    },
};

// Editor state
const EditorConfig = struct {
    cx: usize,
    cy: usize,
    rowoff: usize,
    coloff: usize,
    screenrows: usize,
    screencols: usize,
    rows: std.ArrayList(EditorRow),
    dirty: usize,
    filename: ?[]u8,
    statusmsg: [80]u8,
    statusmsg_len: usize,
    statusmsg_time: i64,
    syntax: ?*const EditorSyntax,
    rawmode: bool,
    orig_termios: posix.termios,
};

var E: EditorConfig = undefined;

// ======================= Low level terminal handling =======================

fn disableRawMode() void {
    if (E.rawmode) {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, E.orig_termios) catch {};
        E.rawmode = false;
    }
}

fn enableRawMode() !void {
    if (E.rawmode) return;

    if (!posix.isatty(posix.STDIN_FILENO)) {
        return error.NotATty;
    }

    E.orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);

    var raw = E.orig_termios;

    // input modes: no break, no CR to NL, no parity check, no strip char,
    // no start/stop output control.
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    // output modes - disable post processing
    raw.oflag.OPOST = false;

    // control modes - set 8 bit chars
    raw.cflag.CSIZE = .CS8;

    // local modes - echo off, canonical off, no extended functions,
    // no signal chars
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    // control chars - set return condition: min number of bytes and timer
    raw.cc[VMIN] = 0; // Return each byte, or zero for timeout
    raw.cc[VTIME] = 1; // 100 ms timeout (unit is tens of second)

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    E.rawmode = true;
}

// Read a key from the terminal put in raw mode, trying to handle escape sequences.
fn editorReadKey() u16 {
    var buf: [1]u8 = undefined;

    // Wait for a byte
    while (true) {
        const nread = posix.read(posix.STDIN_FILENO, &buf) catch {
            std.process.exit(1);
        };
        if (nread == 1) break;
        // nread == 0 means timeout, keep trying
    }

    const c_byte = buf[0];

    if (c_byte == @intFromEnum(KeyAction.esc)) {
        var seq: [3]u8 = undefined;

        // Try to read more of escape sequence
        const n1 = posix.read(posix.STDIN_FILENO, seq[0..1]) catch return @intFromEnum(KeyAction.esc);
        if (n1 == 0) return @intFromEnum(KeyAction.esc);

        const n2 = posix.read(posix.STDIN_FILENO, seq[1..2]) catch return @intFromEnum(KeyAction.esc);
        if (n2 == 0) return @intFromEnum(KeyAction.esc);

        // ESC [ sequences
        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                // Extended escape, read additional byte
                const n3 = posix.read(posix.STDIN_FILENO, seq[2..3]) catch return @intFromEnum(KeyAction.esc);
                if (n3 == 0) return @intFromEnum(KeyAction.esc);
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '3' => return @intFromEnum(KeyAction.del_key),
                        '5' => return @intFromEnum(KeyAction.page_up),
                        '6' => return @intFromEnum(KeyAction.page_down),
                        else => {},
                    }
                }
            } else {
                switch (seq[1]) {
                    'A' => return @intFromEnum(KeyAction.arrow_up),
                    'B' => return @intFromEnum(KeyAction.arrow_down),
                    'C' => return @intFromEnum(KeyAction.arrow_right),
                    'D' => return @intFromEnum(KeyAction.arrow_left),
                    'H' => return @intFromEnum(KeyAction.home_key),
                    'F' => return @intFromEnum(KeyAction.end_key),
                    else => {},
                }
            }
        }
        // ESC O sequences
        else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return @intFromEnum(KeyAction.home_key),
                'F' => return @intFromEnum(KeyAction.end_key),
                else => {},
            }
        }

        return @intFromEnum(KeyAction.esc);
    }

    return @as(u16, c_byte);
}

// Get cursor position using ESC [6n
fn getCursorPosition(rows: *usize, cols: *usize) !void {
    // Report cursor location
    _ = try posix.write(posix.STDOUT_FILENO, "\x1b[6n");

    // Read the response: ESC [ rows ; cols R
    var buf: [32]u8 = undefined;
    var i: usize = 0;

    while (i < buf.len - 1) {
        const n = posix.read(posix.STDIN_FILENO, buf[i .. i + 1]) catch break;
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

// Get window size via ioctl, with fallback cursor-probe method
fn getWindowSize(rows: *usize, cols: *usize) !void {
    var ws: posix.winsize = undefined;
    const ret = c.ioctl(1, @intCast(c.T.IOCGWINSZ), &ws);
    if (ret == -1 or ws.col == 0) {
        // ioctl failed - query the terminal itself
        var orig_row: usize = 0;
        var orig_col: usize = 0;

        try getCursorPosition(&orig_row, &orig_col);

        // Go to right/bottom margin
        _ = try posix.write(posix.STDOUT_FILENO, "\x1b[999C\x1b[999B");

        try getCursorPosition(rows, cols);

        // Restore position
        var seq_buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&seq_buf, "\x1b[{d};{d}H", .{ orig_row, orig_col }) catch return;
        _ = posix.write(posix.STDOUT_FILENO, seq) catch {};
    } else {
        cols.* = ws.col;
        rows.* = ws.row;
    }
}

// ====================== Syntax highlight color scheme ====================

fn isSeparator(ch: u8) bool {
    return ch == 0 or std.ascii.isWhitespace(ch) or
        std.mem.indexOfScalar(u8, ",.()+-/*=~%[];", ch) != null;
}

fn editorRowHasOpenComment(row: *const EditorRow) bool {
    const rsize = row.render.items.len;
    if (rsize == 0) return false;
    if (row.hl.items.len == 0) return false;
    const last_hl = row.hl.items[rsize - 1];
    if (last_hl != .mlcomment) return false;
    if (rsize < 2) return true;
    if (row.render.items[rsize - 2] == '*' and row.render.items[rsize - 1] == '/') return false;
    return true;
}

fn editorUpdateSyntax(row: *EditorRow) void {
    const rsize = row.render.items.len;

    // Resize hl to match render size
    row.hl.items.len = 0;
    row.hl.ensureTotalCapacity(allocator, rsize) catch return;
    row.hl.items.len = rsize;
    @memset(row.hl.items, .normal);

    const syntax = E.syntax orelse return;

    const scs = syntax.singleline_comment_start;
    const mcs = syntax.multiline_comment_start;
    const mce = syntax.multiline_comment_end;
    const keywords = syntax.keywords;
    const flags = syntax.flags;

    var i: usize = 0;
    // Skip leading whitespace
    while (i < rsize and std.ascii.isWhitespace(row.render.items[i])) {
        i += 1;
    }

    var prev_sep: bool = true;
    var in_string: u8 = 0; // 0 = not in string, otherwise the quote char
    var in_comment: bool = false;

    // If the previous line has an open comment, start with open comment state
    if (row.idx > 0 and row.idx <= E.rows.items.len) {
        const prev_row = &E.rows.items[row.idx - 1];
        if (editorRowHasOpenComment(prev_row)) {
            in_comment = true;
        }
    }

    // Reset i to 0 for the main loop
    i = 0;

    while (i < rsize) {
        const ch = row.render.items[i];

        // Handle // comments
        if (prev_sep and scs.len >= 2 and
            i + 1 < rsize and
            ch == scs[0] and row.render.items[i + 1] == scs[1])
        {
            // From here to end is a comment
            @memset(row.hl.items[i..], .comment);
            break;
        }

        // Handle multi-line comments
        if (in_comment) {
            row.hl.items[i] = .mlcomment;
            if (mce.len >= 2 and i + 1 < rsize and
                ch == mce[0] and row.render.items[i + 1] == mce[1])
            {
                row.hl.items[i + 1] = .mlcomment;
                i += 2;
                in_comment = false;
                prev_sep = true;
                continue;
            } else {
                prev_sep = false;
                i += 1;
                continue;
            }
        } else if (mcs.len >= 2 and i + 1 < rsize and
            ch == mcs[0] and row.render.items[i + 1] == mcs[1])
        {
            row.hl.items[i] = .mlcomment;
            row.hl.items[i + 1] = .mlcomment;
            i += 2;
            in_comment = true;
            prev_sep = false;
            continue;
        }

        // Handle "" and ''
        if (flags & HL_HIGHLIGHT_STRINGS != 0) {
            if (in_string != 0) {
                row.hl.items[i] = .string;
                if (ch == '\\' and i + 1 < rsize) {
                    row.hl.items[i + 1] = .string;
                    i += 2;
                    prev_sep = false;
                    continue;
                }
                if (ch == in_string) in_string = 0;
                i += 1;
                continue;
            } else {
                if (ch == '"' or ch == '\'') {
                    in_string = ch;
                    row.hl.items[i] = .string;
                    i += 1;
                    prev_sep = false;
                    continue;
                }
            }
        }

        // Handle non-printable chars
        if (!std.ascii.isPrint(ch)) {
            row.hl.items[i] = .nonprint;
            i += 1;
            prev_sep = false;
            continue;
        }

        // Handle numbers
        if (flags & HL_HIGHLIGHT_NUMBERS != 0) {
            if ((std.ascii.isDigit(ch) and (prev_sep or (i > 0 and row.hl.items[i - 1] == .number))) or
                (ch == '.' and i > 0 and row.hl.items[i - 1] == .number))
            {
                row.hl.items[i] = .number;
                i += 1;
                prev_sep = false;
                continue;
            }
        }

        // Handle keywords
        if (prev_sep) {
            var matched = false;
            for (keywords) |kw| {
                var klen = kw.len;
                const kw2 = klen > 0 and kw[klen - 1] == '|';
                if (kw2) klen -= 1;

                if (i + klen <= rsize and
                    std.mem.eql(u8, row.render.items[i .. i + klen], kw[0..klen]) and
                    (i + klen >= rsize or isSeparator(row.render.items[i + klen])))
                {
                    const hl_type: Highlight = if (kw2) .keyword2 else .keyword1;
                    @memset(row.hl.items[i .. i + klen], hl_type);
                    i += klen;
                    matched = true;
                    break;
                }
            }
            if (matched) {
                prev_sep = false;
                continue;
            }
        }

        // Not special chars
        prev_sep = isSeparator(ch);
        i += 1;
    }

    // Propagate syntax change to the next row if the open comment state changed
    const oc = editorRowHasOpenComment(row);
    if (row.hl_oc != oc and row.idx + 1 < E.rows.items.len) {
        editorUpdateSyntax(&E.rows.items[row.idx + 1]);
    }
    row.hl_oc = oc;
}

fn editorSyntaxToColor(hl: Highlight) u8 {
    return switch (hl) {
        .comment, .mlcomment => 36, // cyan
        .keyword1 => 33, // yellow
        .keyword2 => 32, // green
        .string => 35, // magenta
        .number => 31, // red
        .match => 34, // blue
        else => 37, // white
    };
}

fn editorSelectSyntaxHighlight(filename: []const u8) void {
    E.syntax = null;
    for (&HLDB) |*s| {
        for (s.filematch) |pat| {
            // Find the pattern in the filename
            if (std.mem.indexOf(u8, filename, pat)) |pos| {
                if (pat[0] != '.' or pos + pat.len == filename.len) {
                    E.syntax = s;
                    return;
                }
            }
        }
    }
}

// ======================= Editor rows implementation =======================

fn editorUpdateRow(row: *EditorRow) void {
    // Count tabs
    var tabs: usize = 0;
    for (row.chars.items) |ch| {
        if (ch == @intFromEnum(KeyAction.tab)) tabs += 1;
    }

    row.render.items.len = 0;
    row.render.ensureTotalCapacity(allocator, row.chars.items.len + tabs * 7 + 1) catch return;

    var idx: usize = 0;
    for (row.chars.items) |ch| {
        if (ch == @intFromEnum(KeyAction.tab)) {
            row.render.append(allocator, ' ') catch return;
            idx += 1;
            while ((idx) % KILO_TAB_STOP != 0) {
                row.render.append(allocator, ' ') catch return;
                idx += 1;
            }
        } else {
            row.render.append(allocator, ch) catch return;
            idx += 1;
        }
    }

    editorUpdateSyntax(row);
}

fn editorInsertRow(at: usize, s: []const u8) void {
    if (at > E.rows.items.len) return;

    // Insert a new row at position 'at'
    const new_row = EditorRow{
        .idx = at,
        .chars = std.ArrayList(u8).empty,
        .render = std.ArrayList(u8).empty,
        .hl = std.ArrayList(Highlight).empty,
        .hl_oc = false,
    };

    E.rows.insert(allocator, at, new_row) catch return;

    // Update idx for rows after 'at'
    var j: usize = at + 1;
    while (j < E.rows.items.len) : (j += 1) {
        E.rows.items[j].idx = j;
    }

    const row = &E.rows.items[at];
    row.chars.appendSlice(allocator, s) catch return;
    editorUpdateRow(row);

    E.dirty += 1;
}

fn editorFreeRow(row: *EditorRow) void {
    row.chars.deinit(allocator);
    row.render.deinit(allocator);
    row.hl.deinit(allocator);
}

fn editorDelRow(at: usize) void {
    if (at >= E.rows.items.len) return;
    editorFreeRow(&E.rows.items[at]);
    _ = E.rows.orderedRemove(at);
    // Update idx for all rows from 'at' onwards
    var j: usize = at;
    while (j < E.rows.items.len) : (j += 1) {
        E.rows.items[j].idx = j;
    }
    E.dirty += 1;
}

fn editorRowsToString() ![]u8 {
    var totlen: usize = 0;
    for (E.rows.items) |row| {
        totlen += row.chars.items.len + 1; // +1 for newline
    }

    var buf = try allocator.alloc(u8, totlen);
    var pos: usize = 0;
    for (E.rows.items) |row| {
        @memcpy(buf[pos .. pos + row.chars.items.len], row.chars.items);
        pos += row.chars.items.len;
        buf[pos] = '\n';
        pos += 1;
    }
    return buf;
}

fn editorRowInsertChar(row: *EditorRow, at: usize, ch: u8) void {
    const size = row.chars.items.len;
    if (at > size) {
        // Pad with spaces
        const padlen = at - size;
        row.chars.ensureTotalCapacity(allocator, size + padlen + 1) catch return;
        var p: usize = 0;
        while (p < padlen) : (p += 1) {
            row.chars.append(allocator, ' ') catch return;
        }
        row.chars.append(allocator, ch) catch return;
    } else {
        row.chars.insert(allocator, at, ch) catch return;
    }
    editorUpdateRow(row);
    E.dirty += 1;
}

fn editorRowAppendString(row: *EditorRow, s: []const u8) void {
    row.chars.appendSlice(allocator, s) catch return;
    editorUpdateRow(row);
    E.dirty += 1;
}

fn editorRowDelChar(row: *EditorRow, at: usize) void {
    if (at >= row.chars.items.len) return;
    _ = row.chars.orderedRemove(at);
    editorUpdateRow(row);
    E.dirty += 1;
}

fn editorInsertChar(ch: u8) void {
    const filerow = E.rowoff + E.cy;
    const filecol = E.coloff + E.cx;

    // If the row doesn't exist, add empty rows
    while (E.rows.items.len <= filerow) {
        editorInsertRow(E.rows.items.len, "");
    }

    const row = &E.rows.items[filerow];
    editorRowInsertChar(row, filecol, ch);

    if (E.cx == E.screencols - 1) {
        E.coloff += 1;
    } else {
        E.cx += 1;
    }
    E.dirty += 1;
}

fn editorInsertNewline() void {
    const filerow = E.rowoff + E.cy;
    var filecol = E.coloff + E.cx;

    if (filerow >= E.rows.items.len) {
        if (filerow == E.rows.items.len) {
            editorInsertRow(filerow, "");
            // goto fixcursor
            if (E.cy == E.screenrows - 1) {
                E.rowoff += 1;
            } else {
                E.cy += 1;
            }
            E.cx = 0;
            E.coloff = 0;
        }
        return;
    }

    const row = &E.rows.items[filerow];
    if (filecol >= row.chars.items.len) filecol = row.chars.items.len;

    if (filecol == 0) {
        editorInsertRow(filerow, "");
    } else {
        // Split row at filecol
        const rest = row.chars.items[filecol..];
        editorInsertRow(filerow + 1, rest);
        // Truncate current row
        const cur_row = &E.rows.items[filerow];
        cur_row.chars.items.len = filecol;
        editorUpdateRow(cur_row);
    }

    // fixcursor:
    if (E.cy == E.screenrows - 1) {
        E.rowoff += 1;
    } else {
        E.cy += 1;
    }
    E.cx = 0;
    E.coloff = 0;
}

fn editorDelChar() void {
    const filerow = E.rowoff + E.cy;
    const filecol = E.coloff + E.cx;

    if (filerow >= E.rows.items.len) return;
    if (filecol == 0 and filerow == 0) return;

    const row = &E.rows.items[filerow];

    if (filecol == 0) {
        // Handle column 0: merge with previous row
        const prev_row = &E.rows.items[filerow - 1];
        const prev_size = prev_row.chars.items.len;
        editorRowAppendString(prev_row, row.chars.items);
        editorDelRow(filerow);
        if (E.cy == 0) {
            if (E.rowoff > 0) E.rowoff -= 1;
        } else {
            E.cy -= 1;
        }
        E.cx = prev_size;
        if (E.cx >= E.screencols) {
            E.coloff = E.cx - E.screencols + 1;
            E.cx = E.screencols - 1;
        }
    } else {
        editorRowDelChar(row, filecol - 1);
        if (E.cx == 0 and E.coloff > 0) {
            E.coloff -= 1;
        } else if (E.cx > 0) {
            E.cx -= 1;
        }
    }
    E.dirty += 1;
}

// ======================= File I/O =======================

fn editorOpen(filename: []const u8) !void {
    E.dirty = 0;

    // Store filename
    if (E.filename) |old| {
        allocator.free(old);
    }
    E.filename = try allocator.dupe(u8, filename);

    // Try to open file
    const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // New file - no error, just empty
            return;
        }
        return err;
    };
    defer file.close();

    // Read entire file
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    // Split by lines
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        // Strip trailing \r
        var ln = line;
        if (ln.len > 0 and ln[ln.len - 1] == '\r') {
            ln = ln[0 .. ln.len - 1];
        }
        editorInsertRow(E.rows.items.len, ln);
    }

    // Remove last empty row that results from trailing newline
    if (E.rows.items.len > 0) {
        const last = &E.rows.items[E.rows.items.len - 1];
        if (last.chars.items.len == 0 and E.rows.items.len > 1) {
            editorFreeRow(last);
            E.rows.items.len -= 1;
        }
    }

    E.dirty = 0;
}

fn editorSave() void {
    const filename = E.filename orelse {
        editorSetStatusMessage("No filename");
        return;
    };

    const buf = editorRowsToString() catch {
        editorSetStatusMessage("Can't save! Memory error");
        return;
    };
    defer allocator.free(buf);

    const file = std.fs.cwd().createFile(filename, .{ .truncate = true }) catch |err| {
        var errbuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "Can't save! I/O error: {s}", .{@errorName(err)}) catch "Can't save!";
        editorSetStatusMessage(msg);
        return;
    };
    defer file.close();

    file.writeAll(buf) catch |err| {
        var errbuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "Can't save! I/O error: {s}", .{@errorName(err)}) catch "Can't save!";
        editorSetStatusMessage(msg);
        return;
    };

    E.dirty = 0;
    var msgbuf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msgbuf, "{d} bytes written on disk", .{buf.len}) catch "Saved";
    editorSetStatusMessage(msg);
}

// ============================= Terminal update ============================

fn editorRefreshScreen() void {
    var ab = std.ArrayList(u8).empty;
    defer ab.deinit(allocator);

    // Hide cursor
    ab.appendSlice(allocator, "\x1b[?25l") catch return;
    // Go home
    ab.appendSlice(allocator, "\x1b[H") catch return;

    var y: usize = 0;
    while (y < E.screenrows) : (y += 1) {
        const filerow = E.rowoff + y;

        if (filerow >= E.rows.items.len) {
            if (E.rows.items.len == 0 and y == E.screenrows / 3) {
                var welcome: [80]u8 = undefined;
                const welcome_str = std.fmt.bufPrint(&welcome, "Kilo editor -- version {s}\x1b[0K\r\n", .{KILO_VERSION}) catch "Kilo\r\n";
                const welcome_len = welcome_str.len;
                const padding = if (E.screencols > welcome_len) (E.screencols - welcome_len) / 2 else 0;
                if (padding > 0) {
                    ab.append(allocator, '~') catch return;
                    var p: usize = 1;
                    while (p < padding) : (p += 1) {
                        ab.append(allocator, ' ') catch return;
                    }
                }
                ab.appendSlice(allocator, welcome_str) catch return;
            } else {
                ab.appendSlice(allocator, "~\x1b[0K\r\n") catch return;
            }
            continue;
        }

        const r = &E.rows.items[filerow];
        const rlen = r.render.items.len;
        const len: usize = if (rlen > E.coloff) blk: {
            const visible = rlen - E.coloff;
            break :blk if (visible > E.screencols) E.screencols else visible;
        } else 0;

        var current_color: i32 = -1;

        if (len > 0) {
            const render_slice = r.render.items[E.coloff .. E.coloff + len];
            const hl_slice = if (r.hl.items.len > E.coloff)
                r.hl.items[E.coloff..@min(E.coloff + len, r.hl.items.len)]
            else
                &[_]Highlight{};

            for (render_slice, 0..) |ch, j| {
                const hl: Highlight = if (j < hl_slice.len) hl_slice[j] else .normal;

                if (hl == .nonprint) {
                    ab.appendSlice(allocator, "\x1b[7m") catch return;
                    const sym: u8 = if (ch <= 26) '@' + ch else '?';
                    ab.append(allocator, sym) catch return;
                    ab.appendSlice(allocator, "\x1b[0m") catch return;
                    current_color = -1;
                } else if (hl == .normal) {
                    if (current_color != -1) {
                        ab.appendSlice(allocator, "\x1b[39m") catch return;
                        current_color = -1;
                    }
                    ab.append(allocator, ch) catch return;
                } else {
                    const color: i32 = @intCast(editorSyntaxToColor(hl));
                    if (color != current_color) {
                        var cbuf: [16]u8 = undefined;
                        const cseq = std.fmt.bufPrint(&cbuf, "\x1b[{d}m", .{color}) catch "\x1b[37m";
                        ab.appendSlice(allocator, cseq) catch return;
                        current_color = color;
                    }
                    ab.append(allocator, ch) catch return;
                }
            }
        }

        ab.appendSlice(allocator, "\x1b[39m") catch return;
        ab.appendSlice(allocator, "\x1b[0K") catch return;
        ab.appendSlice(allocator, "\r\n") catch return;
    }

    // Status bar
    ab.appendSlice(allocator, "\x1b[0K") catch return;
    ab.appendSlice(allocator, "\x1b[7m") catch return;

    var status: [80]u8 = undefined;
    const fname = E.filename orelse "[No Name]";
    const fname_trunc = if (fname.len > 20) fname[0..20] else fname;
    const status_str = std.fmt.bufPrint(&status, "{s} - {d} lines {s}", .{
        fname_trunc,
        E.rows.items.len,
        if (E.dirty > 0) "(modified)" else "",
    }) catch "status error";
    var slen = status_str.len;
    if (slen > E.screencols) slen = E.screencols;

    var rstatus: [80]u8 = undefined;
    const rstatus_str = std.fmt.bufPrint(&rstatus, "{d}/{d}", .{
        E.rowoff + E.cy + 1,
        E.rows.items.len,
    }) catch "?/?";
    const rlen = rstatus_str.len;

    ab.appendSlice(allocator, status_str[0..slen]) catch return;

    var len: usize = slen;
    while (len < E.screencols) : (len += 1) {
        if (E.screencols - len == rlen) {
            ab.appendSlice(allocator, rstatus_str) catch return;
            break;
        } else {
            ab.append(allocator, ' ') catch return;
        }
    }

    ab.appendSlice(allocator, "\x1b[0m\r\n") catch return;

    // Message bar
    ab.appendSlice(allocator, "\x1b[0K") catch return;
    const msglen = E.statusmsg_len;
    if (msglen > 0 and std.time.timestamp() - E.statusmsg_time < 5) {
        const show_len = if (msglen <= E.screencols) msglen else E.screencols;
        ab.appendSlice(allocator, E.statusmsg[0..show_len]) catch return;
    }

    // Position cursor
    const filerow = E.rowoff + E.cy;
    const row = if (filerow < E.rows.items.len) &E.rows.items[filerow] else null;
    var cx: usize = 1;
    if (row) |r| {
        var j: usize = E.coloff;
        while (j < E.cx + E.coloff) : (j += 1) {
            if (j < r.chars.items.len and r.chars.items[j] == @intFromEnum(KeyAction.tab)) {
                cx += 7 - (cx % 8);
            }
            cx += 1;
        }
    }

    var posbuf: [32]u8 = undefined;
    const posseq = std.fmt.bufPrint(&posbuf, "\x1b[{d};{d}H", .{ E.cy + 1, cx }) catch "\x1b[1;1H";
    ab.appendSlice(allocator, posseq) catch return;

    // Show cursor
    ab.appendSlice(allocator, "\x1b[?25h") catch return;

    _ = posix.write(posix.STDOUT_FILENO, ab.items) catch {};
}

fn editorSetStatusMessage(msg: []const u8) void {
    const len = if (msg.len < E.statusmsg.len) msg.len else E.statusmsg.len;
    @memcpy(E.statusmsg[0..len], msg[0..len]);
    E.statusmsg_len = len;
    E.statusmsg_time = std.time.timestamp();
}

// =============================== Find mode ================================

fn editorFind() void {
    var query: [KILO_QUERY_LEN + 1]u8 = @splat(0);
    var qlen: usize = 0;
    var last_match: i64 = -1;
    var find_next: i32 = 0;

    var saved_hl_line: i64 = -1;
    var saved_hl: ?[]Highlight = null;

    const saved_cx = E.cx;
    const saved_cy = E.cy;
    const saved_coloff = E.coloff;
    const saved_rowoff = E.rowoff;

    defer {
        // Restore saved highlight
        if (saved_hl) |hl| {
            if (saved_hl_line >= 0 and @as(usize, @intCast(saved_hl_line)) < E.rows.items.len) {
                const row = &E.rows.items[@intCast(saved_hl_line)];
                const copy_len = if (hl.len < row.hl.items.len) hl.len else row.hl.items.len;
                @memcpy(row.hl.items[0..copy_len], hl[0..copy_len]);
            }
            allocator.free(hl);
        }
    }

    while (true) {
        var msgbuf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&msgbuf, "Search: {s} (Use ESC/Arrows/Enter)", .{query[0..qlen]}) catch "Search:";
        editorSetStatusMessage(msg);
        editorRefreshScreen();

        const key = editorReadKey();

        if (key == @intFromEnum(KeyAction.del_key) or
            key == @intFromEnum(KeyAction.ctrl_h) or
            key == @intFromEnum(KeyAction.backspace))
        {
            if (qlen > 0) {
                qlen -= 1;
                query[qlen] = 0;
            }
            last_match = -1;
        } else if (key == @intFromEnum(KeyAction.esc) or key == @intFromEnum(KeyAction.enter)) {
            if (key == @intFromEnum(KeyAction.esc)) {
                E.cx = saved_cx;
                E.cy = saved_cy;
                E.coloff = saved_coloff;
                E.rowoff = saved_rowoff;
            }
            editorSetStatusMessage("");
            return;
        } else if (key == @intFromEnum(KeyAction.arrow_right) or key == @intFromEnum(KeyAction.arrow_down)) {
            find_next = 1;
        } else if (key == @intFromEnum(KeyAction.arrow_left) or key == @intFromEnum(KeyAction.arrow_up)) {
            find_next = -1;
        } else if (std.ascii.isPrint(@truncate(key))) {
            if (qlen < KILO_QUERY_LEN) {
                query[qlen] = @truncate(key);
                qlen += 1;
                query[qlen] = 0;
                last_match = -1;
            }
        }

        // Search occurrence
        if (last_match == -1) find_next = 1;
        if (find_next != 0) {
            var current: i64 = last_match;
            var matched_row: ?usize = null;
            var match_offset: usize = 0;

            var i: usize = 0;
            while (i < E.rows.items.len) : (i += 1) {
                current += find_next;
                if (current < 0) current = @intCast(E.rows.items.len - 1);
                if (@as(usize, @intCast(current)) >= E.rows.items.len) current = 0;

                const row = &E.rows.items[@intCast(current)];
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
                if (saved_hl_line >= 0 and @as(usize, @intCast(saved_hl_line)) < E.rows.items.len) {
                    const prev = &E.rows.items[@intCast(saved_hl_line)];
                    const copy_len = if (hl.len < prev.hl.items.len) hl.len else prev.hl.items.len;
                    @memcpy(prev.hl.items[0..copy_len], hl[0..copy_len]);
                }
                allocator.free(hl);
                saved_hl = null;
            }

            if (matched_row) |row_idx| {
                last_match = @intCast(row_idx);
                const row = &E.rows.items[row_idx];

                // Save and apply match highlight
                if (row.hl.items.len > 0) {
                    saved_hl_line = @intCast(row_idx);
                    saved_hl = allocator.dupe(Highlight, row.hl.items) catch null;
                    @memset(row.hl.items[match_offset..@min(match_offset + qlen, row.hl.items.len)], .match);
                }

                E.cy = 0;
                E.cx = match_offset;
                E.rowoff = row_idx;
                E.coloff = 0;
                if (E.cx >= E.screencols) {
                    const diff = E.cx - E.screencols + 1;
                    E.cx -= diff;
                    E.coloff += diff;
                }
            }
        }
    }
}

// ========================= Editor events handling ========================

fn editorMoveCursor(key: u16) void {
    const filerow = E.rowoff + E.cy;
    const filecol = E.coloff + E.cx;
    const row = if (filerow < E.rows.items.len) &E.rows.items[filerow] else null;

    if (key == @intFromEnum(KeyAction.arrow_left)) {
        if (E.cx == 0) {
            if (E.coloff > 0) {
                E.coloff -= 1;
            } else if (filerow > 0) {
                E.cy -= 1;
                const prev_row = &E.rows.items[filerow - 1];
                E.cx = prev_row.chars.items.len;
                if (E.cx > E.screencols - 1) {
                    E.coloff = E.cx - E.screencols + 1;
                    E.cx = E.screencols - 1;
                }
            }
        } else {
            E.cx -= 1;
        }
    } else if (key == @intFromEnum(KeyAction.arrow_right)) {
        if (row != null and filecol < row.?.chars.items.len) {
            if (E.cx == E.screencols - 1) {
                E.coloff += 1;
            } else {
                E.cx += 1;
            }
        } else if (row != null and filecol == row.?.chars.items.len) {
            E.cx = 0;
            E.coloff = 0;
            if (E.cy == E.screenrows - 1) {
                E.rowoff += 1;
            } else {
                E.cy += 1;
            }
        }
    } else if (key == @intFromEnum(KeyAction.arrow_up)) {
        if (E.cy == 0) {
            if (E.rowoff > 0) E.rowoff -= 1;
        } else {
            E.cy -= 1;
        }
    } else if (key == @intFromEnum(KeyAction.arrow_down)) {
        if (filerow < E.rows.items.len) {
            if (E.cy == E.screenrows - 1) {
                E.rowoff += 1;
            } else {
                E.cy += 1;
            }
        }
    }

    // Fix cx if the current line has not enough chars
    const new_filerow = E.rowoff + E.cy;
    const new_filecol = E.coloff + E.cx;
    const new_row = if (new_filerow < E.rows.items.len) &E.rows.items[new_filerow] else null;
    const rowlen: usize = if (new_row) |r| r.chars.items.len else 0;
    if (new_filecol > rowlen) {
        // Need to reduce cx (or coloff)
        const excess = new_filecol - rowlen;
        if (E.cx >= excess) {
            E.cx -= excess;
        } else {
            E.coloff -= excess - E.cx;
            E.cx = 0;
        }
    }
}

var quit_times: usize = KILO_QUIT_TIMES;

fn editorProcessKeypress() void {
    const key = editorReadKey();

    if (key == @intFromEnum(KeyAction.enter)) {
        editorInsertNewline();
    } else if (key == @intFromEnum(KeyAction.ctrl_c)) {
        // Ignore Ctrl-C
    } else if (key == @intFromEnum(KeyAction.ctrl_q)) {
        if (E.dirty > 0 and quit_times > 0) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{quit_times}) catch "WARNING! Unsaved changes.";
            editorSetStatusMessage(msg);
            quit_times -= 1;
            return;
        }
        disableRawMode();
        std.process.exit(0);
    } else if (key == @intFromEnum(KeyAction.ctrl_s)) {
        editorSave();
    } else if (key == @intFromEnum(KeyAction.ctrl_f)) {
        editorFind();
    } else if (key == @intFromEnum(KeyAction.backspace) or
        key == @intFromEnum(KeyAction.ctrl_h) or
        key == @intFromEnum(KeyAction.del_key))
    {
        if (key == @intFromEnum(KeyAction.del_key)) {
            editorMoveCursor(@intFromEnum(KeyAction.arrow_right));
        }
        editorDelChar();
    } else if (key == @intFromEnum(KeyAction.page_up) or key == @intFromEnum(KeyAction.page_down)) {
        if (key == @intFromEnum(KeyAction.page_up) and E.cy != 0) {
            E.cy = 0;
        } else if (key == @intFromEnum(KeyAction.page_down) and E.cy != E.screenrows - 1) {
            E.cy = E.screenrows - 1;
        }
        var times = E.screenrows;
        while (times > 0) : (times -= 1) {
            editorMoveCursor(if (key == @intFromEnum(KeyAction.page_up))
                @intFromEnum(KeyAction.arrow_up)
            else
                @intFromEnum(KeyAction.arrow_down));
        }
    } else if (key == @intFromEnum(KeyAction.arrow_up) or
        key == @intFromEnum(KeyAction.arrow_down) or
        key == @intFromEnum(KeyAction.arrow_left) or
        key == @intFromEnum(KeyAction.arrow_right))
    {
        editorMoveCursor(key);
    } else if (key == @intFromEnum(KeyAction.ctrl_l) or key == @intFromEnum(KeyAction.esc)) {
        // Nothing to do
    } else {
        // Insert character if printable
        if (key < 128 and std.ascii.isPrint(@truncate(key))) {
            editorInsertChar(@truncate(key));
        }
    }

    quit_times = KILO_QUIT_TIMES;
}

// SIGWINCH handler
fn handleSigWinCh(_: i32) callconv(.c) void {
    var rows: usize = 0;
    var cols: usize = 0;
    getWindowSize(&rows, &cols) catch return;
    E.screenrows = rows;
    E.screencols = cols;
    if (E.screenrows >= 2) E.screenrows -= 2;
    if (E.cy >= E.screenrows and E.screenrows > 0) E.cy = E.screenrows - 1;
    if (E.cx >= E.screencols and E.screencols > 0) E.cx = E.screencols - 1;
    editorRefreshScreen();
}

fn initEditor() !void {
    E.cx = 0;
    E.cy = 0;
    E.rowoff = 0;
    E.coloff = 0;
    E.rows = std.ArrayList(EditorRow).empty;
    E.dirty = 0;
    E.filename = null;
    E.statusmsg = @splat(0);
    E.statusmsg_len = 0;
    E.statusmsg_time = 0;
    E.syntax = null;
    E.rawmode = false;

    var rows: usize = 0;
    var cols: usize = 0;
    try getWindowSize(&rows, &cols);
    E.screenrows = rows;
    E.screencols = cols;
    if (E.screenrows >= 2) E.screenrows -= 2;

    // Install SIGWINCH handler
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigWinCh },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(c.SIG.WINCH, &sa, null);
}

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        _ = posix.write(posix.STDERR_FILENO, "Usage: kilo <filename>\n") catch {};
        std.process.exit(1);
    }

    try initEditor();

    const filename = args[1];
    editorSelectSyntaxHighlight(filename);
    try editorOpen(filename);

    try enableRawMode();
    defer disableRawMode();

    editorSetStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find");

    while (true) {
        editorRefreshScreen();
        editorProcessKeypress();
    }
}
