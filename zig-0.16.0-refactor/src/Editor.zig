const std = @import("std");
const posix = std.posix;
const terminal = @import("terminal.zig");
const syntax = @import("syntax.zig");
const Row = @import("Row.zig");
const Highlight = syntax.Highlight;
const Key = terminal.Key;

const version = "0.0.1";
const quit_times_max = 3;
const query_len = 256;
const status_buf_size = 80;

const Self = @This();

cx: usize = 0,
cy: usize = 0,
rowoff: usize = 0,
coloff: usize = 0,
screenrows: usize = 0,
screencols: usize = 0,
rows: std.ArrayList(Row) = std.ArrayList(Row).empty,
dirty: usize = 0,
filename: ?[]u8 = null,
status_msg: [status_buf_size]u8 = @splat(0),
status_msg_len: usize = 0,
status_msg_time: i64 = 0,
syn: ?*const syntax.Syntax = null,
term: terminal.Terminal = .{},
quit_times: usize = quit_times_max,
allocator: std.mem.Allocator,
io: std.Io,

pub fn init(allocator: std.mem.Allocator, io_handle: std.Io) !Self {
    var self = Self{
        .allocator = allocator,
        .io = io_handle,
    };

    var rows: usize = 0;
    var cols: usize = 0;
    try self.term.getWindowSize(&rows, &cols);
    self.screenrows = if (rows >= 2) rows - 2 else rows;
    self.screencols = cols;

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.rows.items) |*row| row.deinit();
    self.rows.deinit(self.allocator);
    if (self.filename) |f| self.allocator.free(f);
}

// ======================= Row Operations =======================

fn updateRow(self: *Self, row: *Row) void {
    row.updateRender(self.rows.items, self.syn);
}

pub fn insertRow(self: *Self, at: usize, s: []const u8) void {
    if (at > self.rows.items.len) return;

    var new_row = Row.init(self.allocator, at, s) catch return;
    self.rows.insert(self.allocator, at, new_row) catch {
        new_row.deinit();
        return;
    };

    for (self.rows.items[at + 1 ..], at + 1..) |*row, idx| {
        row.idx = idx;
    }

    self.updateRow(&self.rows.items[at]);
    self.dirty += 1;
}

fn deleteRow(self: *Self, at: usize) void {
    if (at >= self.rows.items.len) return;
    self.rows.items[at].deinit();
    _ = self.rows.orderedRemove(at);
    for (self.rows.items[at..], at..) |*row, idx| {
        row.idx = idx;
    }
    self.dirty += 1;
}

fn rowsToString(self: *Self) ![]u8 {
    var totlen: usize = 0;
    for (self.rows.items) |row| {
        totlen += row.chars.items.len + 1;
    }

    const buf = try self.allocator.alloc(u8, totlen);
    var pos: usize = 0;
    for (self.rows.items) |row| {
        @memcpy(buf[pos .. pos + row.chars.items.len], row.chars.items);
        pos += row.chars.items.len;
        buf[pos] = '\n';
        pos += 1;
    }
    return buf;
}

// ======================= Editing Operations =======================

pub fn insertChar(self: *Self, ch: u8) void {
    const filerow = self.rowoff + self.cy;
    const filecol = self.coloff + self.cx;

    while (self.rows.items.len <= filerow) {
        self.insertRow(self.rows.items.len, "");
    }

    const row = &self.rows.items[filerow];
    row.insertChar(filecol, ch);
    self.updateRow(row);

    if (self.cx == self.screencols - 1) {
        self.coloff += 1;
    } else {
        self.cx += 1;
    }
    self.dirty += 1;
}

pub fn insertNewline(self: *Self) void {
    const filerow = self.rowoff + self.cy;
    var filecol = self.coloff + self.cx;

    if (filerow >= self.rows.items.len) {
        if (filerow == self.rows.items.len) {
            self.insertRow(filerow, "");
            self.advanceCursorDown();
        }
        return;
    }

    const row = &self.rows.items[filerow];
    if (filecol >= row.chars.items.len) filecol = row.chars.items.len;

    if (filecol == 0) {
        self.insertRow(filerow, "");
    } else {
        const rest = row.chars.items[filecol..];
        self.insertRow(filerow + 1, rest);
        const cur_row = &self.rows.items[filerow];
        cur_row.truncate(filecol);
        self.updateRow(cur_row);
    }

    self.advanceCursorDown();
}

pub fn deleteChar(self: *Self) void {
    const filerow = self.rowoff + self.cy;
    const filecol = self.coloff + self.cx;

    if (filerow >= self.rows.items.len) return;
    if (filecol == 0 and filerow == 0) return;

    const row = &self.rows.items[filerow];

    if (filecol == 0) {
        const prev_row = &self.rows.items[filerow - 1];
        const prev_size = prev_row.chars.items.len;
        prev_row.appendString(row.chars.items);
        self.updateRow(prev_row);
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
        self.updateRow(row);
        if (self.cx == 0 and self.coloff > 0) {
            self.coloff -= 1;
        } else if (self.cx > 0) {
            self.cx -= 1;
        }
    }
    self.dirty += 1;
}

fn advanceCursorDown(self: *Self) void {
    if (self.cy == self.screenrows - 1) {
        self.rowoff += 1;
    } else {
        self.cy += 1;
    }
    self.cx = 0;
    self.coloff = 0;
}

// ======================= Cursor Movement =======================

pub fn moveCursor(self: *Self, key: Key) void {
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

    // Fix cx if current line is shorter
    const new_filerow = self.rowoff + self.cy;
    const new_filecol = self.coloff + self.cx;
    const rowlen: usize = if (new_filerow < self.rows.items.len)
        self.rows.items[new_filerow].chars.items.len
    else
        0;
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

// ======================= File I/O =======================

pub fn open(self: *Self, filename: []const u8) !void {
    self.dirty = 0;

    if (self.filename) |old| self.allocator.free(old);
    self.filename = try self.allocator.dupe(u8, filename);

    self.syn = syntax.Syntax.detect(filename);

    const content = std.Io.Dir.cwd().readFileAlloc(self.io, filename, self.allocator, .unlimited) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer self.allocator.free(content);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        var ln = line;
        if (ln.len > 0 and ln[ln.len - 1] == '\r') {
            ln = ln[0 .. ln.len - 1];
        }
        self.insertRow(self.rows.items.len, ln);
    }

    if (self.rows.items.len > 1) {
        const last = &self.rows.items[self.rows.items.len - 1];
        if (last.chars.items.len == 0) {
            last.deinit();
            self.rows.items.len -= 1;
        }
    }

    self.dirty = 0;
}

pub fn save(self: *Self) void {
    const filename = self.filename orelse {
        self.setStatusMessage("No filename");
        return;
    };

    const buf = self.rowsToString() catch {
        self.setStatusMessage("Can't save! Memory error");
        return;
    };
    defer self.allocator.free(buf);

    const file = std.Io.Dir.cwd().createFile(self.io, filename, .{ .truncate = true }) catch |err| {
        var errbuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "Can't save! I/O error: {s}", .{@errorName(err)}) catch "Can't save!";
        self.setStatusMessage(msg);
        return;
    };
    defer file.close(self.io);

    file.writeStreamingAll(self.io, buf) catch |err| {
        var errbuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "Can't save! I/O error: {s}", .{@errorName(err)}) catch "Can't save!";
        self.setStatusMessage(msg);
        return;
    };

    self.dirty = 0;
    var msgbuf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msgbuf, "{d} bytes written on disk", .{buf.len}) catch "Saved";
    self.setStatusMessage(msg);
}

// ======================= Find =======================

pub fn find(self: *Self) void {
    var query: [query_len + 1]u8 = @splat(0);
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
        if (saved_hl) |hl| {
            if (saved_hl_line >= 0 and @as(usize, @intCast(saved_hl_line)) < self.rows.items.len) {
                const row = &self.rows.items[@intCast(saved_hl_line)];
                const copy_len = @min(hl.len, row.hl.items.len);
                @memcpy(row.hl.items[0..copy_len], hl[0..copy_len]);
            }
            self.allocator.free(hl);
        }
    }

    while (true) {
        var msgbuf: [status_buf_size]u8 = undefined;
        const msg = std.fmt.bufPrint(&msgbuf, "Search: {s} (Use ESC/Arrows/Enter)", .{query[0..qlen]}) catch "Search:";
        self.setStatusMessage(msg);
        self.refreshScreen();

        const key = self.term.readKey();

        if (key == .del_key or key == .ctrl_h or key == .backspace) {
            if (qlen > 0) {
                qlen -= 1;
                query[qlen] = 0;
            }
            last_match = -1;
        } else if (key == .esc or key == .enter) {
            if (key == .esc) {
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
        } else if (key.isPrintable()) {
            if (qlen < query_len) {
                query[qlen] = key.toChar();
                qlen += 1;
                query[qlen] = 0;
                last_match = -1;
            }
        }

        if (last_match == -1) find_next = 1;
        if (find_next != 0) {
            var current: i64 = last_match;
            var matched_row: ?usize = null;
            var match_offset: usize = 0;

            for (0..self.rows.items.len) |_| {
                current += find_next;
                if (current < 0) current = @intCast(self.rows.items.len - 1);
                if (@as(usize, @intCast(current)) >= self.rows.items.len) current = 0;

                const row = &self.rows.items[@intCast(current)];
                if (std.mem.indexOf(u8, row.render.items, query[0..qlen])) |offset| {
                    matched_row = @intCast(current);
                    match_offset = offset;
                    break;
                }
            }
            find_next = 0;

            if (saved_hl) |hl| {
                if (saved_hl_line >= 0 and @as(usize, @intCast(saved_hl_line)) < self.rows.items.len) {
                    const prev = &self.rows.items[@intCast(saved_hl_line)];
                    const copy_len = @min(hl.len, prev.hl.items.len);
                    @memcpy(prev.hl.items[0..copy_len], hl[0..copy_len]);
                }
                self.allocator.free(hl);
                saved_hl = null;
            }

            if (matched_row) |row_idx| {
                last_match = @intCast(row_idx);
                const row = &self.rows.items[row_idx];

                if (row.hl.items.len > 0) {
                    saved_hl_line = @intCast(row_idx);
                    saved_hl = self.allocator.dupe(Highlight, row.hl.items) catch null;
                    @memset(row.hl.items[match_offset..@min(match_offset + qlen, row.hl.items.len)], .match);
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

// ======================= Screen Refresh =======================

pub fn refreshScreen(self: *Self) void {
    var ab = std.ArrayList(u8).empty;
    defer ab.deinit(self.allocator);

    ab.appendSlice(self.allocator, "\x1b[?25l\x1b[H") catch return;

    self.renderRows(&ab);
    self.renderStatusBar(&ab);
    self.renderMessageBar(&ab);

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
    ab.appendSlice(self.allocator, posseq) catch return;
    ab.appendSlice(self.allocator, "\x1b[?25h") catch return;

    _ = terminal.write(posix.STDOUT_FILENO, ab.items) catch {};
}

fn renderRows(self: *Self, ab: *std.ArrayList(u8)) void {
    for (0..self.screenrows) |y| {
        const filerow = self.rowoff + y;

        if (filerow >= self.rows.items.len) {
            if (self.rows.items.len == 0 and y == self.screenrows / 3) {
                var welcome: [80]u8 = undefined;
                const welcome_str = std.fmt.bufPrint(&welcome, "Kilo editor -- version {s}\x1b[0K\r\n", .{version}) catch "Kilo\r\n";
                const padding = if (self.screencols > welcome_str.len) (self.screencols - welcome_str.len) / 2 else 0;
                if (padding > 0) {
                    ab.append(self.allocator, '~') catch return;
                    for (1..padding) |_| {
                        ab.append(self.allocator, ' ') catch return;
                    }
                }
                ab.appendSlice(self.allocator, welcome_str) catch return;
            } else {
                ab.appendSlice(self.allocator, "~\x1b[0K\r\n") catch return;
            }
            continue;
        }

        const r = &self.rows.items[filerow];
        const rlen = r.render.items.len;
        const len: usize = if (rlen > self.coloff)
            @min(rlen - self.coloff, self.screencols)
        else
            0;

        var current_color: u8 = 37;

        if (len > 0) {
            const render_slice = r.render.items[self.coloff .. self.coloff + len];
            const hl_slice = if (r.hl.items.len > self.coloff)
                r.hl.items[self.coloff..@min(self.coloff + len, r.hl.items.len)]
            else
                &[_]Highlight{};

            for (render_slice, 0..) |ch, j| {
                const hl: Highlight = if (j < hl_slice.len) hl_slice[j] else .normal;

                if (hl == .nonprint) {
                    ab.appendSlice(self.allocator, "\x1b[7m") catch return;
                    const sym: u8 = if (ch <= 26) '@' + ch else '?';
                    ab.append(self.allocator, sym) catch return;
                    ab.appendSlice(self.allocator, "\x1b[0m") catch return;
                    current_color = 37;
                } else if (hl == .normal) {
                    if (current_color != 37) {
                        ab.appendSlice(self.allocator, "\x1b[39m") catch return;
                        current_color = 37;
                    }
                    ab.append(self.allocator, ch) catch return;
                } else {
                    const color = hl.color();
                    if (color != current_color) {
                        var cbuf: [16]u8 = undefined;
                        const cseq = std.fmt.bufPrint(&cbuf, "\x1b[{d}m", .{color}) catch "\x1b[37m";
                        ab.appendSlice(self.allocator, cseq) catch return;
                        current_color = color;
                    }
                    ab.append(self.allocator, ch) catch return;
                }
            }
        }

        ab.appendSlice(self.allocator, "\x1b[39m\x1b[0K\r\n") catch return;
    }
}

fn renderStatusBar(self: *Self, ab: *std.ArrayList(u8)) void {
    ab.appendSlice(self.allocator, "\x1b[0K\x1b[7m") catch return;

    var status: [status_buf_size]u8 = undefined;
    const fname = self.filename orelse "[No Name]";
    const fname_trunc = if (fname.len > 20) fname[0..20] else fname;
    const status_str = std.fmt.bufPrint(&status, "{s} - {d} lines {s}", .{
        fname_trunc,
        self.rows.items.len,
        if (self.dirty > 0) "(modified)" else "",
    }) catch "status error";
    const slen = @min(status_str.len, self.screencols);

    var rstatus: [status_buf_size]u8 = undefined;
    const rstatus_str = std.fmt.bufPrint(&rstatus, "{d}/{d}", .{
        self.rowoff + self.cy + 1,
        self.rows.items.len,
    }) catch "?/?";
    const rlen = rstatus_str.len;

    ab.appendSlice(self.allocator, status_str[0..slen]) catch return;

    var len: usize = slen;
    while (len < self.screencols) : (len += 1) {
        if (self.screencols - len == rlen) {
            ab.appendSlice(self.allocator, rstatus_str) catch return;
            break;
        } else {
            ab.append(self.allocator, ' ') catch return;
        }
    }

    ab.appendSlice(self.allocator, "\x1b[0m\r\n") catch return;
}

fn renderMessageBar(self: *Self, ab: *std.ArrayList(u8)) void {
    ab.appendSlice(self.allocator, "\x1b[0K") catch return;
    if (self.status_msg_len > 0 and getTimestamp() - self.status_msg_time < 5) {
        const show_len = @min(self.status_msg_len, self.screencols);
        ab.appendSlice(self.allocator, self.status_msg[0..show_len]) catch return;
    }
}

pub fn setStatusMessage(self: *Self, msg: []const u8) void {
    const len = @min(msg.len, self.status_msg.len);
    @memcpy(self.status_msg[0..len], msg[0..len]);
    self.status_msg_len = len;
    self.status_msg_time = getTimestamp();
}

// ======================= Key Processing =======================

pub fn processKeypress(self: *Self) bool {
    const key = self.term.readKey();

    switch (key) {
        .enter => self.insertNewline(),
        .ctrl_c => {},
        .ctrl_q => {
            if (self.dirty > 0 and self.quit_times > 0) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{self.quit_times}) catch "WARNING! Unsaved changes.";
                self.setStatusMessage(msg);
                self.quit_times -= 1;
                return true;
            }
            return false;
        },
        .ctrl_s => self.save(),
        .ctrl_f => self.find(),
        .backspace, .ctrl_h, .del_key => {
            if (key == .del_key) self.moveCursor(.arrow_right);
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
        .arrow_up, .arrow_down, .arrow_left, .arrow_right => self.moveCursor(key),
        .ctrl_l, .esc => {},
        else => {
            if (key.isPrintable()) {
                self.insertChar(key.toChar());
            }
        },
    }

    self.quit_times = quit_times_max;
    return true;
}

// ======================= SIGWINCH =======================

pub fn handleResize(self: *Self) void {
    var rows: usize = 0;
    var cols: usize = 0;
    self.term.getWindowSize(&rows, &cols) catch return;
    self.screenrows = if (rows >= 2) rows - 2 else rows;
    self.screencols = cols;
    if (self.cy >= self.screenrows and self.screenrows > 0) self.cy = self.screenrows - 1;
    if (self.cx >= self.screencols and self.screencols > 0) self.cx = self.screencols - 1;
    self.refreshScreen();
}

fn getTimestamp() i64 {
    var tv: posix.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return tv.sec;
}
