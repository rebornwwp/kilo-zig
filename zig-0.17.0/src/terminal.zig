//! 终端控制层。
//!
//! 本文件负责和“真正的终端设备”打交道：
//! - 打开 `/dev/tty`，避免依赖可能被重定向的 stdin/stdout；
//! - 保存并修改 termios，进入/退出 raw mode；
//! - 从终端读取按键，并把 ANSI 转义序列解析成 `Key`；
//! - 查询窗口大小和光标位置；
//! - 向终端写入渲染好的屏幕内容。

const std = @import("std");
const posix = std.posix;
const c = std.c;

// termios 的 cc 数组用这两个下标保存 MIN/TIME。
// 直接写 16/17 是为了避开不同 libc 常量类型带来的转换噪音。
const vmin: usize = 16;
const vtime: usize = 17;

/// 编辑器内部使用的按键表示。
///
/// 0~127 直接对应终端读到的字节；方向键、Home/End 等没有对应字节的键，
/// 使用 1000 之后的编号表示。
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

    /// 是否可以直接当作可打印字符插入文本。
    pub fn isPrintable(self: Key) bool {
        const k = @backingInt(self);
        return k < 128 and std.ascii.isPrint(@as(u8, @truncate(k)));
    }

    /// 取出按键对应的原始字节。
    pub fn toChar(self: Key) u8 {
        return @truncate(@backingInt(self));
    }
};

/// 终端句柄及其原始状态。
pub const Terminal = struct {
    /// 关闭 `/dev/tty` 时需要用到 Io 实现。
    io: std.Io,
    /// 当前进程控制终端的读写句柄。
    tty: std.Io.File,
    /// 进入 raw mode 之前保存的 termios，退出时必须恢复。
    orig_termios: posix.termios = undefined,
    /// 当前是否处于 raw mode。
    rawmode: bool = false,
    /// 防止 deinit 重复关闭同一个 fd。
    closed: bool = false,

    /// 打开当前进程的控制终端。
    ///
    /// 使用 `/dev/tty` 而不是 stdin/stdout 的原因：
    /// 即使程序被 `|`、`>`、`<` 重定向，TUI 仍然应该和真正的终端交互。
    pub fn init(io: std.Io) !Terminal {
        const tty = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        return .{
            .io = io,
            .tty = tty,
        };
    }

    /// 恢复终端状态并关闭 `/dev/tty`。
    pub fn deinit(self: *Terminal) void {
        if (self.closed) return;
        self.disableRawMode();
        self.tty.close(self.io);
        self.closed = true;
    }

    /// 进入 raw mode。
    ///
    /// 关键点是关闭 ICANON/ECHO/ISIG 等行规程功能，让终端把每个按键
    /// 立即交给程序，而不是等 Enter 后按行交付。
    pub fn enableRawMode(self: *Terminal) !void {
        if (self.rawmode) return;
        if (c.isatty(self.tty.handle) == 0) return error.NotATty;

        self.orig_termios = try posix.tcgetattr(self.tty.handle);
        var raw = self.orig_termios;

        // 输入：不做换行转换、不把 Ctrl-S/Q 当流控。
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // 输出：由编辑器自己输出 \r\n，不要让内核把 \n 转成 \r\n。
        raw.oflag.OPOST = false;
        // 固定 8 位字符。
        raw.cflag.CSIZE = .CS8;
        // 本地模式：关回显、关行缓冲、关扩展输入处理（IEXTEN）、关信号生成。
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // VMIN=0、VTIME=1：read 最多等 100ms 后返回 0。
        // 这样单独按 Esc 时不会一直阻塞，方向键的 ESC 序列也能正常读取。
        raw.cc[vmin] = 0;
        raw.cc[vtime] = 1;

        try posix.tcsetattr(self.tty.handle, .FLUSH, raw);
        self.rawmode = true;
    }

    /// 恢复进入 raw mode 之前保存的终端设置。
    pub fn disableRawMode(self: *Terminal) void {
        if (self.rawmode) {
            posix.tcsetattr(self.tty.handle, .FLUSH, self.orig_termios) catch {};
            self.rawmode = false;
        }
    }

    /// 读取一个按键。
    ///
    /// 普通字符直接返回；如果是 ESC，则继续尝试读取方向键等
    /// ANSI 转义序列（例如 `ESC [ A` 表示上箭头）。
    ///
    /// 底层 read 出错时沿用 kilo 原实现直接退出；注意这种路径会跳过
    /// `Editor.deinit`，因此不会恢复 termios。
    pub fn readKey(self: *Terminal) Key {
        const fd = self.tty.handle;
        var buf: [1]u8 = undefined;
        while (true) {
            const nread = posix.read(fd, &buf) catch {
                std.process.exit(1);
            };
            if (nread == 1) break;
        }

        if (buf[0] != 27) return @fromBackingInt(@intCast(buf[0]));

        var seq: [3]u8 = undefined;
        const n1 = posix.read(fd, seq[0..1]) catch return .esc;
        if (n1 == 0) return .esc;
        const n2 = posix.read(fd, seq[1..2]) catch return .esc;
        if (n2 == 0) return .esc;

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                const n3 = posix.read(fd, seq[2..3]) catch return .esc;
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

    /// 获取终端窗口大小。
    ///
    /// 优先用 `ioctl(TIOCGWINSZ)`；如果终端没有报告大小，则退回到
    /// “把光标移到右下角再查询位置”的兼容方案。
    pub fn getWindowSize(self: *Terminal, rows: *usize, cols: *usize) !void {
        var ws: posix.winsize = undefined;
        const ret = c.ioctl(self.tty.handle, @intCast(c.T.IOCGWINSZ), &ws);
        if (ret == -1 or ws.col == 0) {
            var orig_row: usize = 0;
            var orig_col: usize = 0;
            try getCursorPosition(self, &orig_row, &orig_col);
            _ = try self.write("\x1b[999C\x1b[999B");
            try getCursorPosition(self, rows, cols);
            var seq_buf: [32]u8 = undefined;
            const seq = std.fmt.bufPrint(&seq_buf, "\x1b[{d};{d}H", .{ orig_row, orig_col }) catch return;
            _ = self.write(seq) catch {};
        } else {
            cols.* = ws.col;
            rows.* = ws.row;
        }
    }

    /// 向控制终端写入数据。
    pub fn write(self: *Terminal, buf: []const u8) !usize {
        return writeAll(self.tty.handle, buf);
    }
};

/// 把整个缓冲区写到 fd，处理短写和 EINTR。
pub fn writeAll(fd: posix.fd_t, buf: []const u8) !usize {
    var written: usize = 0;
    while (written < buf.len) {
        const rc = posix.system.write(fd, buf[written..].ptr, buf[written..].len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) break;
                written += n;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.Unexpected,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .NOSPC => return error.NoSpaceLeft,
            else => return error.Unexpected,
        }
    }
    return written;
}

/// 通过 `ESC[6n` 查询当前光标位置。
///
/// 终端会把答案以 `ESC[row;colR` 的形式写回输入队列，所以这里需要
/// 从同一个 tty fd 读取响应。
fn getCursorPosition(term: *Terminal, rows: *usize, cols: *usize) !void {
    _ = try term.write("\x1b[6n");

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len - 1) {
        const n = posix.read(term.tty.handle, buf[i .. i + 1]) catch break;
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
