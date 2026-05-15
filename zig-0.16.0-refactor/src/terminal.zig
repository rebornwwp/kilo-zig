const std = @import("std");
const posix = std.posix;
const c = std.c;

const vmin: usize = 16;
const vtime: usize = 17;

pub const Key = enum(u16) {
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
    arrow_right,
    arrow_up,
    arrow_down,
    del_key,
    home_key,
    end_key,
    page_up,
    page_down,
    _,

    pub fn isPrintable(self: Key) bool {
        const k = @intFromEnum(self);
        return k < 128 and std.ascii.isPrint(@as(u8, @truncate(k)));
    }

    pub fn toChar(self: Key) u8 {
        return @truncate(@intFromEnum(self));
    }
};

pub const Terminal = struct {
    orig_termios: posix.termios = undefined,
    rawmode: bool = false,

    pub fn enableRawMode(self: *Terminal) !void {
        if (self.rawmode) return;
        if (c.isatty(posix.STDIN_FILENO) == 0) return error.NotATty;

        self.orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = self.orig_termios;

        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[vmin] = 0;
        raw.cc[vtime] = 1;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        self.rawmode = true;
    }

    pub fn disableRawMode(self: *Terminal) void {
        if (self.rawmode) {
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.orig_termios) catch {};
            self.rawmode = false;
        }
    }

    pub fn readKey(_: *Terminal) Key {
        var buf: [1]u8 = undefined;
        while (true) {
            const nread = posix.read(posix.STDIN_FILENO, &buf) catch {
                std.process.exit(1);
            };
            if (nread == 1) break;
        }

        if (buf[0] != 27) return @enumFromInt(buf[0]);

        var seq: [3]u8 = undefined;
        const n1 = posix.read(posix.STDIN_FILENO, seq[0..1]) catch return .esc;
        if (n1 == 0) return .esc;
        const n2 = posix.read(posix.STDIN_FILENO, seq[1..2]) catch return .esc;
        if (n2 == 0) return .esc;

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                const n3 = posix.read(posix.STDIN_FILENO, seq[2..3]) catch return .esc;
                if (n3 == 0) return .esc;
                if (seq[2] == '~') return switch (seq[1]) {
                    '3' => .del_key,
                    '5' => .page_up,
                    '6' => .page_down,
                    else => .esc,
                };
            } else {
                return switch (seq[1]) {
                    'A' => .arrow_up,
                    'B' => .arrow_down,
                    'C' => .arrow_right,
                    'D' => .arrow_left,
                    'H' => .home_key,
                    'F' => .end_key,
                    else => .esc,
                };
            }
        } else if (seq[0] == 'O') {
            return switch (seq[1]) {
                'H' => .home_key,
                'F' => .end_key,
                else => .esc,
            };
        }

        return .esc;
    }

    pub fn getWindowSize(_: *Terminal, rows: *usize, cols: *usize) !void {
        var ws: posix.winsize = undefined;
        const ret = c.ioctl(1, @intCast(c.T.IOCGWINSZ), &ws);
        if (ret == -1 or ws.col == 0) {
            var orig_row: usize = 0;
            var orig_col: usize = 0;
            try getCursorPosition(&orig_row, &orig_col);
            _ = try write(posix.STDOUT_FILENO, "\x1b[999C\x1b[999B");
            try getCursorPosition(rows, cols);
            var seq_buf: [32]u8 = undefined;
            const seq = std.fmt.bufPrint(&seq_buf, "\x1b[{d};{d}H", .{ orig_row, orig_col }) catch return;
            _ = write(posix.STDOUT_FILENO, seq) catch {};
        } else {
            cols.* = ws.col;
            rows.* = ws.row;
        }
    }
};

pub fn write(fd: posix.fd_t, buf: []const u8) !usize {
    while (true) {
        const rc = posix.system.write(fd, buf.ptr, buf.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.Unexpected,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .NOSPC => return error.NoSpaceLeft,
            else => return error.Unexpected,
        }
    }
}

fn getCursorPosition(rows: *usize, cols: *usize) !void {
    _ = try write(posix.STDOUT_FILENO, "\x1b[6n");

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len - 1) {
        const n = posix.read(posix.STDIN_FILENO, buf[i .. i + 1]) catch break;
        if (n != 1) break;
        if (buf[i] == 'R') break;
        i += 1;
    }

    if (i < 2 or buf[0] != 0x1b or buf[1] != '[') return error.ParseError;

    const response = buf[2..i];
    const semi = std.mem.indexOfScalar(u8, response, ';') orelse return error.ParseError;
    rows.* = try std.fmt.parseInt(usize, response[0..semi], 10);
    cols.* = try std.fmt.parseInt(usize, response[semi + 1 ..], 10);
}
