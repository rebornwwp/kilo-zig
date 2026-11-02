//! 编辑器核心。
//!
//! `Editor` 同时负责几件事：
//! - 保存文件内容（`rows`）和光标位置；
//! - 处理插入、删除、换行、移动等编辑操作；
//! - 打开/保存文件；
//! - 查找；
//! - 把当前状态渲染成一屏 ANSI 转义序列；
//! - 把按键分发给对应的编辑操作。
//!
//! 屏幕坐标和文件坐标是两套不同的坐标：
//! - `cx` / `cy` 是光标在当前屏幕上的列/行；
//! - `coloff` / `rowoff` 是屏幕左上角对应的文件列/行偏移；
//! - 文件中的真实位置 = `coloff + cx`、`rowoff + cy`。

const std = @import("std");
const posix = std.posix;
const terminal = @import("terminal.zig");
const syntax = @import("syntax.zig");
const Row = @import("Row.zig");
const Highlight = syntax.Highlight;
const Key = terminal.Key;

const version = "0.0.1";
/// 有未保存修改时，先连续警告多少次；警告耗尽后再按 Ctrl-Q 才真正退出。
const quit_times_max = 3;
/// 查找输入框最多保存多少个字符。
const query_len = 256;
/// 状态栏/消息栏的固定缓冲区大小。
const status_buf_size = 80;

const Self = @This();

// ---- 屏幕坐标 ----
/// 光标在当前屏幕中的列（0 开始）。
cx: usize = 0,
/// 光标在当前屏幕中的行（0 开始）。
cy: usize = 0,
/// 屏幕顶部对应文件中的第几行。
rowoff: usize = 0,
/// 屏幕左侧对应文件中的第几列。
coloff: usize = 0,
/// 文本区域行数（总行数减去状态栏和消息栏）。
screenrows: usize = 0,
/// 文本区域列数。
screencols: usize = 0,

// ---- 文件内容 ----
/// 文件的所有行。
rows: std.ArrayList(Row) = std.ArrayList(Row).empty,
/// 是否有未保存修改。0 表示干净，非 0 表示 dirty。
dirty: usize = 0,
/// 当前文件名；没有文件名时表示新建的匿名缓冲区。
filename: ?[]u8 = null,

// ---- 状态栏 ----
/// 状态消息缓冲区。
status_msg: [status_buf_size]u8 = @splat(0),
/// 状态消息实际长度。
status_msg_len: usize = 0,
/// 状态消息写入时间，用于 5 秒后自动消失。
status_msg_time: i64 = 0,

// ---- 其他 ----
/// 当前文件的语法配置；没有匹配到语法时为 null。
syn: ?*const syntax.Syntax = null,
/// 终端控制对象，负责 /dev/tty、raw mode 和按键读取。
term: terminal.Terminal,
/// 有未保存修改时剩余的警告次数；耗尽后下一次 Ctrl-Q 退出。
quit_times: usize = quit_times_max,
/// 内存分配器。
allocator: std.mem.Allocator,
/// 文件 I/O 使用的 Io 实现。
io: std.Io,

/// 初始化编辑器：打开控制终端，并根据窗口大小计算文本区域。
pub fn init(allocator: std.mem.Allocator, io_handle: std.Io) !Self {
    var self = Self{
        .allocator = allocator,
        .io = io_handle,
        .term = try terminal.Terminal.init(io_handle),
    };
    // 如果后面的窗口查询失败，需要把已经打开的 /dev/tty 关掉。
    errdefer self.term.deinit();

    var rows: usize = 0;
    var cols: usize = 0;
    try self.term.getWindowSize(&rows, &cols);
    // 底部两行分别留给状态栏和消息栏。
    self.screenrows = if (rows >= 2) rows - 2 else rows;
    self.screencols = cols;

    return self;
}

/// 释放编辑器资源，并恢复终端状态。
///
/// `main` 用 `defer editor.deinit()` 保证正常退出时一定执行到这里。
pub fn deinit(self: *Self) void {
    for (self.rows.items) |*row| row.deinit();
    self.rows.deinit(self.allocator);
    if (self.filename) |f| self.allocator.free(f);
    // 先恢复 termios，再关闭 /dev/tty。
    self.term.deinit();
}

// ======================= 行操作 =======================

/// 重新生成行的 render/hl，并更新语法高亮状态。
fn updateRow(self: *Self, row: *Row) void {
    row.updateRender(self.rows.items, self.syn);
}

/// 在 `at` 位置插入一行。
///
/// 插入后会把后面所有行的 `idx` 重新编号，并刷新这一行的显示缓存。
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

/// 删除 `at` 位置的行，并修正后面各行的行号。
fn deleteRow(self: *Self, at: usize) void {
    if (at >= self.rows.items.len) return;
    self.rows.items[at].deinit();
    _ = self.rows.orderedRemove(at);
    for (self.rows.items[at..], at..) |*row, idx| {
        row.idx = idx;
    }
    self.dirty += 1;
}

/// 把所有行重新拼成带 `\n` 的完整文件内容。
///
/// 返回的缓冲区由调用者负责释放。
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

// ======================= 编辑操作 =======================

/// 在当前光标位置插入一个字符。
///
/// 如果光标已经移动到文件末尾之外，会先补齐空行/空格。
pub fn insertChar(self: *Self, ch: u8) void {
    // 屏幕坐标 + 滚动偏移 = 文件中的真实坐标。
    const filerow = self.rowoff + self.cy;
    const filecol = self.coloff + self.cx;

    // 如果光标在文件末尾之后，先补出空行。
    while (self.rows.items.len <= filerow) {
        self.insertRow(self.rows.items.len, "");
    }

    const row = &self.rows.items[filerow];
    row.insertChar(filecol, ch);
    self.updateRow(row);

    // 光标到达屏幕最右侧时，不再增加 cx，而是滚动 coloff。
    if (self.cx == self.screencols - 1) {
        self.coloff += 1;
    } else {
        self.cx += 1;
    }
    self.dirty += 1;
}

/// 在光标处按 Enter：把当前行从光标位置劈成两行。
pub fn insertNewline(self: *Self) void {
    const filerow = self.rowoff + self.cy;
    var filecol = self.coloff + self.cx;

    // 在文件末尾按 Enter：补一个空行即可。
    if (filerow >= self.rows.items.len) {
        if (filerow == self.rows.items.len) {
            self.insertRow(filerow, "");
            self.advanceCursorDown();
        }
        return;
    }

    const row = &self.rows.items[filerow];
    // 光标可能在行尾之后，先夹到合法范围。
    if (filecol >= row.chars.items.len) filecol = row.chars.items.len;

    if (filecol == 0) {
        // 在行首按 Enter：当前内容整体下移，光标上方插入空行。
        self.insertRow(filerow, "");
    } else {
        // 从光标处劈开：后半段变成新行，当前行截断到光标处。
        const rest = row.chars.items[filecol..];
        self.insertRow(filerow + 1, rest);
        const cur_row = &self.rows.items[filerow];
        cur_row.truncate(filecol);
        self.updateRow(cur_row);
    }

    self.advanceCursorDown();
}

/// 删除光标前一个字符。
///
/// 如果光标在行首，则把当前行合并到上一行。
pub fn deleteChar(self: *Self) void {
    const filerow = self.rowoff + self.cy;
    const filecol = self.coloff + self.cx;

    if (filerow >= self.rows.items.len) return;
    if (filecol == 0 and filerow == 0) return;

    const row = &self.rows.items[filerow];

    if (filecol == 0) {
        // 行首退格：把当前行追加到上一行，然后删除当前行。
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
        // 普通退格：删除光标左侧字符，光标左移一格。
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

/// 光标下移一行，并回到行首。
///
/// 如果已经到达屏幕底部，则改为滚动 `rowoff`。
fn advanceCursorDown(self: *Self) void {
    if (self.cy == self.screenrows - 1) {
        self.rowoff += 1;
    } else {
        self.cy += 1;
    }
    self.cx = 0;
    self.coloff = 0;
}

// ======================= 光标移动 =======================

/// 根据方向键移动光标。
///
/// 处理了屏幕边缘滚动、左右跨越行首/行尾，以及移动到短行后
/// 自动把光标收回到行尾的逻辑。
pub fn moveCursor(self: *Self, key: Key) void {
    const filerow = self.rowoff + self.cy;
    const filecol = self.coloff + self.cx;
    const row = if (filerow < self.rows.items.len) &self.rows.items[filerow] else null;

    switch (key) {
        .arrow_left => {
            if (self.cx == 0) {
                // 屏幕最左列：先尝试向左滚动，否则跳到上一行行尾。
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
                    // 行内右移；到屏幕最右侧时改为横向滚动。
                    if (self.cx == self.screencols - 1) {
                        self.coloff += 1;
                    } else {
                        self.cx += 1;
                    }
                } else if (filecol == r.chars.items.len) {
                    // 已经在行尾：右移到下一行行首。
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
            // 到屏幕顶部时改为纵向滚动。
            if (self.cy == 0) {
                if (self.rowoff > 0) self.rowoff -= 1;
            } else {
                self.cy -= 1;
            }
        },
        .arrow_down => {
            // 文件末尾之外不再继续下移。
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

    // 如果新行比原来的列位置短，把光标收回到行尾。
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
            // 光标在屏幕左侧之外，需要同时回退 coloff。
            self.coloff -= excess - self.cx;
            self.cx = 0;
        }
    }
}

// ======================= 文件 I/O =======================

/// 打开文件。
///
/// 文件不存在时不算错误：相当于创建一个新缓冲区。
/// 读取成功后按行拆分，并去掉 Windows 风格的 `\r`。
pub fn open(self: *Self, filename: []const u8) !void {
    self.dirty = 0;

    // 保存一份自己的文件名副本，之后状态栏和保存都要用。
    if (self.filename) |old| self.allocator.free(old);
    self.filename = try self.allocator.dupe(u8, filename);

    // 根据扩展名选择语法高亮配置。
    self.syn = syntax.Syntax.detect(filename);

    const content = std.Io.Dir.cwd().readFileAlloc(self.io, filename, self.allocator, .unlimited) catch |err| {
        // 新文件：没有内容，但文件名已经设置好了。
        if (err == error.FileNotFound) return;
        return err;
    };
    defer self.allocator.free(content);

    // 按换行拆分。末尾的 `\r` 是 Windows 换行留下的，读入时去掉。
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        var ln = line;
        if (ln.len > 0 and ln[ln.len - 1] == '\r') {
            ln = ln[0 .. ln.len - 1];
        }
        self.insertRow(self.rows.items.len, ln);
    }

    // 文件以 `\n` 结尾时，split 会产生一个多余空行，把它去掉。
    if (self.rows.items.len > 1) {
        const last = &self.rows.items[self.rows.items.len - 1];
        if (last.chars.items.len == 0) {
            last.deinit();
            self.rows.items.len -= 1;
        }
    }

    // 读文件过程中 insertRow 会增加 dirty，读完后重置为干净状态。
    self.dirty = 0;
}

/// 保存当前缓冲区到文件名对应的磁盘文件。
///
/// 错误不会向上抛，而是写进底部状态栏，避免编辑器因为一次写失败退出。
pub fn save(self: *Self) void {
    // 匿名缓冲区没有文件名，不能保存。
    const filename = self.filename orelse {
        self.setStatusMessage("No filename");
        return;
    };

    // 先把所有行拼成完整文件内容。
    const buf = self.rowsToString() catch {
        self.setStatusMessage("Can't save! Memory error");
        return;
    };
    defer self.allocator.free(buf);

    // truncate=true：覆盖原文件，而不是在末尾追加。
    const file = std.Io.Dir.cwd().createFile(self.io, filename, .{ .truncate = true }) catch |err| {
        var errbuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "Can't save! I/O error: {s}", .{@errorName(err)}) catch "Can't save!";
        self.setStatusMessage(msg);
        return;
    };
    defer file.close(self.io);

    // 写失败同样只提示，不退出编辑器。
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

// ======================= 查找 =======================

/// 交互式查找。
///
/// 这个函数自己读取按键，直到用户按 Enter 接受或按 ESC 取消。
/// 找到匹配后会临时把匹配文本标成 `.match` 颜色。
pub fn find(self: *Self) void {
    var query: [query_len + 1]u8 = @splat(0);
    var qlen: usize = 0;
    var last_match: i64 = -1;
    var find_next: i32 = 0;
    var saved_hl_line: i64 = -1;
    var saved_hl: ?[]Highlight = null;

    // 记录查找开始前的位置，ESC 取消时恢复。
    const saved_cx = self.cx;
    const saved_cy = self.cy;
    const saved_coloff = self.coloff;
    const saved_rowoff = self.rowoff;

    // 退出查找时把临时覆盖的高亮恢复回去。
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
            // 退格：缩短查询串，并重新从头搜索。
            if (qlen > 0) {
                qlen -= 1;
                query[qlen] = 0;
            }
            last_match = -1;
        } else if (key == .esc or key == .enter) {
            // ESC 取消并恢复原光标；Enter 接受当前匹配。
            if (key == .esc) {
                self.cx = saved_cx;
                self.cy = saved_cy;
                self.coloff = saved_coloff;
                self.rowoff = saved_rowoff;
            }
            self.setStatusMessage("");
            return;
        } else if (key == .arrow_right or key == .arrow_down) {
            // 向下一个匹配移动。
            find_next = 1;
        } else if (key == .arrow_left or key == .arrow_up) {
            // 向上一个匹配移动。
            find_next = -1;
        } else if (key.isPrintable()) {
            // 普通字符追加到查询串。
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

            // 从 last_match 开始按方向绕圈查找。
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

            // 找到新匹配前，先恢复上一次匹配行的原始高亮。
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
                    // 备份原高亮，再把匹配部分改成 .match 颜色。
                    saved_hl_line = @intCast(row_idx);
                    saved_hl = self.allocator.dupe(Highlight, row.hl.items) catch null;
                    @memset(row.hl.items[match_offset..@min(match_offset + qlen, row.hl.items.len)], .match);
                }

                // 把匹配行滚到屏幕顶部，并水平定位到匹配列。
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

// ======================= 屏幕刷新 =======================

/// 把当前编辑器状态完整画到终端。
///
/// 为了减少闪烁，所有内容先追加到 `ab` 缓冲区，最后一次性写出：
/// 隐藏光标 → 定位左上角 → 正文 → 状态栏 → 消息栏 → 恢复光标位置。
pub fn refreshScreen(self: *Self) void {
    var ab = std.ArrayList(u8).empty;
    defer ab.deinit(self.allocator);

    ab.appendSlice(self.allocator, "\x1b[?25l\x1b[H") catch return;

    self.renderRows(&ab);
    self.renderStatusBar(&ab);
    self.renderMessageBar(&ab);

    // 计算光标在终端中的实际列号。
    // 文件里的列号不等于屏幕列号，因为制表符会展开成多个空格。
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

    // ANSI 光标定位是 1-based，所以行号/列号都要 +1。
    var posbuf: [32]u8 = undefined;
    const posseq = std.fmt.bufPrint(&posbuf, "\x1b[{d};{d}H", .{ self.cy + 1, cx }) catch "\x1b[1;1H";
    ab.appendSlice(self.allocator, posseq) catch return;
    ab.appendSlice(self.allocator, "\x1b[?25h") catch return;

    // 一次性写到 /dev/tty，而不是 stdout。
    _ = self.term.write(ab.items) catch {};
}

/// 渲染正文区域（不含状态栏）。
///
/// 空行显示为 `~`，文件为空时在屏幕中间显示欢迎语。
/// 每个字符根据 `hl` 切换 ANSI 颜色。
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

/// 渲染状态栏：左边是文件名/行数/是否修改，右边是当前位置。
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

/// 渲染最底部一行的临时消息。
///
/// 消息只在写入后的 5 秒内显示。
fn renderMessageBar(self: *Self, ab: *std.ArrayList(u8)) void {
    ab.appendSlice(self.allocator, "\x1b[0K") catch return;
    if (self.status_msg_len > 0 and getTimestamp() - self.status_msg_time < 5) {
        const show_len = @min(self.status_msg_len, self.screencols);
        ab.appendSlice(self.allocator, self.status_msg[0..show_len]) catch return;
    }
}

/// 设置底部状态消息，并记录当前时间。
pub fn setStatusMessage(self: *Self, msg: []const u8) void {
    const len = @min(msg.len, self.status_msg.len);
    @memcpy(self.status_msg[0..len], msg[0..len]);
    self.status_msg_len = len;
    self.status_msg_time = getTimestamp();
}

// ======================= 按键处理 =======================

/// 读取并处理一个按键。
///
/// 返回 `false` 表示用户确认退出；返回 `true` 表示继续主循环。
pub fn processKeypress(self: *Self) bool {
    const key = self.term.readKey();

    switch (key) {
        .enter => self.insertNewline(),
        .ctrl_c => {},
        .ctrl_q => {
            // 沿用 kilo 原版计数：quit_times 是剩余警告次数，耗尽后的
            // 下一次 Ctrl-Q 才退出，所以 3 次警告意味着总共要按 4 次。
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

// ======================= 窗口大小变化 =======================

/// 处理 SIGWINCH：重新查询窗口大小并刷新。
///
/// 如果光标因为窗口变小而越界，会把它收回到新边界内。
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

/// 获取当前 Unix 时间戳（秒）。
fn getTimestamp() i64 {
    var tv: posix.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return tv.sec;
}
